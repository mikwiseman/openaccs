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
}
