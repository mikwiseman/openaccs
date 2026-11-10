import Foundation

/// ChatGPT Import: the ChatGPT app's "Import from Claude Code" with "Keep imports in sync" copies Claude's setup into
/// Codex one way. It changes "Claude" to "Codex" inside what it copies, brings along Cursor's built-in skills and
/// Claude's account skills, and never updates what it copied. It also turns Claude Code sessions into Codex chats.
/// One setup shares Claude and Codex instead, and sessions stay with the app that made them, so this area offers to
/// turn Import's sync off, to remove the skill folders Import copied into ~/.agents/skills, and to archive the chats
/// it made. ~/AGENTS.md, which Import also writes, is left to Instructions.
public enum ImportSyncSetup {
    public static func scan(_ context: SetupContext) -> AreaReport {
        let configFile = context.url(".codex/config.toml").resolvingSymlinksInPath()
        let configData = try? Data(contentsOf: configFile)
        let config = configData.flatMap { String(data: $0, encoding: .utf8) }.flatMap(TOMLFile.init(text:))
        let sync = config?.value(syncKey, in: ["desktop"])
        let ledger = self.ledger(context)
        guard sync != nil || ledger?.isEmpty == false else { return AreaReport(area: .importSync, summary: "Not used") }

        var attention: [Attention] = [], changes: [SetupChange] = [], items: [SetupItem] = []
        let isOn = sync == .bool(true)
        if isOn, var edited = config {
            let id = "importSync.turn-off"
            let fixable = edited.set(syncKey, .bool(false), in: ["desktop"])
            attention.append(Attention(id: "importSync.on", text: "ChatGPT Import still copies Claude into Codex", fixes: fixable ? [id] : []))
            if fixable {
                changes.append(SetupChange(
                    id: id, area: .importSync, title: "Turn off ChatGPT's Keep imports in sync",
                    detail: "In ~/.codex/config.toml, \(syncKey) under [desktop] becomes false. Nothing else in the file changes.",
                    operations: [.toml(path: configFile.path, table: ["desktop"], key: syncKey, value: .bool(false), expected: sync)],
                    waitsFor: .chatGPT))
            }
        }

        // What Import put in ~ itself; items it put in a project stay with that project.
        let home = (ledger ?? []).filter { $0.cwd == nil || $0.cwd == context.home.path }
        var copies: [(name: String, why: String)] = []
        if ledger != nil {
            let agentsDir = context.url(".agents/skills")
            // Commands come out as skills too.
            let imported = Dictionary(home.filter { $0.itemType == "SKILLS" || $0.itemType == "COMMANDS" }.compactMap { row in row.target.map { ($0, row) } },
                                      uniquingKeysWith: { _, last in last })
            var names = Set(imported.keys)
            // Account skills stay with each account, so a copy goes whoever made it.
            if copiesAccountSkills(context) { names.insert(SkillsSetup.reserved) }
            // A copy that a link in ~/.claude/skills leads into is in use: it stays.
            let linked = SkillsSetup.entries(in: context.url(".claude/skills")).values.filter(\.isLink).compactMap(\.real)
            for name in names.sorted() where !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") {
                let folder = agentsDir.appending(path: name)
                guard FileState.of(folder) == .folder else { continue }
                let real = folder.resolvingSymlinksInPath().path
                guard !linked.contains(where: { $0 == real || $0.hasPrefix(real + "/") }) else { continue }
                copies.append((name, why(name, imported[name], folder: folder, context)))
            }
            if !copies.isEmpty {
                changes.append(SetupChange(
                    id: "importSync.remove-copies", area: .importSync,
                    title: copies.count == 1 ? "Remove 1 skill ChatGPT Import copied" : "Remove \(copies.count) skills ChatGPT Import copied",
                    detail: "These folders in ~/.agents/skills go to Backups:\n" + copies.map { "\($0.name): \($0.why)" }.joined(separator: "\n"),
                    operations: copies.map { .remove(path: agentsDir.appending(path: $0.name).path, expected: .folder) },
                    requires: isOn ? ["importSync.turn-off"] : []))
            }
            items = copies.map { SetupItem(id: "importSync.skill.\($0.name)", name: $0.name, claude: .notShared, codex: .same, note: $0.why) }
            for (type, id, name) in [("MCP_SERVER_CONFIG", "importSync.mcp", "MCP servers"), ("PLUGINS", "importSync.plugins", "Plugins")] {
                let added = Set(home.filter { $0.itemType == type }.compactMap(\.target)).count
                if added > 0 { items.append(SetupItem(id: id, name: name, claude: .notShared, codex: .same, note: "ChatGPT Import added \(added) to Codex")) }
            }
        }

