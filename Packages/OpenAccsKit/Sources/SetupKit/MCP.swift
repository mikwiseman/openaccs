import Foundation
import OpenAccsCore

/// MCP servers: the same servers in Claude Code and Codex, matched by name.
///
/// Claude's are its user-scope servers, the top-level `mcpServers` of ~/.claude.json. That file is large and every
/// running Claude Code writes it, so OpenAccs only reads it and changes servers with `claude mcp add-json` and
/// `claude mcp remove`. Per-project servers stay where they are. Codex's are the [mcp_servers.<name>] tables of
/// ~/.codex/config.toml, rewritten with every other byte kept, while ChatGPT is closed (it keeps the file in memory).
///
/// A server is translated field by field (`MCPSpec`); what only one tool has stays on its side. Only ${VAR}
/// references travel: a server with a key written into its settings is not copied anywhere. One record per server
/// (setup-mcp/) holds what each side held at the last sync, which tells an addition from a removal and one side's
/// change from changes on both.
public enum MCPSetup {
    public static func scan(_ context: SetupContext) -> AreaReport {
        var configFile = context.url(".codex/config.toml")
        // A config.toml that links into a dotfiles folder is edited where it points, so it stays a link.
        if case .link = FileState.of(configFile) { configFile = configFile.resolvingSymlinksInPath() }
        let configData = try? Data(contentsOf: configFile)
        guard let claude = readClaude(context) else { return unreadable("~/.claude.json") }
        guard configData != nil || FileState.of(configFile) == .absent,
              let codex = TOMLFile(text: configData.map { String(decoding: $0, as: UTF8.self) } ?? "") else {
            return unreadable("~/.codex/config.toml")
        }
        let codexServers = codex.mcpServers
        let codexPlugins = (codex.value("plugins", in: [])?.table ?? [:]).filter { $0.value.table?["enabled"] != .bool(false) }.keys.sorted()
        let records = Self.records(context)
        let names = Set(claude.servers.keys).union(codexServers.keys).sorted()
        var plans: [String: Plan] = [:]
        for name in names {
            plans[name] = plan(claude: claude.servers[name].map(translate(claude:)), codex: codexServers[name].map(translate(codex:)),
                               record: records[name], projects: claude.projects[name] ?? 0,
                               claudePlugin: plugin(name, in: claude.plugins), codexPlugin: plugin(name, in: codexPlugins))
        }

        var uneditable = Set<String>()
        func editCodex(_ edits: [(name: String, spec: MCPSpec?)]) -> (writes: [FileOperation], done: [String])? {
            var writes: [FileOperation] = [], done: [String] = []
            for (name, spec) in edits {
                var next = codex
                let value = spec.map { TOMLValue.table(codexTable($0, keeping: codexServers[name]?.table ?? [:])) }
                if next.setServer(name, value) {
                    writes.append(.toml(path: configFile.path, table: ["mcp_servers"], key: name, value: value, expected: codexServers[name]))
                    done.append(name)
                } else { uneditable.insert(name) }
            }
            return done.isEmpty ? nil : (writes, done)
        }
        func editClaude(_ name: String, _ spec: MCPSpec?) -> [FileOperation] {
            let old = claude.servers[name] as? [String: Any]
            return [.claudeMCP(name: name, value: spec.map { json(claudeEntry($0, keeping: old ?? [:])) }, expected: old.map { json($0) })]
        }
        func remember(_ name: String, _ spec: MCPSpec?) -> FileOperation? {
            let file = recordFile(name, context), state = FileState.of(file)
            guard let spec else { return state == .absent ? nil : .remove(path: file.path, expected: state) }
            let record = Record(name: name, claude: hash(spec), codex: hash(spec))
            guard let data = try? JSON.encoder.encode(record) else { return nil }
            return .write(path: file.path, contents: data, expected: state)
        }
        /// One server written to `tool`, with its record.
        func change(_ id: String, _ title: String, _ name: String, _ spec: MCPSpec?, to tool: Tool) -> SetupChange? {
            var operations: [FileOperation]
            if tool == .codex {
                guard let edit = editCodex([(name, spec)]) else { return nil }
                operations = edit.writes
            } else {
                operations = editClaude(name, spec)
            }
            operations += [remember(name, spec)].compactMap { $0 }
            return SetupChange(id: id, area: .mcp, title: title, detail: diff(name, to: spec, on: tool, claude: claude, codex: codexServers),
                               operations: operations, waitsFor: tool == .codex ? .chatGPT : nil)
        }

        var changes: [SetupChange] = [], attention: [Attention] = []
        // Servers new on one side: one change for each tool that gets them.
        for tool in [Tool.codex, .claude] {
            let added = names.compactMap { name -> (name: String, spec: MCPSpec?)? in
                guard case .copy(let spec?, tool, .added) = plans[name] else { return nil }
                return (name, spec)
            }
            guard !added.isEmpty else { continue }
            var operations: [FileOperation], done: [String]
            if tool == .codex {
                guard let edit = editCodex(added) else { continue }
                (operations, done) = (edit.writes, edit.done)
            } else {
                (operations, done) = (added.flatMap { editClaude($0.name, $0.spec) }, added.map(\.name))
            }
            operations += added.filter { done.contains($0.name) }.compactMap { remember($0.name, $0.spec) }
            let from = tool.other.name
            changes.append(SetupChange(
                id: "mcp.\(tool).add", area: .mcp,
                title: done.count == 1 ? "\(tool.name) gets \(done[0]) from \(from)" : "\(tool.name) gets \(done.count) servers from \(from)",
                detail: (tool == .codex ? "New tables in ~/.codex/config.toml, every other line kept: " : "Added with claude mcp add-json --scope user: ")
                    + done.joined(separator: ", "),
                operations: operations, waitsFor: tool == .codex ? .chatGPT : nil))
        }
        // Changed or removed on one side since the last sync: one change per server, so each can stay as it is.
        for why in [Why.changed, .removed] {
            for name in names {
                guard case .copy(let spec, let tool, why) = plans[name] else { continue }
                let title = why == .changed ? "\(tool.name) gets \(tool.other.name)'s changes to \(name)" : "Remove \(name) from \(tool.name)"
                if let change = change("mcp.\(tool).\(why).\(name)", title, name, spec, to: tool) { changes.append(change) }
            }
        }
        // Changed in both, or different at the first sync: the user picks a side.
        for name in names {
            guard case .conflict(let claudeSpec, let codexSpec, let changedInBoth) = plans[name] else { continue }
            let picks = [change("mcp.use-claude.\(name)", "Use Claude's \(name)", name, claudeSpec, to: .codex),
                         change("mcp.use-codex.\(name)", "Use Codex's \(name)", name, codexSpec, to: .claude)].compactMap { $0 }
            changes += picks
            attention.append(Attention(id: "mcp.conflict.\(name)", text: changedInBoth ? "\(name) changed in both" : "\(name) differs between Claude and Codex",
                                       fixes: picks.map(\.id)))
        }

        // Records of servers that are the same on both sides, and of ones gone from both. They are true whatever else
        // applies, so they go with a change that needs no app closed, or in one of their own.
        var carried = names.compactMap { name -> FileOperation? in
            guard case .same(let spec) = plans[name], records[name] != Record(name: name, claude: hash(spec), codex: hash(spec)) else { return nil }
            return remember(name, spec)
        }
        carried += records.keys.sorted().filter { !names.contains($0) }.compactMap { remember($0, nil) }
        if !carried.isEmpty {
            let picks = Set(attention.flatMap(\.fixes))
            if let i = changes.firstIndex(where: { !picks.contains($0.id) && $0.waitsFor == nil }) ?? changes.firstIndex(where: { !picks.contains($0.id) }) {
                changes[i].operations += carried
            } else {
                changes.append(SetupChange(
                    id: "mcp.remember", area: .mcp,
                    title: carried.count == 1 ? "Remember 1 server as it is now" : "Remember \(carried.count) servers as they are now",
                    detail: "So a server later changed or removed on one side changes the same way on the other. Only OpenAccs's own records change.",
                    operations: carried))
            }
        }

        let waits = context.isRunning(.chatGPT)
        var items: [SetupItem] = []
        var inBoth = 0, differ = 0, onlyClaude = 0, onlyCodex = 0
        for name in names {
            let inClaude = claude.servers[name] != nil, inCodex = codexServers[name] != nil
            switch (inClaude, inCodex) {
            case (true, true): inBoth += 1
            case (true, false): onlyClaude += 1
            default: onlyCodex += 1
            }
            var item = SetupItem(id: name, name: name, claude: .same, codex: .same)
            switch plans[name] {
            case .unshared(let why)?:
                (item.claude, item.codex, item.note) = (.notShared, .notShared, why)
            case .copy(_, let tool, let why)?:
                let target: SetupItem.Presence = tool == .codex && waits ? .waiting : why == .added ? .missing : .differs
                let source: SetupItem.Presence = why == .removed ? .missing : .same
                (item.claude, item.codex) = tool == .codex ? (source, target) : (target, source)
                let from = tool.other.name
                item.note = switch why {
                case .added: "Only in \(from)"
                case .changed: "Changed in \(from) since the last sync"
                case .removed: "Removed from \(from) since the last sync"
                }
            case .conflict(let claudeSpec, let codexSpec, let changedInBoth)?:
                item.claude = claudeSpec == nil ? .missing : .differs
                item.codex = codexSpec == nil ? .missing : .differs
                item.note = changedInBoth ? "Changed in both since the last sync"
                    : "Differs in " + differences(claudeSpec ?? MCPSpec(), codexSpec ?? MCPSpec()).joined(separator: ", ")
            case .same?, nil:
                break
            }
            if inClaude, inCodex, item.claude == .differs || item.codex == .differs || item.codex == .waiting { differ += 1 }
            if uneditable.contains(name) { (item.claude, item.codex, item.note) = (.notShared, .notShared, "Its text in config.toml can't be changed cleanly") }
            items.append(item)
        }

        let parts = [inBoth > 0 ? "\(inBoth) in both" : nil,
                     differ > 0 ? (differ == 1 ? "1 differs" : "\(differ) differ") : nil,
                     onlyCodex > 0 ? "\(onlyCodex) only in Codex" : nil,
                     onlyClaude > 0 ? "\(onlyClaude) only in Claude" : nil].compactMap { $0 }
        let summary = parts.isEmpty ? "No MCP servers in Claude or Codex" : parts.joined(separator: " · ")
        return AreaReport(area: .mcp, summary: summary, attention: attention, changes: changes, items: items)
    }

