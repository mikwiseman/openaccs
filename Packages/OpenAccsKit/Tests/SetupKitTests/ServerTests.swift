import Foundation
import Testing
@testable import SetupKit

@Suite struct ServerTests {
    @Test func stagesThePortableSetupAndSaysWhatStays() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", "# Mine\nShort.\n")
        try home.write(".agents/skills/shared/SKILL.md", "---\nname: shared\n---\n")
        try home.write(".agents/skills/shared/scripts/run.sh", "echo hi\n")
        try home.write(".claude/skills/claude-only/SKILL.md", "---\nname: claude-only\n---\n")
        try FileManager.default.createSymbolicLink(atPath: home.path(".claude/skills/shared"), withDestinationPath: home.path(".agents/skills/shared"))
        try home.write(".claude/skills/synced/acct/SKILL.md", "per account")
        try home.write(".claude/agents/reviewer.md", "reviewer")
        let settings: [String: Any] = [
            "env": ["PATH": "/opt/homebrew/bin:/usr/bin", "EDITOR": "vim", "GITHUB_TOKEN": "ghp_literal", "SENTRY_AUTH_TOKEN": "${SENTRY_AUTH_TOKEN}"],
            "permissions": ["defaultMode": "auto", "deny": ["Read(~/.ssh/**)"]],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/Users/me/.claude/hooks/spin.sh"]]]],
                      "PostToolUse": [["hooks": [["type": "command", "command": "echo done"]]]]],
            "statusLine": ["type": "command", "command": "bash /Users/me/.claude/statusline.sh"],
            "extraKnownMarketplaces": ["mine": ["source": ["source": "directory", "path": "/Users/me/plugins"]],
                                       "official": ["source": ["source": "github", "repo": "anthropics/claude-plugins-official"]]],
            "enabledPlugins": ["tool@mine": true, "slack@official": true],
        ]
        try home.write(".claude/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        let servers: [String: Any] = ["mcpServers": [
            "context7": ["type": "http", "url": "https://mcp.context7.com/mcp", "headers": ["CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"]],
            "playwright": ["type": "stdio", "command": "npx", "args": ["@playwright/mcp@0.0.83"]],
            "swifteye": ["type": "stdio", "command": "/Users/me/Code/swifteye/.build/release/swifteye"],
            "unipile": ["type": "http", "url": "https://api.example.com/mcp", "headers": ["X-API-KEY": "literal-key"]],
        ], "projects": ["/Users/me/x": [:]]]
        try home.write(".claude.json", String(decoding: try JSONSerialization.data(withJSONObject: servers), as: UTF8.self))
        let stage = URL(filePath: home.path("stage"))

        let plan = try ServerSetup.stage(home.context(), into: stage)

        #expect(home.read("stage/CLAUDE.md") == "# Mine\nShort.\n")
        // Links become real folders; per-account skills stay.
        #expect(home.read("stage/skills/shared/scripts/run.sh") == "echo hi\n")
        #expect(home.read("stage/skills/claude-only/SKILL.md") != nil)
        #expect(home.read("stage/skills/synced/acct/SKILL.md") == nil)
        #expect(home.linkTarget("stage/skills/shared") == nil)
        #expect(home.read("stage/claude/agents/reviewer.md") == "reviewer")
        // Settings without what points at this Mac.
        let kept = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stage.appending(path: "claude/settings.json"))) as? [String: Any])
        #expect(kept["env"] as? [String: String] == ["EDITOR": "vim", "SENTRY_AUTH_TOKEN": "${SENTRY_AUTH_TOKEN}"])
        #expect(plan.stays.contains("Claude setting env.GITHUB_TOKEN: a key; set it on the server yourself"))
        #expect((kept["hooks"] as? [String: Any])?.keys.sorted() == ["PostToolUse"])
        #expect(kept["statusLine"] == nil)
        #expect((kept["extraKnownMarketplaces"] as? [String: Any])?.keys.sorted() == ["official"])
        #expect((kept["enabledPlugins"] as? [String: Bool]) == ["slack@official": true])
        #expect((kept["permissions"] as? [String: Any])?["defaultMode"] as? String == "auto")
        // MCP: portable ones go, one file each; the rest stay with a reason.
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: stage.appending(path: "claude-mcp").path)) == ["context7.json", "playwright.json"])
        #expect(plan.stays.contains("MCP swifteye: works only on a Mac"))
        #expect(plan.stays.contains { $0.hasPrefix("MCP unipile: a key is written") })
        #expect(plan.goes.contains("Skills: 2"))
        // Nothing secret travelled.
        let staged = try FileManager.default.subpathsOfDirectory(atPath: stage.path)
            .compactMap { try? String(contentsOfFile: stage.appending(path: $0).path, encoding: .utf8) }.joined()
        #expect(!staged.contains("literal-key") && !staged.contains("ghp_literal"))
    }

    @Test func codexGetsItsModelAutonomyAndPortableServersOnly() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", """
        model = "gpt-6-astra"
        approval_policy = "never"
        sandbox_mode = "danger-full-access"
        notify = ["/Applications/ChatGPT.app/Contents/MacOS/notify"]

        [desktop]
        external-agent-import-sync-enabled = true

        [projects."/Users/me/x"]
        trust_level = "trusted"

        [mcp_servers.context7]
        url = "https://mcp.context7.com/mcp"

        [mcp_servers.wai-telegram]
        url = "https://example.com/mcp"
        bearer_token_env_var = "TELEGRAM_AI_KEY"

        [mcp_servers.node_repl]
        command = "/Applications/ChatGPT.app/Contents/Resources/node_repl"

        [mcp_servers.secret]
        url = "https://example.com/mcp"
        http_headers = { X-API-KEY = "literal-key" }

        [mcp_servers.playwright]
        command = "npx"
        args = ["@playwright/mcp@0.0.79"]
        """)
        let plan = try ServerSetup.stage(home.context(), into: URL(filePath: home.path("stage")))
        let text = try #require(home.read("stage/codex/config.toml"))
        let config = try #require(TOMLFile(text: text))
        #expect(config.value("model", in: [])?.string == "gpt-6-astra")
        #expect(config.value("sandbox_mode", in: [])?.string == "danger-full-access")
        #expect(config.value("notify", in: []) == nil)
        #expect(config.value("external-agent-import-sync-enabled", in: ["desktop"]) == nil)
        #expect(Set(config.mcpServers.keys) == ["context7", "wai-telegram", "playwright"])
        #expect(config.mcpServers["wai-telegram"]?.table?["bearer_token_env_var"]?.string == "TELEGRAM_AI_KEY")
        #expect(!text.contains("literal-key") && !text.contains("/Users/"))
        #expect(plan.stays.contains("Codex MCP node_repl: works only on a Mac"))
        #expect(plan.stays.contains { $0.hasPrefix("Codex MCP secret: a key is written") })
    }

    @Test func aLinkBackUpTheTreeDoesNotLoop() throws {
        let home = try SetupHome()
        try home.write(".agents/skills/loop/SKILL.md", "x")
        try FileManager.default.createSymbolicLink(atPath: home.path(".agents/skills/loop/self"), withDestinationPath: home.path(".agents/skills/loop"))
        _ = try ServerSetup.stage(home.context(), into: URL(filePath: home.path("stage")))
        #expect(home.read("stage/skills/loop/SKILL.md") == "x")
    }

    @Test func keysWrittenIntoMCPArgsOrURLsStayAndThePlanSaysSo() throws {
        let home = try SetupHome()
        let servers: [String: Any] = ["mcpServers": [
            "remote": ["command": "npx", "args": ["-y", "mcp-remote", "https://mcp.example.com/sse", "--header", "Authorization: Bearer SECRET_1"]],
            "smithery": ["command": "npx", "args": ["-y", "@smithery/cli", "run", "exa", "--key", "SECRET_2"]],
            "zapier": ["type": "http", "url": "https://mcp.zapier.com/api/mcp/s/SECRET3a8f2c9d1e7b4a6f0c3d5e8b2a9f1c7d/mcp"],
            "tavily": ["type": "http", "url": "https://mcp.tavily.com/mcp/?tavilyApiKey=SECRET_4"],
            "db": ["command": "npx", "args": ["db-mcp", "postgres://me:SECRET_5@db.example.com/app"]],
            "referenced": ["command": "npx", "args": ["-y", "mcp-remote", "https://mcp.example.com/sse", "--header", "Authorization: Bearer ${REMOTE_KEY}"]],
            "plain": ["type": "http", "url": "https://mcp.context7.com/mcp"],
        ]]
        try home.write(".claude.json", String(decoding: try JSONSerialization.data(withJSONObject: servers), as: UTF8.self))
        try home.write(".codex/config.toml", """
        [mcp_servers.remote]
        command = "npx"
        args = ["-y", "mcp-remote", "https://mcp.example.com/sse", "--api-key=SECRET_6"]

        [mcp_servers.search]
        url = "https://mcp.example.com/mcp?apiKey=SECRET_7"

        [mcp_servers.docs]
        url = "https://mcp.context7.com/mcp"
        """)
        let stage = URL(filePath: home.path("stage"))

        let plan = try ServerSetup.stage(home.context(), into: stage)

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: stage.appending(path: "claude-mcp").path)) == ["referenced.json", "plain.json"])
        for name in ["remote", "smithery", "zapier", "tavily", "db"] {
            #expect(plan.stays.contains("MCP \(name): a key is written into its settings; add it on the server with your key"))
        }
        for name in ["remote", "search"] {
            #expect(plan.stays.contains("Codex MCP \(name): a key is written into its settings; add it on the server with your key"))
        }
        let codex = try #require(TOMLFile(text: home.read("stage/codex/config.toml") ?? ""))
        #expect(Set(codex.mcpServers.keys) == ["docs"])
        #expect(!staged(stage).contains("SECRET"))
    }

    @Test func claudeSettingsGoOnlyAsKnownSafeKeys() throws {
        let home = try SetupHome()
        let settings: [String: Any] = [
            "model": "opus", "effortLevel": "high", "theme": "dark", "cleanupPeriodDays": 30,
            "apiKeyHelper": "echo SECRET_HELPER", "otelHeadersHelper": "/Users/me/bin/otel.sh",
            "awsCredentialExport": "/Users/me/bin/aws.sh", "awsAuthRefresh": "aws sso login", "somethingNew": ["x": 1],
            "env": ["OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer SECRET_OTEL", "ANTHROPIC_CUSTOM_HEADERS": "x-api-key: SECRET_HDR",
                    "DATABASE_URL": "postgres://u:SECRET_PW@db/x", "MCP_GATEWAY": "https://gw.example.com/mcp?token=SECRET_Q",
                    "EDITOR": "vim", "ANTHROPIC_BASE_URL": "https://proxy.example.com"],
        ]
        try home.write(".claude/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        let stage = URL(filePath: home.path("stage"))

        let plan = try ServerSetup.stage(home.context(), into: stage)

        let kept = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stage.appending(path: "claude/settings.json"))) as? [String: Any])
        #expect(kept.keys.sorted() == ["cleanupPeriodDays", "effortLevel", "env", "model", "theme"])
        #expect(kept["env"] as? [String: String] == ["EDITOR": "vim", "ANTHROPIC_BASE_URL": "https://proxy.example.com"])
        #expect(plan.stays.contains("Claude settings apiKeyHelper, awsAuthRefresh, awsCredentialExport, otelHeadersHelper, somethingNew: not known to be safe on a server (some run a command or hold a key)"))
        for name in ["OTEL_EXPORTER_OTLP_HEADERS", "ANTHROPIC_CUSTOM_HEADERS", "DATABASE_URL", "MCP_GATEWAY"] {
            #expect(plan.stays.contains("Claude setting env.\(name): a key; set it on the server yourself"))
        }
        #expect(!staged(stage).contains("SECRET"))
    }

    @Test func hooksStatusLineAndCodexCwdThatNeedThisMacStay() throws {
        let home = try SetupHome()
        let settings: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "~/.claude/hooks/notify.sh"]]]],
                      "SubagentStop": [["hooks": [["type": "command", "command": "bash $HOME/.claude/hooks/done.sh"]]]],
                      "Notification": [["hooks": [["type": "command", "command": "osascript -e 'display notification \"Claude\"'"]]]],
                      "PostToolUse": [["hooks": [["type": "command", "command": "echo done"]]]]],
            "statusLine": ["type": "command", "command": "~/.claude/statusline.sh"],
        ]
        try home.write(".claude/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        try home.write(".codex/config.toml", """
        [mcp_servers.pw]
        command = "npx"
        args = ["@playwright/mcp"]
        cwd = "/Users/me/Code/x"
        """)
        let stage = URL(filePath: home.path("stage"))

        let plan = try ServerSetup.stage(home.context(), into: stage)

        let kept = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stage.appending(path: "claude/settings.json"))) as? [String: Any])
        #expect((kept["hooks"] as? [String: Any])?.keys.sorted() == ["PostToolUse"])
        #expect(kept["statusLine"] == nil)
        for event in ["Stop", "SubagentStop", "Notification"] { #expect(plan.stays.contains("Claude hook \(event): needs this Mac")) }
        #expect(plan.stays.contains("Claude status line: needs this Mac"))
        #expect(plan.stays.contains("Codex MCP pw: uses files on this Mac"))
        #expect(!(home.read("stage/codex/config.toml") ?? "").contains("/Users/"))
    }

    @Test func hiddenFilesInSkillsStayAndThePlanSaysSo() throws {
        let home = try SetupHome()
        try home.write(".agents/skills/deploy/SKILL.md", "---\nname: deploy\n---\n")
        try home.write(".agents/skills/deploy/.env", "API_TOKEN=SECRET_ENV")
        try home.write(".agents/skills/deploy/scripts/.npmrc", "//registry.npmjs.org/:_authToken=SECRET_NPM")
        try home.write(".agents/skills/deploy/scripts/run.sh", "echo hi\n")
        try home.write(".agents/skills/deploy/.DS_Store", "x")
        try home.write(".claude/agents/.env", "SECRET_AGENT")
        try home.write(".claude/agents/reviewer.md", "reviewer")
        let stage = URL(filePath: home.path("stage"))

        let plan = try ServerSetup.stage(home.context(), into: stage)

        #expect(home.read("stage/skills/deploy/scripts/run.sh") == "echo hi\n")
        #expect(home.read("stage/claude/agents/reviewer.md") == "reviewer")
        #expect(!FileManager.default.fileExists(atPath: home.path("stage/skills/deploy/.DS_Store")))
        #expect(plan.stays.contains("Hidden files (.env, .npmrc): they can hold keys; copy what a skill needs yourself"))
        #expect(!staged(stage).contains("SECRET"))
    }

    // MARK: server-setup.sh, run as the server would, in a throwaway home

    @Test func setupScriptKeepsWhatWasChangedOnTheServerAndUpdatesTheRest() throws {
        let home = try SetupHome()
        try incoming(home, claudeMD: "# v1\n", model: "gpt-6", agent: "reviewer v1")
        #expect(try runSetup(home).status == 0)
        #expect(home.read(".claude/CLAUDE.md") == "# v1\n")
        #expect(home.read(".claude/skills/alpha/SKILL.md") == "alpha")
        #expect(home.read(".codex/config.toml") == "model = \"gpt-6\"\n")

        // On the server: Codex trusts a repo, and the user adds an agent of their own.
        try home.write(".codex/config.toml", "model = \"gpt-6\"\n\n[projects.\"/home/me/repo\"]\ntrust_level = \"trusted\"\n")
        try home.write(".claude/agents/server-only.md", "mine")
        try incoming(home, claudeMD: "# v2\n", model: "gpt-7", agent: "reviewer v2")
        let second = try runSetup(home)

        #expect(second.status == 0)
        #expect(home.read(".claude/CLAUDE.md") == "# v2\n")
        #expect(home.read(".claude/agents/reviewer.md") == "reviewer v2")
        #expect(home.read(".claude/agents/server-only.md") == "mine")
        #expect(home.read(".codex/config.toml")?.contains("trust_level") == true)
        #expect(second.output.contains("Kept ~/.codex/config.toml: changed on this server since the last run"))

        // Still the user's on the next run; once they move it away, this Mac's goes.
        try incoming(home, claudeMD: "# v2\n", model: "gpt-7", agent: "reviewer v2")
        #expect(try runSetup(home).output.contains("Kept ~/.codex/config.toml"))
        try FileManager.default.removeItem(atPath: home.path(".codex/config.toml"))
        try incoming(home, claudeMD: "# v2\n", model: "gpt-7", agent: "reviewer v2")
        let fourth = try runSetup(home)
        #expect(home.read(".codex/config.toml") == "model = \"gpt-7\"\n")
        #expect(!fourth.output.contains("Kept"))
    }

    @Test(arguments: [(".claude/skills", ".agents/skills"), (".agents/skills", ".claude/skills")])
    func setupScriptWorksWhenOneSkillsFolderLinksToTheOther(link: String, folder: String) throws {
        let home = try SetupHome()
        try FileManager.default.createDirectory(atPath: home.path(folder), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.path(".agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.path(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path(link), withDestinationPath: home.path(folder))
        for _ in 1...2 {
            try incoming(home, claudeMD: "# v1\n", model: "gpt-6", agent: "reviewer")
            #expect(try runSetup(home).status == 0)
            #expect(home.read(".claude/skills/alpha/SKILL.md") == "alpha")
            #expect(home.read(".agents/skills/alpha/SKILL.md") == "alpha")
        }
    }

    /// What the server gets from the Mac, in ~/.openaccs/incoming.
    func incoming(_ home: SetupHome, claudeMD: String, model: String, agent: String) throws {
        try home.write(".openaccs/incoming/CLAUDE.md", claudeMD)
        try home.write(".openaccs/incoming/skills/alpha/SKILL.md", "alpha")
        try home.write(".openaccs/incoming/claude/agents/reviewer.md", agent)
        try home.write(".openaccs/incoming/claude/settings.json", "{\"model\":\"opus\"}")
        try home.write(".openaccs/incoming/codex/config.toml", "model = \"\(model)\"\n")
    }

    /// Runs server-setup.sh with stand-in claude and codex, so nothing is installed and nothing goes online.
    func runSetup(_ home: SetupHome) throws -> (status: Int32, output: String) {
        for tool in ["claude", "codex", "curl"] {
            let path = try home.write("bin/\(tool)", tool == "curl" ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\necho \(tool) 1.0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        var script = URL(filePath: #filePath)
        for _ in 1...5 { script.deleteLastPathComponent() }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.appending(path: "OpenAccs/Resources/server-setup.sh").path]
        process.environment = ["HOME": home.url.path, "PATH": "\(home.path("bin")):/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Every text file in the stage, joined.
    func staged(_ stage: URL) -> String {
        ((try? FileManager.default.subpathsOfDirectory(atPath: stage.path)) ?? [])
            .compactMap { try? String(contentsOfFile: stage.appending(path: $0).path, encoding: .utf8) }.joined()
    }
}