        // Chats Import made from Claude sessions, in every project. One Codex has continued is Codex's now, and one
        // OpenAccs archived that is back in the list was brought back on purpose: both stay.
        let chats: [Chat]? = ledger?.contains { $0.itemType == "SESSIONS" } == true ? self.chats(context) : []
        let archivedBefore = Set(SetupApplier(context: context).history().flatMap(\.undo).compactMap { operation -> String? in
            guard case .codexChat(let id, false, _) = operation else { return nil }
            return id
        })
        let continued = (chats ?? []).filter { $0.continued != 0 }.count
        let broughtBack = (chats ?? []).filter { $0.continued == 0 && archivedBefore.contains($0.id) }.count
        let copied = (chats ?? []).filter { $0.continued == 0 && !archivedBefore.contains($0.id) }
        if !copied.isEmpty {
            let one = copied.count == 1, kept = continued + broughtBack
            let why = broughtBack == 0 ? "Codex continued" : continued == 0 ? "you brought back" : "Codex continued or you brought back"
            changes.append(SetupChange(
                id: "importSync.archive-chats", area: .importSync,
                title: one ? "Archive 1 chat ChatGPT Import copied into Codex" : "Archive \(copied.count) chats ChatGPT Import copied into Codex",
                detail: (one ? "It moves to Archived chats in Codex, where it can be restored. The session it was copied from stays where it is."
                             : "They move to Archived chats in Codex, where each one can be restored. The sessions they were copied from stay where they are.")
                    + (kept == 0 ? "" : " \(kept) that \(why) \(kept == 1 ? "stays" : "stay")."),
                operations: copied.map { .codexChat(id: $0.id, archive: true, recency: $0.recency) },
                waitsFor: .chatGPT,
                requires: isOn ? ["importSync.turn-off"] : []))
        }
        if let chats, !chats.isEmpty {
            items.append(SetupItem(id: "importSync.chats", name: "Chats", claude: .notShared, codex: .same,
                                   note: "\(chats.count) still in Codex's list" + (continued == 0 ? "" : "; Codex continued \(continued)")
                                       + (broughtBack == 0 ? "" : "; you brought back \(broughtBack)")))
        }

