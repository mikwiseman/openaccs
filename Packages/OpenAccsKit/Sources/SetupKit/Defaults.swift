import Foundation
import OpenAccsCore

/// Defaults: a few recommended settings, each its own change and never applied unasked, and Autonomy, how freely
/// Claude and Codex act, which only the user picks. Claude Code keeps them in ~/.claude/settings.json and writes
/// that file too, so every other key and value stays. Codex keeps them in ~/.codex/config.toml, edited in place
/// and only while ChatGPT is closed (it keeps the file in memory). Never sets `cli_auth_credentials_store`:
/// account switching needs Codex's default file store.
public enum DefaultsSetup {
    public enum Autonomy: String, CaseIterable, Sendable {
        case ask, auto, full

        var title: String { rawValue.capitalized }

        /// Claude's `permissions.defaultMode` for it.
        var claudeMode: String {
            switch self {
            case .ask: "default"
            case .auto: "auto"
            case .full: "bypassPermissions"
            }
        }
    }

    /// Claude deletes chats after 30 days unless told otherwise, and OpenAccs's shared history reads them.
    static let keepDays = 3650
    /// Written with `//` or `~/`, because in user settings `./` means ~/.claude.
    static let denyRules = ["Read(//**/.env)", "Read(//**/.env.*)", "Read(~/.ssh/**)", "Read(~/.codex/auth.json)",
                            "Read(~/.claude/.credentials.json)", "Read(~/Library/Application Support/Claude/config.json)"]
    static let fallbackKey = "project_doc_fallback_filenames"
    static let claudeMD = TOMLValue.string("CLAUDE.md")

