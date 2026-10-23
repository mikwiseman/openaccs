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
        var skills: [String: URL] = [:]
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
            for (name, dir) in skills { try copyResolved(dir, to: target.appending(path: name)) }
            plan.goes.append("Skills: \(skills.count)")
        }

        for part in ["agents", "commands"] {
            let dir = context.url(".claude/\(part)")
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            guard !names.isEmpty else { continue }
            try copyResolved(dir, to: stage.appending(path: "claude/\(part)"))
            plan.goes.append("Claude \(part): \(names.count)")
        }

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
        plan.stays.append("Logins: each tool signs in on the server itself")
        return plan
    }

    /// Claude's settings without what points at this Mac: PATH, hooks and a status line run from Mac paths,
    /// and plugin marketplaces that are local folders (with the plugins they hold).
    static func serverSettings(_ settings: [String: Any]) -> (kept: [String: Any], dropped: [String]) {
        var kept = settings, dropped: [String] = []
        if var env = kept["env"] as? [String: Any] {
            for (key, value) in env where key == "PATH" || isMacPath("\(value)") {
                env[key] = nil
                dropped.append("Claude setting env.\(key): points at this Mac")
            }
            kept["env"] = env.isEmpty ? nil : env
        }
        if var hooks = kept["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let portable = groups.compactMap { group -> [String: Any]? in
                    var group = group
                    let commands = (group["hooks"] as? [[String: Any]] ?? []).filter { !isMacPath($0["command"] as? String ?? "") }
                    group["hooks"] = commands
                    return commands.isEmpty ? nil : group
                }
                if portable.count != groups.count { dropped.append("Claude hook \(event): runs a file on this Mac") }
                hooks[event] = portable.isEmpty ? nil : portable
            }
            kept["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if let status = kept["statusLine"] as? [String: Any], isMacPath(status["command"] as? String ?? "") {
            kept["statusLine"] = nil
            dropped.append("Claude status line: runs a file on this Mac")
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
        if macOnly.contains(name) { return "works only on a Mac" }
        if let command = spec["command"] as? String, isMacPath(command) || command.hasPrefix("/") && !command.hasPrefix("/usr/") {
            return "runs a program on this Mac"
        }
        if (spec["args"] as? [Any] ?? []).contains(where: { isMacPath("\($0)") }) { return "uses files on this Mac" }
        if let helper = spec["headersHelper"] as? String, isMacPath(helper) { return "its sign-in helper is on this Mac" }
        for field in ["env", "headers"] {
            for (_, value) in spec[field] as? [String: Any] ?? [:] {
                let text = "\(value)"
                if !text.contains("${") { return "a key is written into its settings; add it on the server with your key" }
            }
        }
        return nil
    }

    static func isMacPath(_ text: String) -> Bool {
        text.contains("/Users/") || text.contains("/Applications/") || text.contains("/Library/") || text.contains("/opt/homebrew/")
    }

    /// Copies a folder (or file) with every symbolic link replaced by what it points to (a link back up the
    /// tree is skipped, so it can't loop).
    static func copyResolved(_ from: URL, to: URL, inside: Set<String> = []) throws {
        let fm = FileManager.default
        let source = from.resolvingSymlinksInPath()
        guard !inside.contains(source.path) else { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: to)
            return
        }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != ".git" && name != ".DS_Store" {
            try copyResolved(source.appending(path: name), to: to.appending(path: name), inside: inside.union([source.path]))
        }
    }
}