        let left = [(copies.count, "copied skill"), (copied.count, "copied chat")].filter { $0.0 > 0 }
            .map { $0.0 == 1 ? "1 \($0.1)" : "\($0.0) \($0.1)s" }
        // Without the ledger, or the chats it lists, there is nothing to say about what is left over.
        let summary = ([isOn ? "Keep imports in sync is on" : "Off"]
            + (ledger == nil || chats == nil ? [] : [left.isEmpty ? "nothing left over" : left.joined(separator: " · ")])).joined(separator: " · ")
        return AreaReport(area: .importSync, summary: summary, attention: attention, changes: changes, items: items)
    }

    /// The ChatGPT app's "Keep imports in sync", in [desktop] of ~/.codex/config.toml.
    static let syncKey = "external-agent-import-sync-enabled"

    /// One item Import recorded as done, as its ledger keeps it: `source` and `target` are names (a skill folder,
    /// an MCP server, a plugin) or paths (instructions, settings), and `cwd` is the project, or nil for ~.
    struct Row: Decodable, Hashable {
        var providerId: String?
        var itemType: String
        var cwd: String?
        var source: String?
        var target: String?
    }

    /// Every success in Import's ledger, `successes` being a JSON array of {item_type, cwd, source, target, title}.
    /// A session's `target` is the id of the Codex chat Import made from it.
    static let query = "SELECT i.provider_id, json_extract(s.value, '$.item_type') AS item_type, json_extract(s.value, '$.cwd') AS cwd, "
        + "json_extract(s.value, '$.source') AS source, json_extract(s.value, '$.target') AS target "
        + "FROM external_agent_config_imports AS i, json_each(i.successes) AS s "
        + "WHERE json_valid(i.successes) AND item_type IN ('SKILLS', 'COMMANDS', 'MCP_SERVER_CONFIG', 'PLUGINS', 'SESSIONS') ORDER BY i.completed_at_ms"

    /// A chat Import made from a session that is still in Codex's list (not archived), with its `recency_at_ms`.
    /// `continued` is 1 when Codex ran a turn in it after Import last wrote it: only a turn moves recency, and Import
    /// dates the chat by the session it copied, so a later turn moves it past that import.
    struct Chat: Decodable, Hashable {
        var id: String
        var recency: Int
        var continued: Int
    }

    /// The chats Import made from sessions, newest first.
    static let chatsQuery = "SELECT t.id, t.recency_at_ms AS recency, t.recency_at_ms > c.imported_at_ms AS continued FROM threads AS t JOIN ("
        + "SELECT json_extract(s.value, '$.target') AS id, MAX(i.completed_at_ms) AS imported_at_ms "
        + "FROM external_agent_config_imports AS i, json_each(i.successes) AS s "
        + "WHERE json_valid(i.successes) AND json_extract(s.value, '$.item_type') = 'SESSIONS' GROUP BY 1"
        + ") AS c ON c.id = t.id WHERE t.archived = 0 ORDER BY t.recency_at_ms DESC, t.id"

    /// Where a chat is now: `archived` 1 or 0, and its `recency_at_ms`.
    struct ChatState: Decodable, Hashable {
        var id: String
        var archived: Int
        var recency: Int
    }

    /// Import's ledger; nil when sqlite3, the database or the table is missing.
    static func ledger(_ context: SetupContext) -> [Row]? { rows(query, context) }

    /// The chats Import made that are still in Codex's list; nil when they can't be read.
    static func chats(_ context: SetupContext) -> [Chat]? { rows(chatsQuery, context) }

    /// These chats as Codex's database has them now, by id (a deleted one is missing); nil when it can't be read.
    static func chatStates(_ context: SetupContext, ids: [String]) -> [String: ChatState]? {
        // Codex's chat ids are UUIDs: an id with any other character never reaches the query.
        guard ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        let list = ids.map { "'\($0)'" }.joined(separator: ", ")
        let states: [ChatState]? = rows("SELECT id, archived, recency_at_ms AS recency FROM threads WHERE id IN (\(list))", context)
        return states.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Rows from ~/.codex/state_5.sqlite, opened read-only. A plain open sees every write, also those still in the
    /// write-ahead log, but it fails while the log's files (-wal, -shm) are absent, since a read-only open can't make
    /// them; then every write is in the file itself, and an immutable open reads it.
    static func rows<T: Decodable>(_ query: String, _ context: SetupContext) -> [T]? {
        let file = context.url(".codex/state_5.sqlite")
        for database in [file.path, file.absoluteString + "?immutable=1"] {
            guard let result = context.run(["sqlite3", "-readonly", "-json", database, query]), result.status == 0 else { continue }
            // sqlite3 prints nothing at all for no rows.
            if result.output.allSatisfy(\.isWhitespace) { return [] }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode([T].self, from: Data(result.output.utf8))
        }
        return nil
    }

    /// Why a copied folder should go, as the detail shows it.
    static func why(_ name: String, _ row: Row?, folder: URL, _ context: SetupContext) -> String {
        if name == SkillsSetup.reserved { return "copied from Claude's account skills, which stay with each account" }
        guard let copy = try? Data(contentsOf: folder.appending(path: "SKILL.md")) else { return "no SKILL.md" }
        let source = row?.source ?? name
        if row?.providerId == "cursor" {
            let builtIn = FileManager.default.fileExists(atPath: context.url(".cursor/skills-cursor/\(source)").path)
            return builtIn ? "copied from Cursor's built-in skills" : "copied from Cursor"
        }
        if row?.itemType == "COMMANDS" { return "made from a Claude command" }
        let original = try? Data(contentsOf: context.url(".claude/skills/\(source)/SKILL.md"))
        return original.map { $0 != copy } == true ? "copied from Claude with words changed" : "copied from Claude"
    }

    /// ~/.agents/skills/synced holds only account folders that ~/.claude/skills/synced has, where Claude keeps the
    /// skills of each signed-in account. Its files may differ: Import changes words inside them.
    static func copiesAccountSkills(_ context: SetupContext) -> Bool {
        let names = { (relative: String) in Set((try? FileManager.default.contentsOfDirectory(atPath: context.url(relative).path)) ?? []) }
        let copy = names(".agents/skills/synced")
        return !copy.isEmpty && copy.isSubset(of: names(".claude/skills/synced"))
    }
}
