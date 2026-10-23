import Foundation
import Testing
@testable import SetupKit

@Suite struct DefaultsTests {
    /// Shaped like ~/.claude/settings.json on Mik's Mac: Claude Code's key order, two-space indent, no final newline.
    static let settings = """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "env": {
            "PATH": "/Users/mik/.local/bin:/opt/homebrew/bin:/usr/bin"
          },
          "permissions": {
            "ask": [
              "Bash(git push:*)"
            ],
            "defaultMode": "auto",
            "deny": [
              "mcp__wai-company__meeting_create"
            ]
          },
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "afplay /System/Library/Sounds/Glass.aiff"
                  }
                ]
              }
            ]
          },
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline-command.sh"
          },
          "enabledPlugins": {
            "swift-lsp@claude-plugins-official": true
          },
          "effortLevel": "high",
          "skipDangerousModePermissionPrompt": true,
          "feedbackSurveyState": {
            "lastShownTime": 1754000000000.5
          },
          "voice": "Привет ✨"
        }
        """

    /// Shaped like ~/.codex/config.toml on Mik's Mac: Codex Full, a comment, and the app's own tables.
    static let config = """
        model = "gpt-6-astra"
        model_reasoning_effort = "high"
        approval_policy = "never"
        approvals_reviewer = "user"   # who answers approvals
        sandbox_mode = "danger-full-access"
        notify = ["/Users/mik/.codex/notify.sh"]

        [features]
        web_search = true

        [projects."/Users/mik/Code/site"]
        trust_level = "trusted"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]

        [desktop]
        external-agent-import-sync-enabled = false

        """

    static let titles = ["Keep Claude chats for 10 years", "Hide .env, ~/.ssh and logins from agents", "Codex reads CLAUDE.md in repos"]

    func macLikeHome(settings: String? = Self.settings, config: String? = Self.config) throws -> SetupHome {
        let home = try SetupHome()
        if let settings { try home.write(".claude/settings.json", settings) }
        if let config { try home.write(".codex/config.toml", config) }
        return home
    }

    func claudeSettings(_ home: SetupHome) throws -> [String: Any] {
        try #require((try? Data(contentsOf: home.url.appending(path: ".claude/settings.json"))).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        })
    }

    func codex(_ home: SetupHome, _ key: String) -> String? {
        home.read(".codex/config.toml").flatMap { TOMLFile(text: $0) }?.value(key, in: [])?.string
    }

    func bytes(_ home: SetupHome, _ relative: String) -> Data? { try? Data(contentsOf: home.url.appending(path: relative)) }

