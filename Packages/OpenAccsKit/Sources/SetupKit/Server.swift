import Foundation
import OpenAccsCore

/// What `openaccs vps` copies to a server: this Mac's setup, minus what only works on a Mac and anything secret.
/// Staged in a folder first so the plan is exactly what goes; the server script (server-setup.sh) puts it in place.
public enum ServerSetup {
    public struct Plan: Sendable, Hashable {
        /// One line per thing that goes ("Instructions: CLAUDE.md, 61 lines").
        public var goes: [String] = []
        /// One line per thing left out, with why.
        public var stays: [String] = []
    }

    /// Servers that need this Mac: its apps, local builds, or files that exist only here.
    static let macOnly: Set<String> = ["swifteye", "background-computer-use", "rhino", "xcodebuildmcp", "xcodebuild",
                                       "computer-use", "node_repl", "tbank-readonly", "google-analytics"]

    /// Builds `stage` (emptied first) from the home in `context`.
    public static func stage(_ context: SetupContext, into stage: URL) throws -> Plan {
        let fm = FileManager.default
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        var plan = Plan()

        let claudeMD = context.url(".claude/CLAUDE.md")
        if let text = try? String(contentsOf: claudeMD, encoding: .utf8) {
            try fm.copyItem(at: claudeMD.resolvingSymlinksInPath(), to: stage.appending(path: "CLAUDE.md"))
            plan.goes.append("Instructions: CLAUDE.md, \(text.split(separator: "\n", omittingEmptySubsequences: false).count - 1) lines (Codex reads it through a link)")
        }

        // Skills: every valid one Claude or Codex sees, stored once; the links are resolved to real folders.
        var skills: [String: URL] = [:], hidden: Set<String> = []
        for folder in [".agents/skills", ".claude/skills", ".codex/skills"] {
            for name in ((try? fm.contentsOfDirectory(atPath: context.url(folder).path)) ?? []).sorted()
            where !name.hasPrefix(".") && name != "synced" && skills[name] == nil {
                let dir = context.url(folder).appending(path: name).resolvingSymlinksInPath()
                if fm.fileExists(atPath: dir.appending(path: "SKILL.md").path) { skills[name] = dir }
            }
        }
        if !skills.isEmpty {
            let target = stage.appending(path: "skills")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for (name, dir) in skills { hidden.formUnion(try copyResolved(dir, to: target.appending(path: name))) }
            plan.goes.append("Skills: \(skills.count)")
        }

        for part in ["agents", "commands"] {
            let dir = context.url(".claude/\(part)")
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            guard !names.isEmpty else { continue }
            hidden.formUnion(try copyResolved(dir, to: stage.appending(path: "claude/\(part)")))
            plan.goes.append("Claude \(part): \(names.count)")
        }
        hidden.subtract([".DS_Store", ".git"])
        if !hidden.isEmpty { plan.stays.append("Hidden files (\(hidden.sorted().joined(separator: ", "))): they can hold keys; copy what a skill needs yourself") }

        if let data = try? Data(contentsOf: context.url(".claude/settings.json")), let settings = JSON.object(data) {
            let (kept, dropped) = serverSettings(settings)
            try fm.createDirectory(at: stage.appending(path: "claude"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: stage.appending(path: "claude/settings.json"))
            plan.goes.append("Claude settings (\(kept.count) keys)")
            plan.stays += dropped
        }

        if let data = try? Data(contentsOf: context.url(".claude.json")),
           let servers = JSON.object(data)?["mcpServers"] as? [String: Any], !servers.isEmpty {
            let target = stage.appending(path: "claude-mcp")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var going: [String] = []
            for name in servers.keys.sorted() {
                guard let spec = servers[name] as? [String: Any] else { continue }
                if let why = whyNotPortable(name, spec) {
                    plan.stays.append("MCP \(name): \(why)")
                    continue
                }
                try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])
                    .write(to: target.appending(path: "\(name).json"))
                going.append(name)
            }
            if !going.isEmpty { plan.goes.append("MCP servers for Claude: \(going.joined(separator: ", "))") }
        }
        // Codex: the model and autonomy keys and the MCP servers that work there; no app state, projects or Mac paths.
        if let text = try? String(contentsOf: context.url(".codex/config.toml"), encoding: .utf8), let config = TOMLFile(text: text) {
            var server: [String: TOMLValue] = [:]
            for key in codexKeys { server[key] = config.value(key, in: []) }
            var going: [String] = []
            var servers: [String: TOMLValue] = [:]
            for (name, spec) in config.mcpServers.sorted(by: { $0.key < $1.key }) {
                if let why = whyNotPortable(name, codex: spec) {
                    plan.stays.append("Codex MCP \(name): \(why)")
                } else {
                    servers[name] = spec
                    going.append(name)
                }
            }
            if !servers.isEmpty { server["mcp_servers"] = .table(servers) }
            try fm.createDirectory(at: stage.appending(path: "codex"), withIntermediateDirectories: true)
            try Data(TOMLFile.render(server).utf8).write(to: stage.appending(path: "codex/config.toml"))
            plan.goes.append("Codex settings (\(server.count - (servers.isEmpty ? 0 : 1)) keys)" + (going.isEmpty ? "" : " and MCP servers: \(going.joined(separator: ", "))"))
        }
        plan.stays.append("Logins: each tool signs in on the server itself")
        return plan
    }

    /// The Codex keys a server gets; the rest of config.toml is this Mac's app state.
    static let codexKeys = ["model", "model_reasoning_effort", "plan_mode_reasoning_effort", "personality", "approval_policy",
                            "sandbox_mode", "approvals_reviewer", "project_doc_fallback_filenames", "web_search"]

    static let keyReason = "a key is written into its settings; add it on the server with your key"

    /// Why a Codex MCP server can't go as it is, or nil. Codex names its keys' variables (env_vars,
    /// bearer_token_env_var, env_http_headers), so literal env and http_headers values are keys.
    static func whyNotPortable(_ name: String, codex spec: TOMLValue) -> String? {
        let table = spec.table ?? [:]
        let args = (table["args"]?.array ?? []).compactMap(\.string)
        if macOnly.contains(name) { return "works only on a Mac" }
        if let command = table["command"]?.string, isMacPath(command) || command.contains(".app/") || command.hasPrefix("/") && !command.hasPrefix("/usr/") {
            return "runs a program on this Mac"
        }
        if args.contains(where: isMacPath) || isMacPath(table["cwd"]?.string ?? "") { return "uses files on this Mac" }
        if let helper = table["http_headers_helper"], isMacPath("\(helper)") { return "its sign-in helper is on this Mac" }
        if !(table["env"]?.table ?? [:]).isEmpty || !(table["http_headers"]?.table ?? [:]).isEmpty
            || carriesKey(args + [table["url"]?.string ?? ""]) {
            return keyReason
        }
        return nil
    }

    /// Claude settings that are plain preferences, fine on any machine. The rest stays: apiKeyHelper,
    /// otelHeadersHelper, awsAuthRefresh and the like run a command here or hold a key, and new keys are unknown.
    static let claudeKeys: Set<String> = [
        "$schema", "model", "modelSettings", "effortLevel", "alwaysThinkingEnabled", "outputStyle", "language", "theme",
        "permissions", "env", "hooks", "statusLine", "enabledPlugins", "extraKnownMarketplaces", "cleanupPeriodDays",
        "includeCoAuthoredBy", "spinnerTipsEnabled", "voice", "agentPushNotifEnabled", "inputNeededNotifEnabled",
        "skipAutoPermissionPrompt", "skipDangerousModePermissionPrompt", "skipWorkflowUsageWarning",
    ]

    /// Claude's settings as a server gets them: the known-safe keys, without what needs this Mac (PATH, hooks and a
    /// status line that run its files or tools, plugin marketplaces that are local folders with the plugins they
    /// hold) and without keys written into env.
    static func serverSettings(_ settings: [String: Any]) -> (kept: [String: Any], dropped: [String]) {
        var kept = settings.filter { claudeKeys.contains($0.key) }, dropped: [String] = []
        let unknown = settings.keys.filter { !claudeKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            dropped.append("Claude settings \(unknown.joined(separator: ", ")): not known to be safe on a server (some run a command or hold a key)")
        }
        if var env = kept["env"] as? [String: Any] {
            for (key, value) in env where key == "PATH" || isMacPath("\(value)") {
                env[key] = nil
                dropped.append("Claude setting env.\(key): points at this Mac")
            }
            // A key written into the settings never travels, whatever its name; a ${VAR} reference does.
            let secret = ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL", "HEADER", "DSN", "COOKIE"]
            for (key, value) in env where !"\(value)".hasPrefix("${") && (secret.contains(where: key.uppercased().contains) || carriesKey(["\(value)"])) {
                env[key] = nil
                dropped.append("Claude setting env.\(key): a key; set it on the server yourself")
            }
            kept["env"] = env.isEmpty ? nil : env
        }
        if var hooks = kept["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                var left = false
                let portable = groups.compactMap { group -> [String: Any]? in
                    var group = group
                    let all = group["hooks"] as? [[String: Any]] ?? []
                    let commands = all.filter { !needsThisMac($0["command"] as? String ?? "") }
                    left = left || commands.count != all.count
                    group["hooks"] = commands
                    return commands.isEmpty ? nil : group
                }
                if left { dropped.append("Claude hook \(event): needs this Mac") }
                hooks[event] = portable.isEmpty ? nil : portable
            }
            kept["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if let status = kept["statusLine"] as? [String: Any], needsThisMac(status["command"] as? String ?? "") {
            kept["statusLine"] = nil
            dropped.append("Claude status line: needs this Mac")
        }
        if var markets = kept["extraKnownMarketplaces"] as? [String: Any] {
            for (name, value) in markets {
                let source = (value as? [String: Any])?["source"] as? [String: Any]
                guard source?["source"] as? String == "directory" else { continue }
                markets[name] = nil
                dropped.append("Plugin marketplace \(name): a folder on this Mac")
                if var plugins = kept["enabledPlugins"] as? [String: Any] {
                    for key in plugins.keys where key.hasSuffix("@\(name)") { plugins[key] = nil }
                    kept["enabledPlugins"] = plugins
                }
            }
            kept["extraKnownMarketplaces"] = markets.isEmpty ? nil : markets
        }
        return (kept, dropped.sorted())
    }

    /// Why an MCP server can't go as it is, or nil.
    static func whyNotPortable(_ name: String, _ spec: [String: Any]) -> String? {
        let args = (spec["args"] as? [Any] ?? []).map { "\($0)" }
        if macOnly.contains(name) { return "works only on a Mac" }
        if let command = spec["command"] as? String, isMacPath(command) || command.hasPrefix("/") && !command.hasPrefix("/usr/") {
            return "runs a program on this Mac"
        }
        if args.contains(where: isMacPath) { return "uses files on this Mac" }
        if let helper = spec["headersHelper"] as? String, isMacPath(helper) { return "its sign-in helper is on this Mac" }
        if carriesKey(args + [spec["url"] as? String ?? ""]) { return keyReason }
        for field in ["env", "headers"] {
            for (_, value) in spec[field] as? [String: Any] ?? [:] where !"\(value)".contains("${") { return keyReason }
        }
        return nil
    }

    /// Whether literal values carry a key: "Authorization: Bearer …" or "x-api-key=…", the value after a key flag
    /// (--api-key …), or a URL with a password, a key in its query, or a long random part in its path (Zapier puts
    /// its key there). A ${VAR} reference names a key the server has, so it doesn't count.
    static func carriesKey(_ values: [String]) -> Bool {
        func keyName(_ name: Substring) -> Bool { ["key", "token", "secret", "password", "auth"].contains(where: name.lowercased().contains) }
        for (index, value) in values.enumerated() where !value.contains("${") {
            if value.lowercased().contains("bearer ") { return true }
            if let url = URLComponents(string: value), url.scheme != nil, url.host != nil {
                if url.password != nil || (url.queryItems ?? []).contains(where: { keyName(Substring($0.name)) && $0.value?.isEmpty == false }) { return true }
                if url.path.split(separator: "/").contains(where: { $0.count >= 32 && $0.contains(where: \.isLetter) && $0.contains(where: \.isNumber) }) { return true }
                continue
            }
            if let split = value.firstIndex(where: { $0 == ":" || $0 == "=" }), keyName(value[..<split]),
               !value[value.index(after: split)...].trimmingCharacters(in: .whitespaces).isEmpty { return true }
            if value.hasPrefix("-"), keyName(Substring(value)), index + 1 < values.count, !values[index + 1].hasPrefix("-"),
               !values[index + 1].contains("${") { return true }
        }
        return false
    }

    static func isMacPath(_ text: String) -> Bool {
        text.contains("/Users/") || text.contains("/Applications/") || text.contains("/Library/") || text.contains("/opt/homebrew/")
    }

    /// Mac tools a hook or status line can call; a server doesn't have them.
    static let macTools: Set<String> = ["osascript", "afplay", "say", "terminal-notifier", "pbcopy", "pbpaste", "open", "launchctl"]

    /// Whether a command needs this Mac: a Mac path, a file in the home folder (scripts there don't travel), or a Mac tool.
    static func needsThisMac(_ command: String) -> Bool {
        let words = command.split(whereSeparator: { " \t\n;|&()'\"".contains($0) }).map { $0.split(separator: "/").last.map(String.init) ?? "" }
        return isMacPath(command) || ["~/", "$HOME/", "${HOME}/"].contains(where: command.contains) || words.contains(where: macTools.contains)
    }

    /// Copies a folder (or file) with every symbolic link replaced by what it points to (a link back up the
    /// tree is skipped, so it can't loop). Hidden files (.env, .git, …) stay behind, since they can hold keys;
    /// returns their names.
    static func copyResolved(_ from: URL, to: URL, inside: Set<String> = []) throws -> Set<String> {
        let fm = FileManager.default
        let source = from.resolvingSymlinksInPath()
        guard !inside.contains(source.path) else { return [] }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: to)
            return []
        }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var hidden: Set<String> = []
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            if name.hasPrefix(".") { hidden.insert(name); continue }
            hidden.formUnion(try copyResolved(source.appending(path: name), to: to.appending(path: name), inside: inside.union([source.path])))
        }
        return hidden
    }
}