    // MARK: Rules

    enum Tool: String, Equatable, CustomStringConvertible {
        case claude, codex
        var name: String { self == .claude ? "Claude" : "Codex" }
        var other: Tool { self == .claude ? .codex : .claude }
        var description: String { rawValue }
    }

    enum Why: String, CustomStringConvertible {
        case added, changed, removed
        var description: String { rawValue }
    }

    /// What one server needs.
    enum Plan: Equatable {
        case same(MCPSpec)
        case unshared(String)
        /// Make `to` hold the spec, or drop the server when nil.
        case copy(MCPSpec?, to: Tool, Why)
        /// The user picks a side; `changedInBoth` is false at the first sync.
        case conflict(claude: MCPSpec?, codex: MCPSpec?, changedInBoth: Bool)
    }

    /// The rules, for one server name. `projects` counts the Claude projects that have a server of that name; the
    /// plugins are the ones each tool would get a server of that name from.
    static func plan(claude: Translation?, codex: Translation?, record: Record?, projects: Int,
                     claudePlugin: String?, codexPlugin: String?) -> Plan {
        if case .unshared(let why)? = claude { return .unshared(why) }
        if case .unshared(let why)? = codex { return .unshared(why) }
        switch (claude?.spec, codex?.spec) {
        case (let mine?, let theirs?):
            if mine == theirs { return .same(mine) }
            guard let record else { return .conflict(claude: mine, codex: theirs, changedInBoth: false) }
            let claudeChanged = hash(mine) != record.claude, codexChanged = hash(theirs) != record.codex
            if claudeChanged, !codexChanged { return .copy(mine, to: .codex, .changed) }
            if codexChanged, !claudeChanged { return .copy(theirs, to: .claude, .changed) }
            return .conflict(claude: mine, codex: theirs, changedInBoth: claudeChanged && codexChanged)
        case (let mine?, nil):
            if let record {
                return hash(mine) == record.claude ? .copy(nil, to: .claude, .removed) : .conflict(claude: mine, codex: nil, changedInBoth: true)
            }
            if let codexPlugin { return .unshared("Codex gets it from its plugin \(codexPlugin)") }
            return .copy(mine, to: .codex, .added)
        case (nil, let theirs?):
            if let record {
                return hash(theirs) == record.codex ? .copy(nil, to: .codex, .removed) : .conflict(claude: nil, codex: theirs, changedInBoth: true)
            }
            if projects > 0 { return .unshared("Claude has it in \(projects == 1 ? "1 project" : "\(projects) projects") only") }
            if let claudePlugin { return .unshared("Claude gets it from its plugin \(claudePlugin)") }
            return .copy(theirs, to: .claude, .added)
        case (nil, nil):
            return .unshared("")
        }
    }

