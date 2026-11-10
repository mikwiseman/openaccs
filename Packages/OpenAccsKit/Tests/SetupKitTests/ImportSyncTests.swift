import Foundation
import Testing
@testable import SetupKit

private extension SetupHome {
    func link(_ relative: String, to target: String) throws {
        let item = url.appending(path: relative)
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: item.path, withDestinationPath: target)
    }

    /// Everything under these paths without following links: kind, then bytes or link target.
    func snapshot(_ relatives: [String]) -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ relative: String) {
            let item = url.appending(path: relative)
            var info = stat()
            guard lstat(item.path, &info) == 0 else { return }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                result[relative] = "link → \(linkTarget(relative) ?? "?")"
            case S_IFDIR:
                result[relative] = "folder"
                for name in (try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? [] { walk("\(relative)/\(name)") }
            default:
                result[relative] = "file \((try? Data(contentsOf: item))?.base64EncodedString() ?? "?")"
            }
        }
        relatives.forEach(walk)
        return result
    }
}

/// One row of Import's ledger as `sqlite3 -json` prints it, with the real column names.
private func row(_ provider: String?, _ type: String, _ name: String, cwd: String? = nil) -> String {
    let json = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
    return "{\"provider_id\":\(json(provider)),\"item_type\":\"\(type)\",\"cwd\":\(json(cwd)),\"source\":\"\(name)\",\"target\":\"\(name)\"}"
}

/// A fake `run` where sqlite3 prints these rows, the way it does: nothing at all for none. The chats query gets
/// `chats`, the ledger query `rows`.
private func sqlite(_ rows: [String], chats: [String] = [], calls: Calls? = nil) -> @Sendable ([String]) -> (status: Int32, output: String)? {
    let json = { (rows: [String]) in rows.isEmpty ? "" : "[" + rows.joined(separator: ",\n") + "]\n" }
    let ledger = json(rows), chats = json(chats)
    return { argv in
        calls?.argv.append(argv)
        guard argv.first == "sqlite3" else { return nil }
        return (0, argv.last == ImportSyncSetup.chatsQuery ? chats : ledger)
    }
}

/// One chat Import made from a Claude session, as the chats query prints it.
private func chat(_ id: String, recency: Int = 1000, continued: Bool = false) -> String {
    "{\"id\":\"\(id)\",\"recency\":\(recency),\"continued\":\(continued ? 1 : 0)}"
}