    @Test func readsAutonomyAndOffersEachRecommendedDefault() throws {
        let home = try macLikeHome()

        let report = DefaultsSetup.scan(home.context())

        #expect(report.area == .defaults)
        #expect(report.summary == "0 of 4 recommended · Autonomy mixed")
        #expect(report.attention.isEmpty)
        #expect(report.items == [
            SetupItem(id: "defaults.autonomy", name: "Autonomy", claude: .differs, codex: .differs, note: "Claude Auto, Codex Full"),
            SetupItem(id: "defaults.keep-chats", name: "Keep Claude chats for 10 years", claude: .missing, codex: .notShared,
                      note: "Not set · Claude deletes chats after 30 days"),
            SetupItem(id: "defaults.hide-secrets", name: "Hide .env, ~/.ssh and logins from agents", claude: .missing, codex: .notShared,
                      note: "0 of 6 deny rules"),
            SetupItem(id: "defaults.codex-claude-md", name: "Codex reads CLAUDE.md in repos", claude: .notShared, codex: .missing, note: "Not set"),
        ])
        // Autonomy is never proposed by a scan; each default is its own change.
        #expect(report.changes.map(\.title) == Self.titles)
        #expect(report.changes.map(\.waitsFor) == [nil, nil, .chatGPT])
        #expect(report.changes.map(\.requires) == [[], ["defaults.keep-chats"], []])
        #expect(report.changes[2].detail == #"+ project_doc_fallback_filenames = ["CLAUDE.md"]"#)

    }

    @Test func scanningAndPlanningWriteNothing() throws {
        let home = try macLikeHome()
        let before = home.snapshot()
        _ = DefaultsSetup.scan(home.context())
        for level in DefaultsSetup.Autonomy.allCases { _ = DefaultsSetup.autonomyChanges(home.context(), to: level) }
        #expect(home.snapshot() == before)
    }

    @Test func keepsChatsWhenTheyAreKeptForLessThan10Years() throws {
        for (days, offered) in [(nil, true), (30, true), (3650, false), (5000, false)] as [(Int?, Bool)] {
            let home = try macLikeHome(settings: days.map { "{\"cleanupPeriodDays\": \($0)}" } ?? "{}")
            let report = DefaultsSetup.scan(home.context())
            let change = report.changes.first { $0.id == "defaults.keep-chats" }
            #expect((change != nil) == offered, "cleanupPeriodDays \(days.map { "\($0)" } ?? "missing")")
            #expect(report.items[1].note == days.map { "cleanupPeriodDays \($0)" } ?? "Not set · Claude deletes chats after 30 days")
            guard let change else { continue }
            #expect(SetupApplier(context: home.context()).apply([change]).applied.count == 1)
            #expect(try claudeSettings(home)["cleanupPeriodDays"] as? Int == 3650)
        }
    }

    @Test func hidesSecretsByAppendingOnlyTheMissingDenyRules() throws {
        let home = try macLikeHome(settings: #"{"permissions": {"deny": ["mcp__x", "Read(~/.ssh/**)"]}, "cleanupPeriodDays": 3650}"#)

        let report = DefaultsSetup.scan(home.context())

        #expect(report.items[2].note == "1 of 6 deny rules")
        // Keep chats is already there, so this one stands alone.
        #expect(report.changes.map(\.id) == ["defaults.hide-secrets", "defaults.codex-claude-md"])
        #expect(report.changes[0].requires.isEmpty)
        #expect(SetupApplier(context: home.context()).apply([report.changes[0]]).applied.count == 1)
        #expect(try claudeSettings(home)["permissions"] as? [String: [String]] == ["deny": [
            "mcp__x", "Read(~/.ssh/**)", "Read(//**/.env)", "Read(//**/.env.*)", "Read(~/.codex/auth.json)",
            "Read(~/.claude/.credentials.json)", "Read(~/Library/Application Support/Claude/config.json)",
        ]])
        #expect(DefaultsSetup.scan(home.context()).items[2] == SetupItem(
            id: "defaults.hide-secrets", name: "Hide .env, ~/.ssh and logins from agents", claude: .same, codex: .notShared, note: "6 of 6 deny rules"))
    }

    @Test func hidingSecretsNeedsKeepChatsWhenBothArePlanned() throws {
        let home = try macLikeHome()
        let hide = try #require(DefaultsSetup.scan(home.context()).changes.first { $0.id == "defaults.hide-secrets" })

        let result = SetupApplier(context: home.context()).apply([hide])

        #expect(result.applied.isEmpty)
        #expect(result.skipped.first?.reason == "needs “defaults.keep-chats” too")
        #expect(home.read(".claude/settings.json") == Self.settings)
    }

    @Test func codexReadsClaudeMDAddedToTheTopLevelOnly() throws {
        let missing = try macLikeHome()
        let change = try #require(DefaultsSetup.scan(missing.context()).changes.last)
        #expect(SetupApplier(context: missing.context()).apply([change]).applied.count == 1)
        #expect(missing.read(".codex/config.toml") == Self.config.replacingOccurrences(
            of: "notify.sh\"]\n", with: "notify.sh\"]\nproject_doc_fallback_filenames = [\"CLAUDE.md\"]\n"))

        // The same key inside a table is not Codex's setting.
        let other = try macLikeHome(config: "project_doc_fallback_filenames = [\"README.md\"]\n" + Self.config)
        let report = DefaultsSetup.scan(other.context())
        #expect(report.items[3].note == #"project_doc_fallback_filenames ["README.md"]"#)
        #expect(SetupApplier(context: other.context()).apply([try #require(report.changes.last)]).applied.count == 1)
        #expect(other.read(".codex/config.toml") == "project_doc_fallback_filenames = [\"README.md\", \"CLAUDE.md\"]\n" + Self.config)

        let inTable = try macLikeHome(config: Self.config + "project_doc_fallback_filenames = [\"CLAUDE.md\"]\n")
        #expect(DefaultsSetup.scan(inTable.context()).changes.last?.id == "defaults.codex-claude-md")

        let there = try macLikeHome(config: "project_doc_fallback_filenames = [\"CLAUDE.md\"]\n")
        let done = DefaultsSetup.scan(there.context())
        #expect(!done.changes.contains { $0.id == "defaults.codex-claude-md" })
        #expect(done.items[3].codex == .same)
    }

    @Test func everyOtherKeyAndValueStays() throws {
        let home = try macLikeHome()
        let before = try claudeSettings(home)

        let result = SetupApplier(context: home.context()).apply(DefaultsSetup.scan(home.context()).changes)

        #expect(result.applied.count == 3)
        var after = try claudeSettings(home)
        #expect(after.removeValue(forKey: "cleanupPeriodDays") as? Int == 3650)
        var permissions = try #require(after["permissions"] as? [String: Any])
        permissions["deny"] = Array((permissions["deny"] as? [String] ?? []).prefix(1))
        after["permissions"] = permissions
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        // Written once more with sorted keys and a two-space indent.
        let text = try #require(home.read(".claude/settings.json"))
        let keys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.dropFirst(3).prefix { $0 != "\"" } }
        #expect(keys == ["$schema", "cleanupPeriodDays", "effortLevel", "enabledPlugins", "env", "feedbackSurveyState", "hooks",
                         "permissions", "skipDangerousModePermissionPrompt", "statusLine", "voice"])
        #expect(text.contains("\n      \"mcp__wai-company__meeting_create\","))
        #expect(!text.contains("cli_auth_credentials_store") && home.read(".codex/config.toml")?.contains("cli_auth_credentials_store") == false)
    }

    @Test(arguments: DefaultsSetup.Autonomy.allCases)
    func autonomyChangesSetEachLevel(_ level: DefaultsSetup.Autonomy) throws {
        let home = try macLikeHome()

        let changes = DefaultsSetup.autonomyChanges(home.context(), to: level)

        // Only the sides that differ: Claude is Auto and Codex is Full already.
        let expected: [String] = switch level {
        case .ask: ["defaults.autonomy.claude", "defaults.autonomy.codex"]
        case .auto: ["defaults.autonomy.codex"]
        case .full: ["defaults.autonomy.claude"]
        }
        #expect(changes.map(\.id) == expected)
        #expect(changes.map(\.title) == expected.map { $0.hasSuffix("claude") ? "Autonomy: Claude \(level.title)" : "Autonomy: Codex \(level.title)" })
        #expect(changes.allSatisfy { $0.waitsFor == ($0.id.hasSuffix("codex") ? .chatGPT : nil) })
        #expect(SetupApplier(context: home.context()).apply(changes).applied.count == changes.count)

        let mode = try claudeSettings(home)["permissions"] as? [String: Any]
        #expect(mode?["defaultMode"] as? String == ["ask": "default", "auto": "auto", "full": "bypassPermissions"][level.rawValue])
        #expect(mode?["deny"] as? [String] == ["mcp__wai-company__meeting_create"])
        #expect(codex(home, "approval_policy") == (level == .full ? "never" : "on-request"))
        #expect(codex(home, "sandbox_mode") == (level == .full ? "danger-full-access" : "workspace-write"))
        #expect(codex(home, "approvals_reviewer") == (level == .auto ? "auto_review" : "user"))
        #expect(home.read(".codex/config.toml")?.contains("# who answers approvals") == true)

        let report = DefaultsSetup.scan(home.context())
        #expect(report.items[0] == SetupItem(id: "defaults.autonomy", name: "Autonomy", claude: .same, codex: .same,
                                             note: "Claude \(level.title), Codex \(level.title)"))
        #expect(report.summary == "1 of 4 recommended · Autonomy \(level.title)")
        #expect(DefaultsSetup.autonomyChanges(home.context(), to: level).isEmpty)
    }

    @Test func askRemovesTheAutoReviewerAndNothingElse() throws {
        let auto = """
            approval_policy = "on-request"
            approvals_reviewer = "auto_review"
            sandbox_mode = "workspace-write"

            [features]
            web_search = true

            """
        let home = try macLikeHome(settings: "{}", config: auto)
        #expect(DefaultsSetup.scan(home.context()).items[0].note == "Claude Ask, Codex Auto")

        // Claude asks already: no mode set means "default".
        let changes = DefaultsSetup.autonomyChanges(home.context(), to: .ask)

        #expect(changes.map(\.id) == ["defaults.autonomy.codex"])
        #expect(SetupApplier(context: home.context()).apply(changes).applied.count == 1)
        #expect(home.read(".codex/config.toml") == auto.replacingOccurrences(of: "approvals_reviewer = \"auto_review\"\n", with: ""))
        #expect(DefaultsSetup.scan(home.context()).summary == "1 of 4 recommended · Autonomy Ask")
    }

    @Test func namesWhatItReadsWhenItIsNoLevel() throws {
        for (settings, config, note) in [
            (#"{"permissions": {"defaultMode": "acceptEdits"}}"#, "", "Claude Accept edits, Codex Default"),
            (#"{"permissions": {"defaultMode": "plan"}}"#, "approval_policy = \"untrusted\"\n", "Claude Plan, Codex Custom"),
            (#"{"permissions": {"defaultMode": "dontAsk"}}"#, "approval_policy = \"on-request\"\nsandbox_mode = \"read-only\"\n", "Claude dontAsk, Codex Custom"),
        ] {
            let home = try macLikeHome(settings: settings, config: config)
            let report = DefaultsSetup.scan(home.context())
            #expect(report.items[0].note == note)
            #expect(report.summary == "0 of 4 recommended · Autonomy mixed")
        }
    }

    @Test func autonomyGivesEachSidesLevelOrNil() throws {
        for (settings, config, claude, codex) in [
            (Self.settings, Self.config, .auto, .full),
            ("{}", "approval_policy = \"on-request\"\nsandbox_mode = \"workspace-write\"\napprovals_reviewer = \"auto_review\"\n", .ask, .auto),
            (#"{"permissions": {"defaultMode": "bypassPermissions"}}"#, "approval_policy = \"on-request\"\nsandbox_mode = \"workspace-write\"\n", .full, .ask),
            (#"{"permissions": {"defaultMode": "acceptEdits"}}"#, "", nil, nil),
            (#"{"permissions": {"defaultMode": "plan"}}"#, "approval_policy = \"never\"\n", nil, nil),
            ("{ \"permissions\": ", "model = \n", nil, nil),
        ] as [(String, String, DefaultsSetup.Autonomy?, DefaultsSetup.Autonomy?)] {
            let home = try macLikeHome(settings: settings, config: config)
            let autonomy = DefaultsSetup.autonomy(home.context())
            #expect(autonomy.claude == claude && autonomy.codex == codex, "\(settings) · \(config)")
        }
        // After a pick, both sides read as that level.
        let home = try macLikeHome()
        #expect(SetupApplier(context: home.context()).apply(DefaultsSetup.autonomyChanges(home.context(), to: .ask)).applied.count == 2)
        let picked = DefaultsSetup.autonomy(home.context())
        #expect(picked.claude == .ask && picked.codex == .ask)
    }

    @Test func appliesAllRecommendedAtOnceAndUndoesByteForByte() throws {
        let home = try macLikeHome()
        let applier = SetupApplier(context: home.context())

        let result = applier.apply(DefaultsSetup.scan(home.context()).changes)

        #expect(Set(result.applied.map(\.title)) == Set(Self.titles) && result.skipped.isEmpty)
        let again = DefaultsSetup.scan(home.context())
        #expect(again.changes.isEmpty)
        #expect(again.summary == "3 of 4 recommended · Autonomy mixed")
        #expect(again.items.dropFirst().allSatisfy { $0.claude != .missing && $0.codex != .missing })

        // Both Claude changes wrote settings.json, so the later one is undone first.
        for entry in result.applied.reversed() { try applier.undo(entry.id) }

        #expect(bytes(home, ".claude/settings.json") == Data(Self.settings.utf8))
        #expect(bytes(home, ".codex/config.toml") == Data(Self.config.utf8))
    }

    @Test func codexWaitsForChatGPTToClose() throws {
        let home = try macLikeHome()
        let context = home.context(running: [.chatGPT])

        let result = SetupApplier(context: context).apply(DefaultsSetup.scan(context).changes + DefaultsSetup.autonomyChanges(context, to: .ask))

        #expect(result.applied.map(\.title) == Array(Self.titles.prefix(2)))
        // Autonomy changes are planned on the files as they are, so they apply on their own, not with these.
        #expect(result.skipped.map { $0.change.title } == ["Codex reads CLAUDE.md in repos", "Autonomy: Claude Ask", "Autonomy: Codex Ask"])
        #expect(result.skipped.map { $0.reason } == ["waits for ChatGPT to close", "changed since you reviewed it", "waits for ChatGPT to close"])
        #expect(home.read(".codex/config.toml") == Self.config)
    }

    @Test func missingFilesAreMadeWithOnlyTheDefaults() throws {
        let home = try macLikeHome(settings: nil, config: nil)

        let report = DefaultsSetup.scan(home.context())

        #expect(report.summary == "0 of 4 recommended · Autonomy mixed")
        #expect(report.items[0].note == "Claude Ask, Codex Default")
        #expect(SetupApplier(context: home.context()).apply(report.changes).applied.count == 3)
        #expect(try claudeSettings(home)["cleanupPeriodDays"] as? Int == 3650)
        #expect(home.read(".codex/config.toml") == "project_doc_fallback_filenames = [\"CLAUDE.md\"]\n")
    }

    @Test func unreadableFilesAreBrokenAndLeftAlone() throws {
        let home = try macLikeHome(settings: "{ \"permissions\": ", config: "model = \n")

        let report = DefaultsSetup.scan(home.context())

        #expect(report.attention == [
            Attention(id: "defaults.claude-settings", text: "Can't read ~/.claude/settings.json", level: .broken),
            Attention(id: "defaults.codex-config", text: "Can't read ~/.codex/config.toml", level: .broken),
        ])
        #expect(report.changes.isEmpty)
        #expect(report.summary == "0 of 4 recommended")
        #expect(report.items[0].note == "Claude unknown, Codex unknown")
        #expect(DefaultsSetup.autonomyChanges(home.context(), to: .full).isEmpty)
    }

    @Test func linkedFilesKeepTheirLinks() throws {
        let home = try SetupHome()
        let settings = try home.write("dotfiles/claude-settings.json", "{}")
        let config = try home.write("dotfiles/codex-config.toml", "")
        for (path, target) in [(".claude/settings.json", settings), (".codex/config.toml", config)] {
            try FileManager.default.createDirectory(at: home.url.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home.path(path), withDestinationPath: target)
        }

        let result = SetupApplier(context: home.context()).apply(DefaultsSetup.scan(home.context()).changes)

        #expect(result.applied.count == 3)
        #expect(home.linkTarget(".claude/settings.json") == settings && home.linkTarget(".codex/config.toml") == config)
        #expect(home.read("dotfiles/codex-config.toml") == "project_doc_fallback_filenames = [\"CLAUDE.md\"]\n")
        #expect(DefaultsSetup.scan(home.context()).changes.isEmpty)
    }
}
