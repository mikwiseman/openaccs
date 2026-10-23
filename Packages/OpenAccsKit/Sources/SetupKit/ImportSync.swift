import Foundation

/// ChatGPT Import: the ChatGPT app's "Import from Claude Code" with "Keep imports in sync" copies Claude's setup into
/// Codex one way. It changes "Claude" to "Codex" inside what it copies, brings along Cursor's built-in skills and
/// Claude's account skills, and never updates what it copied. One setup shares Claude and Codex instead, so this area
/// offers to turn Import's sync off and to remove the skill folders Import copied into ~/.agents/skills.
/// ~/AGENTS.md, which Import also writes, is left to Instructions.
public enum ImportSyncSetup {
    public static func scan(_ context: SetupContext) -> AreaReport {
        let configFile = context.url(".codex/config.toml")
        let configData = try? Data(contentsOf: configFile)
        let config = configData.flatMap { String(data: $0, encoding: .utf8) }.flatMap(TOMLFile.init(text:))
        let sync = config?.value(syncKey, in: ["desktop"])
        let ledger = self.ledger(context)
        guard sync != nil || ledger?.isEmpty == false else { return AreaReport(area: .importSync, summary: "Not used") }

        var attention: [Attention] = [], changes: [SetupChange] = [], items: [SetupItem] = []
        let isOn = sync == .bool(true)
        if isOn, let configData, var edited = config {
            let id = "importSync.turn-off"
            let fixable = edited.set(syncKey, .bool(false), in: ["desktop"])
            attention.append(Attention(id: "importSync.on", text: "ChatGPT Import still copies Claude into Codex", fixes: fixable ? [id] : []))
            if fixable {
                changes.append(SetupChange(
                    id: id, area: .importSync, title: "Turn off ChatGPT's Keep imports in sync",
                    detail: "In ~/.codex/config.toml, \(syncKey) under [desktop] becomes false. Nothing else in the file changes.",
                    operations: [.write(path: configFile.path, contents: Data(edited.text.utf8), expected: .file(contents: configData))],
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
                    operations: copies.map { .remove(path: agentsDir.appending(path: $0.name).path, expected: .folder) }))
            }
            items = copies.map { SetupItem(id: "importSync.skill.\($0.name)", name: $0.name, claude: .notShared, codex: .same, note: $0.why) }
            for (type, id, name) in [("MCP_SERVER_CONFIG", "importSync.mcp", "MCP servers"), ("PLUGINS", "importSync.plugins", "Plugins")] {
                let added = Set(home.filter { $0.itemType == type }.compactMap(\.target)).count
                if added > 0 { items.append(SetupItem(id: id, name: name, claude: .notShared, codex: .same, note: "ChatGPT Import added \(added) to Codex")) }
            }
        }

        let left = copies.isEmpty ? "nothing left over" : copies.count == 1 ? "1 copied skill" : "\(copies.count) copied skills"
        // Without the ledger there is nothing to say about what is left over.
        let summary = ([isOn ? "Keep imports in sync is on" : "Off"] + (ledger == nil ? [] : [left])).joined(separator: " · ")
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
    static let query = "SELECT i.provider_id, json_extract(s.value, '$.item_type') AS item_type, json_extract(s.value, '$.cwd') AS cwd, "
        + "json_extract(s.value, '$.source') AS source, json_extract(s.value, '$.target') AS target "
        + "FROM external_agent_config_imports AS i, json_each(i.successes) AS s "
        + "WHERE json_valid(i.successes) AND item_type IN ('SKILLS', 'COMMANDS', 'MCP_SERVER_CONFIG', 'PLUGINS') ORDER BY i.completed_at_ms"

    /// Import's ledger in ~/.codex/state_5.sqlite, opened read-only; nil when sqlite3, the database or the table is missing.
    static func ledger(_ context: SetupContext) -> [Row]? {
        guard let result = context.run(["sqlite3", "-readonly", "-json", context.url(".codex/state_5.sqlite").path, query]),
              result.status == 0 else { return nil }
        // sqlite3 prints nothing at all for no rows.
        if result.output.allSatisfy(\.isWhitespace) { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode([Row].self, from: Data(result.output.utf8))
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