    /// The enabled plugin whose name (before the @) is `name`.
    static func plugin(_ name: String, in plugins: [String]) -> String? {
        plugins.first { $0.split(separator: "@").first.map(String.init) == name }
    }

    // MARK: Translating

    /// What both tools can say about one server. A server translated to the other tool reads back as the same spec,
    /// so a server and its copy hash alike.
    struct MCPSpec: Encodable, Hashable, Sendable {
        /// A stdio server's command line.
        var command: String?
        var args: [String] = []
        /// Variables passed on from the environment under their own names.
        var envVars: [String] = []
        /// An HTTP server.
        var url: String?
        /// The variable sent as `Authorization: Bearer …`.
        var bearerTokenEnvVar: String?
        /// Header → the variable its value comes from.
        var envHeaders: [String: String] = [:]
        /// A command that prints the headers.
        var headersHelper: String?
        var timeoutMs: Int?
    }

    /// One side's server: the spec both tools share, or why it stays on its side.
    enum Translation: Equatable {
        case spec(MCPSpec)
        case unshared(String)
        var spec: MCPSpec? { if case .spec(let spec) = self { spec } else { nil } }
    }

    static let keyNote = "The key is written in the file. Use ${VAR} to share it."
    static let cantTranslate = "OpenAccs can't translate its settings"

