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

/// A fake `run` where sqlite3 prints these rows, the way it does: nothing at all for none.
private func sqlite(_ rows: [String], calls: Calls? = nil) -> @Sendable ([String]) -> (status: Int32, output: String)? {
    let output = rows.isEmpty ? "" : "[" + rows.joined(separator: ",\n") + "]\n"
    return { argv in
        calls?.argv.append(argv)
        return argv.first == "sqlite3" ? (0, output) : nil
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
        guard case .write(let path, _, _, let expected) = change.operations.first, change.operations.count == 1 else { Issue.record("not one write"); return }
        #expect(path == home.path(".codex/config.toml") && expected == .file(contents: Data(config.utf8)))

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
        #expect(calls.argv == [["sqlite3", "-readonly", "-json", home.path(".codex/state_5.sqlite"), ImportSyncSetup.query]])
        #expect(noSqlite.summary == "Keep imports in sync is on")
        #expect(noSqlite.changes.map(\.id) == ["importSync.turn-off"] && noSqlite.items.isEmpty)

        // No database or no table: sqlite3 fails.
        let noTable = ImportSyncSetup.scan(home.context { _ in (1, "Parse error: no such table: external_agent_config_imports\n") })
        #expect(noTable.summary == "Keep imports in sync is on" && noTable.changes.map(\.id) == ["importSync.turn-off"])

        let bare = try SetupHome()
        try bare.write(".agents/skills/synced/org_acct/pdf/SKILL.md", "Codex reads PDFs.\n")
        #expect(ImportSyncSetup.scan(bare.context { _ in nil }) == AreaReport(area: .importSync, summary: "Not used"))
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