    public static func scan(_ context: SetupContext) -> AreaReport {
        let claude = ClaudeSettings(context), codex = CodexConfig(context)
        var changes: [SetupChange] = [], attention: [Attention] = [], items: [SetupItem] = []
        var met = 0

        // Autonomy is only read here; the user picks it, and autonomyChanges makes that pick.
        let claudeName = claude.object == nil ? "unknown" : claude.modeName
        let codexName = codex.toml == nil ? "unknown" : codex.autonomyName
        let same = claude.autonomy != nil && claude.autonomy == codex.autonomy
        if same { met += 1 }
        items.append(SetupItem(id: "defaults.autonomy", name: "Autonomy", claude: same ? .same : .differs, codex: same ? .same : .differs,
                               note: "Claude \(claudeName), Codex \(codexName)"))

        if let object = claude.object {
            // Each sets only its own key of settings.json when it applies, so either applies alone and both apply together.
            func plan(_ id: String, _ title: String, _ detail: String, key: String, _ value: Any) {
                guard let text = SetupApplier.jsonText(value) else { return }
                changes.append(SetupChange(id: id, area: .defaults, title: title, detail: detail, operations: [
                    .json(path: claude.url.path, key: key, value: text, expected: SetupApplier.jsonText(object[key])),
                ]))
            }

            let days = object["cleanupPeriodDays"]
            let keeps = (days as? Int ?? 0) >= keepDays
            if keeps { met += 1 }
            items.append(SetupItem(id: "defaults.keep-chats", name: "Keep Claude chats for 10 years", claude: keeps ? .same : .missing,
                                   codex: .notShared, note: days.map { "cleanupPeriodDays \($0)" } ?? "Not set · Claude deletes chats after 30 days"))
            if !keeps {
                plan("defaults.keep-chats", "Keep Claude chats for 10 years",
                     "Sets cleanupPeriodDays to \(keepDays) in ~/.claude/settings.json (now \(days.map { "\($0)" } ?? "not set")). "
                         + "Claude deletes chats after 30 days by default, and OpenAccs's shared history reads them. Every other key and value stays.",
                     key: "cleanupPeriodDays", keepDays)
            }

            let deny = claude.permissions["deny"] as? [Any] ?? []
            let missing = denyRules.filter { rule in !deny.contains { $0 as? String == rule } }
            if missing.isEmpty { met += 1 }
            items.append(SetupItem(id: "defaults.hide-secrets", name: "Hide .env, ~/.ssh and logins from agents", claude: missing.isEmpty ? .same : .missing,
                                   codex: .notShared, note: "\(denyRules.count - missing.count) of \(denyRules.count) deny rules"))
            if !missing.isEmpty {
                var permissions = claude.permissions
                permissions["deny"] = deny + missing
                plan("defaults.hide-secrets", "Hide .env, ~/.ssh and logins from agents",
                     "Adds deny rules for Claude's Read tool in ~/.claude/settings.json: \(missing.joined(separator: ", ")). "
                         + "Every other key and value stays.",
                     key: "permissions", permissions)
            }
        } else {
            attention.append(Attention(id: "defaults.claude-settings", text: "Can't read ~/.claude/settings.json", level: .broken))
            for (id, name) in [("defaults.keep-chats", "Keep Claude chats for 10 years"), ("defaults.hide-secrets", "Hide .env, ~/.ssh and logins from agents")] {
                items.append(SetupItem(id: id, name: name, claude: .missing, codex: .notShared, note: "Can't read ~/.claude/settings.json"))
            }
        }

        if let toml = codex.toml {
            let names = toml.value(fallbackKey, in: [])
            let reads = names?.array?.contains(claudeMD) == true
            if reads { met += 1 }
            items.append(SetupItem(id: "defaults.codex-claude-md", name: "Codex reads CLAUDE.md in repos", claude: .notShared, codex: reads ? .same : .missing,
                                   note: names.map { "\(fallbackKey) \(TOMLFile.inline($0))" } ?? "Not set"))
            var edited = toml
            if !reads, edited.set(fallbackKey, .array((names?.array ?? []) + [claudeMD]), in: []) {
                changes.append(codex.change(id: "defaults.codex-claude-md", title: "Codex reads CLAUDE.md in repos", edited))
            }
        } else {
            attention.append(Attention(id: "defaults.codex-config", text: "Can't read ~/.codex/config.toml", level: .broken))
            items.append(SetupItem(id: "defaults.codex-claude-md", name: "Codex reads CLAUDE.md in repos", claude: .notShared, codex: .missing,
                                   note: "Can't read ~/.codex/config.toml"))
        }

        let autonomy: String? = claude.object == nil || codex.toml == nil ? nil : same ? "Autonomy \(claudeName)" : "Autonomy mixed"
        let summary = ["\(met) of 4 recommended", autonomy].compactMap { $0 }.joined(separator: " · ")
        return AreaReport(area: .defaults, summary: summary, attention: attention, changes: changes, items: items)
    }

    /// The level each side is at now, for the Autonomy picker: nil when it is at none of the three or can't be read.
    public static func autonomy(_ context: SetupContext) -> (claude: Autonomy?, codex: Autonomy?) {
        (ClaudeSettings(context).autonomy, CodexConfig(context).autonomy)
    }

    /// What sets Autonomy to `level`: a change for Claude and one for Codex, each only when it isn't there yet.
    /// Planned on the files as they are now, so apply them on their own and scan again after.
    public static func autonomyChanges(_ context: SetupContext, to level: Autonomy) -> [SetupChange] {
        let claude = ClaudeSettings(context), codex = CodexConfig(context)
        var changes: [SetupChange] = []
        if var object = claude.object, claude.mode != level.claudeMode {
            var permissions = claude.permissions
            permissions["defaultMode"] = level.claudeMode
            object["permissions"] = permissions
            if let data = ClaudeAppSetup.serialize(object) {
                changes.append(SetupChange(
                    id: "defaults.autonomy.claude", area: .defaults, title: "Autonomy: Claude \(level.title)",
                    detail: "Sets permissions.defaultMode to \(level.claudeMode) in ~/.claude/settings.json (now \(claude.mode)). Every other key and value stays.",
                    operations: [.write(path: claude.url.path, contents: data, expected: claude.state)]))
            }
        }
        if var edited = codex.toml, set(level, in: &edited), edited.text != codex.toml?.text {
            changes.append(codex.change(id: "defaults.autonomy.codex", title: "Autonomy: Codex \(level.title)", edited))
        }
        return changes
    }