    /// Claude's fields that translate. Any other field is Claude's own and stays when Claude's side is rewritten.
    static let claudeFields: Set<String> = ["type", "command", "args", "env", "url", "headers", "headersHelper", "timeout"]
    /// Codex's fields that translate (`env` and `http_headers` hold keys). Any other field (enabled_tools,
    /// startup_timeout_sec, tools, cwd…) is Codex's own and stays when Codex's side is rewritten.
    static let codexFields: Set<String> = ["command", "args", "env", "env_vars", "url", "bearer_token_env_var", "http_headers",
                                           "env_http_headers", "http_headers_helper", "tool_timeout_sec"]

    static func translate(claude value: Any) -> Translation {
        guard let entry = value as? [String: Any] else { return .unshared(cantTranslate) }
        /// A field's value as T, `empty` when it is missing; nil when it is something else.
        func field<T>(_ key: String, _ empty: T) -> T? { entry[key] == nil ? empty : entry[key] as? T }
        var spec = MCPSpec()
        switch entry["type"] as? String ?? (entry["url"] == nil ? "stdio" : "http") {
        case "stdio":
            guard let command = entry["command"] as? String, let args = field("args", [String]()),
                  let env = field("env", [String: String]()) else { return .unshared(cantTranslate) }
            (spec.command, spec.args) = (command, args)
            for (name, value) in env.sorted(by: { $0.key < $1.key }) {
                guard let variable = reference(value) else { return .unshared(keyNote) }
                guard variable == name else { return .unshared("Codex can pass \(name) only from a variable of the same name") }
                spec.envVars.append(name)
            }
        case "http":
            guard let url = entry["url"] as? String, let headers = field("headers", [String: String]()),
                  let helper = field("headersHelper", Optional<String>.none) else { return .unshared(cantTranslate) }
            (spec.url, spec.headersHelper) = (url, helper)
            for (header, value) in headers {
                if header.lowercased() == "authorization", value.hasPrefix("Bearer "), let variable = reference(String(value.dropFirst(7))) {
                    spec.bearerTokenEnvVar = variable
                } else if let variable = reference(value) {
                    spec.envHeaders[header] = variable
                } else {
                    return .unshared(keyNote)
                }
            }
        case "sse": return .unshared("Codex has no SSE servers")
        case "ws": return .unshared("Codex has no WebSocket servers")
        case let type: return .unshared("Codex has no \(type) servers")
        }
        guard let timeout = field("timeout", Optional<Int>.none) else { return .unshared(cantTranslate) }
        spec.timeoutMs = timeout
        return checked(spec)
    }