/// Runs the real sqlite3.
private func realSqlite(_ argv: [String]) -> (status: Int32, output: String)? {
    guard argv.first == "sqlite3" else { return nil }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/sqlite3")
    process.arguments = Array(argv.dropFirst())
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Codex's state_5.sqlite in a test home, in write-ahead log mode as Codex keeps it, with the columns the queries
/// read, and without the log's -wal and -shm files, as Codex leaves them when it closes the database (the sqlite3
/// tool keeps them). Its `run` is the real sqlite3, and `codex archive` and `codex unarchive` as Codex does them:
/// they refuse a chat that is already there.
private struct CodexDatabase {
    let path: String

    init(_ home: SetupHome, _ rows: String) throws {
        path = home.path(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: home.url.appending(path: ".codex"), withIntermediateDirectories: true)
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
                recency_at_ms INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE external_agent_config_imports (import_id TEXT PRIMARY KEY, completed_at_ms INTEGER NOT NULL,
                successes TEXT NOT NULL, failures TEXT NOT NULL, provider_id TEXT);

            """
        try #require(realSqlite(["sqlite3", path, schema + rows])?.status == 0)
        for suffix in ["-wal", "-shm"] { try FileManager.default.removeItem(atPath: path + suffix) }
    }

    func execute(_ sql: String) { _ = realSqlite(["sqlite3", path, sql]) }

    /// The ids of archived chats, sorted.
    var archived: [String] {
        (realSqlite(["sqlite3", path, "SELECT id FROM threads WHERE archived = 1 ORDER BY id"])?.output ?? "").split(separator: "\n").map(String.init)
    }

    func run(calls: Calls? = nil) -> @Sendable ([String]) -> (status: Int32, output: String)? {
        let path = self.path
        return { argv in
            calls?.argv.append(argv)
            if argv.first == "sqlite3" { return realSqlite(argv) }
            guard argv.first == "codex", argv.count == 3, ["archive", "unarchive"].contains(argv[1]) else { return nil }
            let archived = argv[1] == "archive" ? 1 : 0
            let changed = realSqlite(["sqlite3", path, "UPDATE threads SET archived = \(archived) WHERE id = '\(argv[2])' AND archived != \(archived); SELECT changes();"])
            return changed?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? (0, "") : (1, "Error: failed to \(argv[1]) session\n")
        }
    }
}

private let config = """
model = "gpt-5"

[desktop]
followUpQueueMode = "steer"
external-agent-import-sync-enabled = true # set by Import
external-agent-import-sync-item-types = "all"

[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"

"""

@Suite struct ImportSyncTests {
    @Test func syncOnIsTurnedOffAndNothingElseInTheConfigChanges() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config)
        let report = ImportSyncSetup.scan(home.context())

        #expect(report.summary == "Keep imports in sync is on · nothing left over")
        #expect(report.attention == [Attention(id: "importSync.on", text: "ChatGPT Import still copies Claude into Codex", fixes: ["importSync.turn-off"])])
        let change = try #require(report.changes.first)
        #expect(report.changes.count == 1)
        #expect(change.title == "Turn off ChatGPT's Keep imports in sync" && change.waitsFor == .chatGPT)
        guard case .toml(let path, let table, let key, let value, let expected) = change.operations.first,
              change.operations.count == 1 else { Issue.record("not one TOML edit"); return }
        #expect(path == home.path(".codex/config.toml") && table == ["desktop"] && key == ImportSyncSetup.syncKey)
        #expect(expected == .bool(true) && value == .bool(false))

        #expect(SetupApplier(context: home.context()).apply(report.changes).applied.count == 1)
        #expect(home.read(".codex/config.toml") == config.replacingOccurrences(of: "enabled = true #", with: "enabled = false #"))
    }

    @Test func offOrNeverUsedAsksNothing() throws {
        let never = try SetupHome()
        try never.write(".codex/config.toml", "model = \"gpt-5\"\n\n[desktop]\nfollowUpQueueMode = \"steer\"\n")
        let unused = ImportSyncSetup.scan(never.context())
        #expect(unused == AreaReport(area: .importSync, summary: "Not used"))
        #expect(ImportSyncSetup.scan(try SetupHome().context()) == AreaReport(area: .importSync, summary: "Not used"))

        let off = try SetupHome()
        try off.write(".codex/config.toml", config.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        let report = ImportSyncSetup.scan(off.context())
        #expect(report.summary == "Off · nothing left over")
        #expect(report.attention.isEmpty && report.changes.isEmpty && report.items.isEmpty)

        // A run that put things only in a project leaves nothing in ~.
        let project = try SetupHome()
        try project.write(".agents/skills/test-app/SKILL.md", "Mine.\n")
        let projectOnly = ImportSyncSetup.scan(project.context(run: sqlite([row("claude-code", "SKILLS", "test-app", cwd: "/code/ai-mark")])))
        #expect(projectOnly.summary == "Off · nothing left over" && projectOnly.changes.isEmpty)
    }

    @Test func eachCopySaysWhyItGoes() throws {
        let home = try SetupHome()
        try home.write(".cursor/skills-cursor/canvas/SKILL.md", "Use the Cursor canvas.\n")
        try home.write(".agents/skills/canvas/SKILL.md", "Use the Codex canvas.\n")
        try home.write(".agents/skills/cursor-own/SKILL.md", "Mine, from Cursor.\n")
        try home.write(".claude/skills/wai-school-publish/SKILL.md", "Run ~/.claude/skills/wai-school-publish/scripts/publish.py\n")
        try home.write(".agents/skills/wai-school-publish/SKILL.md", "Run ~/.Codex/skills/wai-school-publish/scripts/publish.py\n")
        try home.write(".claude/skills/screencast/scripts/caption.sh", "echo\n")
        try home.write(".agents/skills/screencast/scripts/caption.sh", "echo\n")
        try home.write(".claude/skills/liquid-glass/SKILL.md", "Glass.\n")
        try home.write(".agents/skills/liquid-glass/SKILL.md", "Glass.\n")
        try home.write(".claude/commands/security-review.md", "Review $ARGUMENTS\n")
        try home.write(".agents/skills/source-command-security-review/SKILL.md", "Use this skill to run the migrated source command.\n")
        try home.write(".agents/skills/apple-design/SKILL.md", "Not Import's.\n")
        try home.write(".agents/skills/test-app/SKILL.md", "Not Import's either: it put its test-app in a project.\n")
        let rows = [
            row("cursor", "SKILLS", "canvas"), row("cursor", "SKILLS", "cursor-own"),
            row("claude-code", "SKILLS", "wai-school-publish"), row("claude-code", "SKILLS", "screencast"),
            row("claude-code", "SKILLS", "liquid-glass", cwd: home.url.path), row("claude-code", "COMMANDS", "source-command-security-review"),
            row("claude-code", "SKILLS", "gone"), row("claude-code", "SKILLS", "test-app", cwd: "/code/ai-mark"),
            row("claude-code", "MCP_SERVER_CONFIG", "github"), row("claude-code", "MCP_SERVER_CONFIG", "vercel"),
            row("cursor", "MCP_SERVER_CONFIG", "notion"), row("claude-code", "MCP_SERVER_CONFIG", "xcodebuild", cwd: "/code/ai-mark"),
            row("claude-code", "PLUGINS", "slack@claude-plugins-official"), row("claude-cowork", "PLUGINS", "legal"),
        ]
        let report = ImportSyncSetup.scan(home.context(run: sqlite(rows)))

        #expect(report.summary == "Off · 6 copied skills")
        #expect(report.attention.isEmpty)
        let change = try #require(report.changes.first)
        #expect(report.changes.count == 1)
        #expect(change.id == "importSync.remove-copies" && change.title == "Remove 6 skills ChatGPT Import copied")
        #expect(change.detail == """
            These folders in ~/.agents/skills go to Backups:
            canvas: copied from Cursor's built-in skills
            cursor-own: copied from Cursor
            liquid-glass: copied from Claude
            screencast: no SKILL.md
            source-command-security-review: made from a Claude command
            wai-school-publish: copied from Claude with words changed
            """)
        let names = ["canvas", "cursor-own", "liquid-glass", "screencast", "source-command-security-review", "wai-school-publish"]
        #expect(change.operations == names.map { .remove(path: home.path(".agents/skills/\($0)"), expected: .folder) })
        #expect(report.items.map(\.name) == names + ["MCP servers", "Plugins"])
        #expect(report.items.first { $0.name == "screencast" } == SetupItem(id: "importSync.skill.screencast", name: "screencast", claude: .notShared, codex: .same, note: "no SKILL.md"))
        #expect(report.items.suffix(2).map(\.note) == ["ChatGPT Import added 3 to Codex", "ChatGPT Import added 2 to Codex"])
    }

    @Test func aCopyThatClaudeLinksIntoStays() throws {
        let home = try SetupHome()
        try home.write(".agents/skills/liquid-glass/SKILL.md", "Glass.\n")
        try home.write(".agents/skills/canvas/SKILL.md", "Canvas.\n")
        try home.write(".agents/skills/canvas/scripts/draw.sh", "echo\n")
        try home.link(".claude/skills/liquid-glass", to: "../../.agents/skills/liquid-glass")
        try home.link(".claude/skills/draw", to: home.path(".agents/skills/canvas/scripts"))
        let report = ImportSyncSetup.scan(home.context(run: sqlite([row("claude-code", "SKILLS", "liquid-glass"), row("cursor", "SKILLS", "canvas")])))
        #expect(report.changes.isEmpty && report.items.isEmpty)
        #expect(report.summary == "Off · nothing left over")
    }

    @Test func claudeAccountSkillsCopiedToCodexGoToo() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config)
        try home.write(".claude/skills/synced/org_acct/pdf/SKILL.md", "Claude reads PDFs.\n")
        try home.write(".claude/skills/synced/.bucket-org_acct", "")
        try home.write(".agents/skills/synced/org_acct/pdf/SKILL.md", "Codex reads PDFs.\n")
        try home.write(".agents/skills/synced/.bucket-org_acct", "")
        try home.write(".agents/skills/canvas/SKILL.md", "Canvas.\n")
        // Not in the ledger: account skills must not be shared, whoever copied them.
        let report = ImportSyncSetup.scan(home.context(run: sqlite([row("cursor", "SKILLS", "canvas")])))
        let change = try #require(report.changes.first { $0.id == "importSync.remove-copies" })
        #expect(change.title == "Remove 2 skills ChatGPT Import copied")
        #expect(change.detail?.hasSuffix("synced: copied from Claude's account skills, which stay with each account") == true)
        #expect(change.operations.last == FileOperation.remove(path: home.path(".agents/skills/synced"), expected: .folder))
        #expect(report.summary == "Keep imports in sync is on · 2 copied skills")

        // A synced folder of its own in ~/.agents/skills is no copy of Claude's.
        let other = try SetupHome()
        try other.write(".codex/config.toml", config)
        try other.write(".claude/skills/synced/org_acct/pdf/SKILL.md", "Claude reads PDFs.\n")
        try other.write(".agents/skills/synced/mine/SKILL.md", "Mine.\n")
        #expect(ImportSyncSetup.scan(other.context()).changes.map(\.id) == ["importSync.turn-off"])
    }

    @Test func withoutSqliteOrTheLedgerNothingIsSaidAboutCopies() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config)
        try home.write(".agents/skills/canvas/SKILL.md", "Canvas.\n")
        try home.write(".claude/skills/synced/org_acct/pdf/SKILL.md", "Claude reads PDFs.\n")
        try home.write(".agents/skills/synced/org_acct/pdf/SKILL.md", "Codex reads PDFs.\n")
        let calls = Calls()
        let noSqlite = ImportSyncSetup.scan(home.context { argv in
            calls.argv.append(argv)
            return nil
        })
        // A plain open first, for ChatGPT's newest writes; immutable when that fails, as it can while ChatGPT has
        // the database open.
        let file = home.path(".codex/state_5.sqlite")
        #expect(calls.argv == [file, URL(filePath: file).absoluteString + "?immutable=1"].map { ["sqlite3", "-readonly", "-json", $0, ImportSyncSetup.query] })
        #expect(noSqlite.summary == "Keep imports in sync is on")
        #expect(noSqlite.changes.map(\.id) == ["importSync.turn-off"] && noSqlite.items.isEmpty)

        // No database or no table: sqlite3 fails.
        let noTable = ImportSyncSetup.scan(home.context { _ in (1, "Parse error: no such table: external_agent_config_imports\n") })
        #expect(noTable.summary == "Keep imports in sync is on" && noTable.changes.map(\.id) == ["importSync.turn-off"])

        let bare = try SetupHome()
        try bare.write(".agents/skills/synced/org_acct/pdf/SKILL.md", "Codex reads PDFs.\n")
        #expect(ImportSyncSetup.scan(bare.context { _ in nil }) == AreaReport(area: .importSync, summary: "Not used"))
    }

    @Test func copiedChatsAreArchivedButOnesCodexContinuedStay() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config)
        let rows = [row("claude-code", "SESSIONS", "t1", cwd: "/code/a"), row("claude-code", "SESSIONS", "t3", cwd: "/code/b")]
        let chats = [chat("t1", recency: 3000), chat("t2", recency: 2000), chat("t3", recency: 5000, continued: true)]
        let calls = Calls()
        let report = ImportSyncSetup.scan(home.context(run: sqlite(rows, chats: chats, calls: calls)))

        #expect(calls.argv.last == ["sqlite3", "-readonly", "-json", home.path(".codex/state_5.sqlite"), ImportSyncSetup.chatsQuery])
        #expect(report.summary == "Keep imports in sync is on · 2 copied chats")
        let change = try #require(report.changes.first { $0.id == "importSync.archive-chats" })
        #expect(report.changes.map(\.id) == ["importSync.turn-off", "importSync.archive-chats"])
        #expect(change.title == "Archive 2 chats ChatGPT Import copied into Codex")
        #expect(change.detail == "They move to Archived chats in Codex, where each one can be restored. "
            + "The sessions they were copied from stay where they are. 1 that Codex continued stays.")
        #expect(change.operations == [FileOperation.codexChat(id: "t1", archive: true, recency: 3000), .codexChat(id: "t2", archive: true, recency: 2000)])
        #expect(change.waitsFor == .chatGPT && change.requires == ["importSync.turn-off"])
        #expect(report.items == [SetupItem(id: "importSync.chats", name: "Chats", claude: .notShared, codex: .same,
                                           note: "3 still in Codex's list; Codex continued 1")])

        // Only chats Codex continued: nothing to archive, and the row still says so.
        let kept = ImportSyncSetup.scan(home.context(run: sqlite(rows, chats: [chat("t3", continued: true)])))
        #expect(kept.changes.map(\.id) == ["importSync.turn-off"])
        #expect(kept.summary == "Keep imports in sync is on · nothing left over")
        #expect(kept.items.map(\.note) == ["1 still in Codex's list; Codex continued 1"])

        let single = ImportSyncSetup.scan(home.context(run: sqlite(rows, chats: [chat("t1")])))
        let one = try #require(single.changes.first { $0.id == "importSync.archive-chats" })
        #expect(single.summary == "Keep imports in sync is on · 1 copied chat")
        #expect(one.title == "Archive 1 chat ChatGPT Import copied into Codex")
        #expect(one.detail == "It moves to Archived chats in Codex, where it can be restored. The session it was copied from stays where it is.")

        // When the plain open fails, the immutable one is read instead.
        let plainFails = sqlite(rows, chats: chats)
        let fallback = ImportSyncSetup.scan(home.context { argv in
            argv.count > 3 && !argv[3].hasSuffix("?immutable=1") ? (1, "Error: unable to open database file\n") : plainFails(argv)
        })
        #expect(fallback.changes.map(\.id) == ["importSync.turn-off", "importSync.archive-chats"])

        // Chats that can't be read: no change, and nothing said about what is left over.
        let ledgerOnly = sqlite(rows)
        let unreadable = ImportSyncSetup.scan(home.context { argv in
            argv.last == ImportSyncSetup.chatsQuery ? (1, "Parse error: no such column: t.recency_at_ms\n") : ledgerOnly(argv)
        })
        #expect(unreadable.summary == "Keep imports in sync is on" && unreadable.changes.map(\.id) == ["importSync.turn-off"])
        #expect(unreadable.items.isEmpty)

        // A ledger without sessions never asks about chats.
        let noSessions = Calls()
        _ = ImportSyncSetup.scan(home.context(run: sqlite([row("cursor", "SKILLS", "canvas")], chats: chats, calls: noSessions)))
        #expect(!noSessions.argv.contains { $0.last == ImportSyncSetup.chatsQuery })
    }

    @Test func theChatsQueryFindsCopiesCodexNeverContinued() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        let codex = try CodexDatabase(home, """
            INSERT INTO threads VALUES
                ('copied', 'Fix the panel', 0, 1000), ('grown', 'Went on in Claude', 0, 2500),
                ('continued', 'Asked in Codex', 0, 2600), ('archived', 'Archived before', 1, 1000), ('native', 'Codex''s own', 0, 5000);
            INSERT INTO external_agent_config_imports VALUES
                ('a', 2000, '[{"item_type":"SESSIONS","cwd":"/code","source":"/s/1.jsonl","target":"copied"},
                    {"item_type":"SESSIONS","source":"/s/2.jsonl","target":"grown"},
                    {"item_type":"SESSIONS","source":"/s/3.jsonl","target":"continued"},
                    {"item_type":"SESSIONS","source":"/s/4.jsonl","target":"archived"},
                    {"item_type":"SESSIONS","source":"/s/5.jsonl","target":"deleted"},
                    {"item_type":"SKILLS","source":"canvas","target":"canvas"}]', '[]', 'claude-code'),
                ('b', 3000, '[{"item_type":"SESSIONS","source":"/s/2.jsonl","target":"grown"}]', '[]', 'claude-code'),
                ('c', 3500, 'not json', '[]', 'claude-code');
            """)
        let calls = Calls()
        let report = ImportSyncSetup.scan(home.context(run: codex.run(calls: calls)))
        let change = try #require(report.changes.first { $0.id == "importSync.archive-chats" })
        // Newest first; "grown" was imported again after Claude went on, so nothing in Codex touched it.
        #expect(change.operations == [FileOperation.codexChat(id: "grown", archive: true, recency: 2500), .codexChat(id: "copied", archive: true, recency: 1000)])
        #expect(report.items.map(\.note) == ["3 still in Codex's list; Codex continued 1"])
        #expect(report.summary == "Off · 2 copied chats")
        // Without the log's files the plain open fails, and the immutable one reads every write.
        let file = home.path(".codex/state_5.sqlite")
        #expect(calls.argv.filter { $0.last == ImportSyncSetup.chatsQuery }.map { $0[3] } == [file, URL(filePath: file).absoluteString + "?immutable=1"])
    }

    @Test func archivingWaitsForChatGPTAndUndoBringsEachChatBack() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        let codex = try CodexDatabase(home, """
            INSERT INTO threads VALUES ('c1', 'First', 0, 1000), ('c2', 'Second', 0, 900), ('mine', 'Codex''s own', 0, 5000);
            INSERT INTO external_agent_config_imports VALUES ('a', 2000,
                '[{"item_type":"SESSIONS","target":"c1"},{"item_type":"SESSIONS","target":"c2"}]', '[]', 'claude-code');
            """)
        let calls = Calls()
        let report = ImportSyncSetup.scan(home.context(run: codex.run(calls: calls)))
        #expect(report.summary == "Off · 2 copied chats" && report.attention.isEmpty)
        let change = try #require(report.changes.first)
        #expect(report.changes.count == 1 && change.id == "importSync.archive-chats" && change.requires.isEmpty)

        let open = SetupApplier(context: home.context(running: [.chatGPT], run: codex.run(calls: calls))).apply([change])
        #expect(open.applied.isEmpty && open.skipped.map(\.reason) == ["waits for ChatGPT to close"])
        #expect(!calls.argv.contains { $0.first == "codex" } && codex.archived.isEmpty)

        let applier = SetupApplier(context: home.context(run: codex.run(calls: calls)))
        let result = applier.apply([change])
        #expect(result.applied.count == 1 && result.skipped.isEmpty)
        #expect(calls.argv.filter { $0.first == "codex" } == [["codex", "archive", "c1"], ["codex", "archive", "c2"]])
        #expect(codex.archived == ["c1", "c2"])
        let after = ImportSyncSetup.scan(home.context(run: codex.run()))
        #expect(after.changes.isEmpty && after.items.isEmpty && after.summary == "Off · nothing left over")

        calls.argv = []
        try applier.undo(try #require(result.applied.first).id)
        #expect(calls.argv.filter { $0.first == "codex" } == [["codex", "unarchive", "c2"], ["codex", "unarchive", "c1"]])
        #expect(codex.archived.isEmpty)
        // Brought back by Undo, so never offered again.
        let undone = ImportSyncSetup.scan(home.context(run: codex.run()))
        #expect(undone.changes.isEmpty && undone.summary == "Off · nothing left over")
        #expect(undone.items.map(\.note) == ["2 still in Codex's list; you brought back 2"])
    }

    @Test func aChatChangedSinceTheReviewIsNeverArchivedBehindYourBack() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        let codex = try CodexDatabase(home, """
            INSERT INTO threads VALUES ('c1', 'First', 0, 1000), ('c2', 'Second', 0, 900), ('c3', 'Third', 0, 800), ('c4', 'Fourth', 0, 700);
            INSERT INTO external_agent_config_imports VALUES ('a', 2000, '[{"item_type":"SESSIONS","target":"c1"},
                {"item_type":"SESSIONS","target":"c2"},{"item_type":"SESSIONS","target":"c3"},{"item_type":"SESSIONS","target":"c4"}]', '[]', 'claude-code');
            """)
        let applier = SetupApplier(context: home.context(run: codex.run()))
        let plan = { try #require(ImportSyncSetup.scan(home.context(run: codex.run())).changes.first) }
        let reviewed = try plan()
        let changed = ["changed since you reviewed it"]

        // Continued in Codex after the review: nothing is archived, and the next plan leaves that chat out.
        codex.execute("UPDATE threads SET recency_at_ms = 2600 WHERE id = 'c2'")
        let continued = applier.apply([reviewed])
        #expect(continued.applied.isEmpty && continued.skipped.map(\.reason) == changed && codex.archived.isEmpty)
        let withoutC2 = try plan()
        #expect(withoutC2.operations.map { guard case .codexChat(let id, true, _) = $0 else { return "?" }; return id } == ["c1", "c3", "c4"])

        // Deleted after the review: nothing is archived either.
        codex.execute("DELETE FROM threads WHERE id = 'c4'")
        #expect(applier.apply([withoutC2]).skipped.map(\.reason) == changed && codex.archived.isEmpty)

        // Archived by hand after the review: left as it is, the rest is archived, and Undo brings back only that.
        let fresh = try plan()
        #expect(fresh.operations == [FileOperation.codexChat(id: "c1", archive: true, recency: 1000), .codexChat(id: "c3", archive: true, recency: 800)])
        codex.execute("UPDATE threads SET archived = 1 WHERE id = 'c3'")
        let result = applier.apply([fresh])
        #expect(result.applied.count == 1 && result.skipped.isEmpty && codex.archived == ["c1", "c3"])
        #expect(result.applied.first?.undo == [FileOperation.codexChat(id: "c1", archive: false, recency: 1000)])
        try applier.undo(try #require(result.applied.first).id)
        #expect(codex.archived == ["c3"])
    }

    @Test func aChatBroughtBackByHandStaysAndUndoStillWorks() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        let codex = try CodexDatabase(home, """
            INSERT INTO threads VALUES ('c1', 'First', 0, 1000), ('c2', 'Second', 0, 900);
            INSERT INTO external_agent_config_imports VALUES ('a', 2000,
                '[{"item_type":"SESSIONS","target":"c1"},{"item_type":"SESSIONS","target":"c2"}]', '[]', 'claude-code');
            """)
        let applier = SetupApplier(context: home.context(run: codex.run()))
        let result = applier.apply([try #require(ImportSyncSetup.scan(home.context(run: codex.run())).changes.first)])
        #expect(codex.archived == ["c1", "c2"])

        codex.execute("UPDATE threads SET archived = 0 WHERE id = 'c2'")
        let again = ImportSyncSetup.scan(home.context(run: codex.run()))
        #expect(again.changes.isEmpty && again.summary == "Off · nothing left over")
        #expect(again.items.map(\.note) == ["1 still in Codex's list; you brought back 1"])

        // Undo brings back the other one and leaves the one already back as it is.
        try applier.undo(try #require(result.applied.first).id)
        #expect(codex.archived.isEmpty)
    }

    @Test func appliesThenFindsNothingLeftAndUndoesByteForByte() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", config)
        try home.write(".cursor/skills-cursor/canvas/SKILL.md", "Use the Cursor canvas.\n")
        try home.write(".agents/skills/canvas/SKILL.md", "Use the Codex canvas.\n")
        try home.write(".agents/skills/canvas/scripts/draw.sh", "echo draw\n")
        try home.write(".claude/skills/wai-school-publish/SKILL.md", "Publish without Claude.\n")
        try home.write(".agents/skills/wai-school-publish/SKILL.md", "Publish without Codex.\n")
        try home.write(".claude/skills/screencast/scripts/caption.sh", "echo\n")
        try home.write(".agents/skills/screencast/scripts/caption.sh", "echo\n")
        try home.write(".agents/skills/liquid-glass/SKILL.md", "Glass.\n")
        try home.link(".claude/skills/liquid-glass", to: "../../.agents/skills/liquid-glass")
        try home.write(".claude/skills/synced/org_acct/pdf/SKILL.md", "Claude reads PDFs.\n")
        try home.write(".agents/skills/synced/org_acct/pdf/SKILL.md", "Codex reads PDFs.\n")
        try home.write(".agents/skills/apple-design/SKILL.md", "Not Import's.\n")
        let rows = [row("cursor", "SKILLS", "canvas"), row("claude-code", "SKILLS", "wai-school-publish"), row("claude-code", "SKILLS", "screencast"),
                    row("claude-code", "SKILLS", "liquid-glass"), row("claude-code", "SKILLS", "synced"), row("claude-code", "PLUGINS", "slack@claude-plugins-official")]
        let context = home.context(run: sqlite(rows))
        let watched = [".agents", ".claude", ".codex", ".cursor"]
        let before = home.snapshot(watched)

        let report = ImportSyncSetup.scan(context)
        #expect(home.snapshot(watched) == before)   // scanning only reads
        #expect(report.summary == "Keep imports in sync is on · 4 copied skills")
        #expect(report.changes.map(\.title) == ["Turn off ChatGPT's Keep imports in sync", "Remove 4 skills ChatGPT Import copied"])

        let applier = SetupApplier(context: context)
        let result = applier.apply(report.changes)
        #expect(result.applied.count == 2 && result.skipped.isEmpty)
        for name in ["canvas", "wai-school-publish", "screencast", "synced"] {
            #expect(!FileManager.default.fileExists(atPath: home.path(".agents/skills/\(name)")))
        }
        #expect(home.read(".agents/skills/liquid-glass/SKILL.md") == "Glass.\n" && home.read(".agents/skills/apple-design/SKILL.md") != nil)
        #expect(home.read(".claude/skills/synced/org_acct/pdf/SKILL.md") == "Claude reads PDFs.\n")

        let again = ImportSyncSetup.scan(context)
        #expect(again.changes.isEmpty && again.attention.isEmpty)
        #expect(again.summary == "Off · nothing left over")
        #expect(again.items.map(\.note) == ["ChatGPT Import added 1 to Codex"])

        for entry in applier.history().reversed() { try applier.undo(entry.id) }
        #expect(home.snapshot(watched) == before)
    }
}