    /// Ask and Auto let Codex write in the workspace and ask first (Auto has a reviewer answer); Full never asks.
    static func set(_ level: Autonomy, in toml: inout TOMLFile) -> Bool {
        guard toml.set("approval_policy", .string(level == .full ? "never" : "on-request"), in: []),
              toml.set("sandbox_mode", .string(level == .full ? "danger-full-access" : "workspace-write"), in: []) else { return false }
        switch level {
        case .ask: return toml.value("approvals_reviewer", in: [])?.string != "auto_review" || toml.remove("approvals_reviewer", in: [])
        case .auto: return toml.set("approvals_reviewer", .string("auto_review"), in: [])
        case .full: return true
        }
    }

    // MARK: Reading

    /// ~/.claude/settings.json, through a link so a write keeps the link. `object` is nil when it isn't a JSON object.
    struct ClaudeSettings {
        let url: URL
        let state: FileState
        let object: [String: Any]?

        init(_ context: SetupContext) {
            url = context.url(".claude/settings.json").resolvingSymlinksInPath()
            state = FileState.of(url)
            object = state == .absent ? [:] : (try? Data(contentsOf: url)).flatMap(JSON.object)
        }

        var permissions: [String: Any] { object?["permissions"] as? [String: Any] ?? [:] }
        /// Claude asks first ("default") when no mode is set.
        var mode: String { permissions["defaultMode"] as? String ?? "default" }
        var autonomy: Autonomy? { object == nil ? nil : Autonomy.allCases.first { $0.claudeMode == mode } }

        var modeName: String {
            switch mode {
            case "acceptEdits": "Accept edits"
            case "plan": "Plan"
            default: autonomy?.title ?? mode
            }
        }
    }

    /// ~/.codex/config.toml, through a link so a write keeps the link. `toml` is nil when it can't be read.
    struct CodexConfig {
        let url: URL
        let state: FileState
        let toml: TOMLFile?

        init(_ context: SetupContext) {
            url = context.url(".codex/config.toml").resolvingSymlinksInPath()
            state = FileState.of(url)
            toml = state == .absent ? TOMLFile(text: "") : (try? String(contentsOf: url, encoding: .utf8)).flatMap { TOMLFile(text: $0) }
        }

        func string(_ key: String) -> String? { toml?.value(key, in: [])?.string }

        var autonomy: Autonomy? {
            switch (string("approval_policy"), string("sandbox_mode")) {
            case ("never", "danger-full-access"): .full
            case ("on-request", "workspace-write"): string("approvals_reviewer") == "auto_review" ? .auto : .ask
            default: nil
            }
        }

        /// A level, or "Default" when neither key is set (Codex then uses its own), else "Custom".
        var autonomyName: String {
            autonomy?.title ?? (string("approval_policy") == nil && string("sandbox_mode") == nil ? "Default" : "Custom")
        }

        /// The whole file with only `edited`'s keys changed, written while ChatGPT is closed.
        func change(id: String, title: String, _ edited: TOMLFile) -> SetupChange {
            SetupChange(id: id, area: .defaults, title: title, detail: InstructionsSetup.lineDiff(toml?.text ?? "", edited.text, context: 0),
                        operations: ["approval_policy", "sandbox_mode", "approvals_reviewer", DefaultsSetup.fallbackKey].compactMap { key in
                            let before = toml?.value(key, in: []), after = edited.value(key, in: [])
                            return before == after ? nil : .toml(path: url.path, table: [], key: key, value: after, expected: before)
                        }, waitsFor: .chatGPT)
        }
    }
}