    static func translate(codex value: TOMLValue) -> Translation {
        guard let table = value.table else { return .unshared(cantTranslate) }
        if table["env"] != nil || table["http_headers"] != nil { return .unshared(keyNote) }
        /// A list of strings, [] when missing; nil when it is something else.
        func strings(_ key: String) -> [String]? {
            guard let value = table[key] else { return [] }
            let items = value.array ?? [], strings = items.compactMap(\.string)
            return value.array != nil && strings.count == items.count ? strings : nil
        }
        /// A string, `.some(nil)` when missing; nil when it is something else.
        func string(_ key: String) -> String?? { table[key].map { $0.string.map(Optional.some) } ?? .some(nil) }
        var spec = MCPSpec()
        switch (table["command"], table["url"]) {
        case (.string(let command)?, nil):
            guard let args = strings("args"), let envVars = strings("env_vars") else { return .unshared(cantTranslate) }
            (spec.command, spec.args, spec.envVars) = (command, args, envVars.sorted())
        case (nil, .string(let url)?):
            let headers = table["env_http_headers"].map { $0.table?.compactMapValues(\.string) } ?? [:]
            guard let bearer = string("bearer_token_env_var"), let helper = string("http_headers_helper"), let headers,
                  headers.count == table["env_http_headers"]?.table?.count ?? 0 else { return .unshared(cantTranslate) }
            (spec.url, spec.bearerTokenEnvVar, spec.headersHelper, spec.envHeaders) = (url, bearer, helper, headers)
        case (nil, nil):
            return .unshared("It has neither a command nor a URL")
        default:
            return .unshared(cantTranslate)
        }
        switch table["tool_timeout_sec"] {
        case nil: break
        case .integer(let seconds)?: spec.timeoutMs = seconds * 1000
        case .float(let seconds)? where seconds.isFinite: spec.timeoutMs = Int((seconds * 1000).rounded())
        default: return .unshared(cantTranslate)
        }
        return checked(spec)
    }

    /// The spec, unless the server must stay where it is anyway.
    static func checked(_ spec: MCPSpec) -> Translation {
        if let command = spec.command, command.contains(".app/") {
            let app = command.split(separator: "/").first { $0.hasSuffix(".app") }.map(String.init) ?? "an app"
            return .unshared("Runs from inside \(app), so it stays with that app")
        }
        // Claude expands ${VAR} in these; Codex passes them on as they are.
        if ([spec.command, spec.url].compactMap { $0 } + spec.args).contains(where: { $0.contains("${") }) {
            return .unshared("Uses ${…} in its command or URL, which only Claude expands")
        }
        return .spec(spec)
    }

    /// The variable a value names when it is exactly `${NAME}`. Anything else counts as a key written into the file.
    static func reference(_ value: String) -> String? {
        value.wholeMatch(of: /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/).map { String($0.1) }
    }

    /// Claude's entry for `spec`, keeping the fields only Claude has from `old`.
    static func claudeEntry(_ spec: MCPSpec, keeping old: [String: Any] = [:]) -> [String: Any] {
        var entry = old.filter { !claudeFields.contains($0.key) }
        if let command = spec.command {
            (entry["type"], entry["command"]) = ("stdio", command)
            if !spec.args.isEmpty { entry["args"] = spec.args }
            if !spec.envVars.isEmpty { entry["env"] = Dictionary(uniqueKeysWithValues: spec.envVars.map { ($0, "${\($0)}") }) }
        } else if let url = spec.url {
            (entry["type"], entry["url"]) = ("http", url)
            var headers = spec.envHeaders.mapValues { "${\($0)}" }
            if let bearer = spec.bearerTokenEnvVar { headers["Authorization"] = "Bearer ${\(bearer)}" }
            if !headers.isEmpty { entry["headers"] = headers }
            if let helper = spec.headersHelper { entry["headersHelper"] = helper }
        }
        if let timeout = spec.timeoutMs { entry["timeout"] = timeout }
        return entry
    }

    /// Codex's table for `spec`, keeping the fields only Codex has from `old`.
    static func codexTable(_ spec: MCPSpec, keeping old: [String: TOMLValue] = [:]) -> [String: TOMLValue] {
        var table = old.filter { !codexFields.contains($0.key) }
        if let command = spec.command {
            table["command"] = .string(command)
            if !spec.args.isEmpty { table["args"] = .array(spec.args.map(TOMLValue.string)) }
            if !spec.envVars.isEmpty { table["env_vars"] = .array(spec.envVars.map(TOMLValue.string)) }
        } else if let url = spec.url {
            table["url"] = .string(url)
            if let bearer = spec.bearerTokenEnvVar { table["bearer_token_env_var"] = .string(bearer) }
            if !spec.envHeaders.isEmpty { table["env_http_headers"] = .table(spec.envHeaders.mapValues(TOMLValue.string)) }
            if let helper = spec.headersHelper { table["http_headers_helper"] = .string(helper) }
        }
        if let timeout = spec.timeoutMs {
            table["tool_timeout_sec"] = timeout % 1000 == 0 ? .integer(timeout / 1000) : .float(Double(timeout) / 1000)
        }
        return table
    }

    /// Of a spec's canonical JSON. A spec holds no key, only variable names.
    static func hash(_ spec: MCPSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Digest.sha256((try? encoder.encode(spec)) ?? Data())
    }

    /// The fields (by Claude's names) in which two specs differ.
    static func differences(_ a: MCPSpec, _ b: MCPSpec) -> [String] {
        [("command", a.command != b.command), ("args", a.args != b.args), ("env", a.envVars != b.envVars), ("url", a.url != b.url),
         ("headers", a.bearerTokenEnvVar != b.bearerTokenEnvVar || a.envHeaders != b.envHeaders),
         ("headersHelper", a.headersHelper != b.headersHelper), ("timeout", a.timeoutMs != b.timeoutMs)].filter(\.1).map(\.0)
    }

    // MARK: Reading and writing

    /// What OpenAccs reads from Claude: its user-scope servers, how many projects have a server of each name, and
    /// its enabled plugins.
    struct ClaudeConfig {
        var servers: [String: Any] = [:]
        var projects: [String: Int] = [:]
        var plugins: [String] = []
    }

    /// nil when ~/.claude.json is there but isn't a JSON object.
    static func readClaude(_ context: SetupContext) -> ClaudeConfig? {
        var config = ClaudeConfig()
        let file = context.url(".claude.json")
        if let data = try? Data(contentsOf: file) {
            guard let object = JSON.object(data) else { return nil }
            config.servers = object["mcpServers"] as? [String: Any] ?? [:]
            for project in (object["projects"] as? [String: Any] ?? [:]).values {
                for name in ((project as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]).keys { config.projects[name, default: 0] += 1 }
            }
        } else if FileState.of(file) != .absent {
            return nil
        }
        if let data = try? Data(contentsOf: context.url(".claude/settings.json")), let settings = JSON.object(data) {
            config.plugins = (settings["enabledPlugins"] as? [String: Any] ?? [:]).filter { $0.value as? Bool == true }.keys.sorted()
        }
        return config
    }

    static func addCommand(_ name: String, _ entry: [String: Any]) -> [String] {
        ["claude", "mcp", "add-json", "--scope", "user", name, json(entry)]
    }

    static func removeCommand(_ name: String) -> [String] { ["claude", "mcp", "remove", "--scope", "user", name] }

    static func json(_ object: Any, pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data(), as: UTF8.self)
    }

    /// What writing `spec` (nil: removing it) changes on `tool`'s side, as a line diff of that side's own text.
    static func diff(_ name: String, to spec: MCPSpec?, on tool: Tool, claude: ClaudeConfig, codex: [String: TOMLValue]) -> String {
        switch tool {
        case .claude:
            let old = claude.servers[name] as? [String: Any]
            return InstructionsSetup.lineDiff(old.map { json($0, pretty: true) } ?? "",
                                              spec.map { json(claudeEntry($0, keeping: old ?? [:]), pretty: true) } ?? "")
        case .codex:
            let old = codex[name]?.table, at = ["mcp_servers", name]
            return InstructionsSetup.lineDiff(old.map { TOMLFile.render($0, at: at) } ?? "",
                                              spec.map { TOMLFile.render(codexTable($0, keeping: old ?? [:]), at: at) } ?? "")
        }
    }

    /// What both sides held at the last sync (they hold the same then). One file per server, so changes for different
    /// servers apply on their own, each with its servers' records.
    struct Record: Codable, Equatable {
        var name: String
        var claude: String
        var codex: String
    }

    static func recordFile(_ name: String, _ context: SetupContext) -> URL {
        context.paths.appSupport.appending(path: "setup-mcp/\(Digest.sha256(Data(name.utf8)).prefix(16)).json")
    }

    static func records(_ context: SetupContext) -> [String: Record] {
        let dir = context.paths.appSupport.appending(path: "setup-mcp", directoryHint: .isDirectory)
        var records: [String: Record] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? JSON.decoder.decode(Record.self, from: data) { records[record.name] = record }
        }
        return records
    }

    static func unreadable(_ file: String) -> AreaReport {
        AreaReport(area: .mcp, summary: "\(file) can't be read",
                   attention: [Attention(id: "mcp.unreadable", text: "\(file) can't be read, so no server changes", level: .broken)])
    }
}
