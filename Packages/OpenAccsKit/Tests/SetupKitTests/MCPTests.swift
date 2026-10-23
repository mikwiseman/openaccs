import Foundation
import Testing
@testable import SetupKit

@Suite struct MCPTests {
    @Test func claudeChangeRejectsAnEditAfterReview() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", "[mcp_servers.sample]\ncommand = \"codex-server\"\n")
        let change = try #require(MCPSetup.scan(home.context()).changes.first { $0.id == "mcp.claude.add" })
        try home.write(".claude.json", #"{"mcpServers":{"sample":{"command":"new-user-choice"}}}"#)
        let calls = Calls()
        let result = SetupApplier(context: home.context { argv in calls.argv.append(argv); return (0, "") }).apply([change])
        #expect(result.applied.isEmpty)
        #expect(calls.argv.isEmpty)
    }

    @Test func claudeCLIChangesAreVerifiedAndReversible() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{},"keep":"untouched"}"#)
        try home.write(".codex/config.toml", "[mcp_servers.sample]\ncommand = \"codex-server\"\n")
        let context = home.context(run: claudeCLI(home))
        let change = try #require(MCPSetup.scan(context).changes.first { $0.id == "mcp.claude.add" })
        let applier = SetupApplier(context: context)
        let result = applier.apply([change])
        #expect(result.skipped.isEmpty)
        #expect(MCPSetup.scan(context).changes.isEmpty)
        try applier.undo(try #require(result.applied.first).id)
        #expect(MCPSetup.readClaude(context)?.servers.isEmpty == true)
        #expect(home.read(".claude.json")?.contains("untouched") == true)
    }
    @Test func referencesRoundTripAndToolSpecificSettingsStay() throws {
        let source: [String: Any] = ["type": "http", "url": "https://example.org/mcp",
            "headers": ["Authorization": "Bearer ${TOKEN}", "X-Key": "${KEY}"],
            "headersHelper": "headers-helper", "timeout": 1500]
        let spec = try #require(MCPSetup.translate(claude: source).spec)
        let table = MCPSetup.codexTable(spec, keeping: ["enabled_tools": .array([.string("read")]), "startup_timeout_sec": .integer(30)])
        #expect(MCPSetup.translate(codex: .table(table)).spec == spec)
        #expect(table["enabled_tools"] == .array([.string("read")]))
        #expect(table["startup_timeout_sec"] == .integer(30))
        #expect(MCPSetup.translate(claude: MCPSetup.claudeEntry(spec)).spec == spec)
    }

    @Test func literalsAndAppOwnedServersAreNeverShared() {
        for server: [String: Any] in [
            ["command": "server", "env": ["TOKEN": "secret-value"]],
            ["type": "http", "url": "https://example.org", "headers": ["Authorization": "Bearer secret-value"]],
            ["command": "/Applications/ChatGPT.app/Contents/helper"],
            ["type": "sse", "url": "https://example.org"],
        ] { #expect(MCPSetup.translate(claude: server).spec == nil) }
    }

    @Test func plainHTTPAndStdioAreSupported() {
        #expect(MCPSetup.translate(claude: ["type": "http", "url": "https://example.org"]).spec?.url == "https://example.org")
        #expect(MCPSetup.translate(codex: .table(["url": .string("https://example.org")])).spec?.url == "https://example.org")
        let spec = MCPSetup.translate(claude: ["command": "server", "env": ["TOKEN": "${TOKEN}"]]).spec
        #expect(spec?.envVars == ["TOKEN"])
        #expect(spec.map { MCPSetup.translate(codex: .table(MCPSetup.codexTable($0))).spec == $0 } == true)
    }

    @Test func pluginAndProjectServersStayWithTheirOwner() {
        let spec = MCPSetup.Translation.spec(.init(command: "server"))
        if case .unshared = MCPSetup.plan(claude: nil, codex: spec, record: nil, projects: 1, claudePlugin: nil, codexPlugin: nil) {} else { Issue.record("project server copied") }
        if case .unshared = MCPSetup.plan(claude: spec, codex: nil, record: nil, projects: 0, claudePlugin: nil, codexPlugin: "sample@plugin") {} else { Issue.record("plugin server copied") }
    }

    @Test func changesRemovalsAndConflictsUseTheLastAgreement() {
        let original = MCPSetup.MCPSpec(command: "old"), edited = MCPSetup.MCPSpec(command: "new")
        let record = MCPSetup.Record(name: "x", claude: MCPSetup.hash(original), codex: MCPSetup.hash(original))
        #expect(MCPSetup.plan(claude: .spec(edited), codex: .spec(original), record: record, projects: 0, claudePlugin: nil, codexPlugin: nil) == .copy(edited, to: .codex, .changed))
        #expect(MCPSetup.plan(claude: nil, codex: .spec(original), record: record, projects: 0, claudePlugin: nil, codexPlugin: nil) == .copy(nil, to: .codex, .removed))
        #expect(MCPSetup.plan(claude: nil, codex: .spec(edited), record: record, projects: 0, claudePlugin: nil, codexPlugin: nil) == .conflict(claude: nil, codex: edited, changedInBoth: true))
    }

    @Test func codexEditsWaitAndRejectChangedServerButKeepUnrelatedEdits() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{"sample":{"command":"server"}}}"#)
        try home.write(".codex/config.toml", "model = \"before\"\n")
        let change = try #require(MCPSetup.scan(home.context()).changes.first)
        #expect(SetupApplier(context: home.context(running: [.chatGPT])).apply([change]).applied.isEmpty)
        try home.write(".codex/config.toml", "model = \"after\"\n")
        #expect(SetupApplier(context: home.context()).apply([change]).applied.count == 1)
        #expect(home.read(".codex/config.toml")?.contains("model = \"after\"") == true)
        #expect(SetupApplier(context: home.context()).apply([change]).applied.isEmpty)
    }

    @Test func everyMappedFieldTravelsBothWaysAndReadsBackTheSame() throws {
        let url = "https://example.org/mcp"
        // Each row is one server as Claude and as Codex write it.
        let rows: [(claude: [String: Any], codex: [String: TOMLValue])] = [
            (["type": "stdio", "command": "server", "args": []], ["command": .string("server")]),
            (["type": "stdio", "command": "server", "args": ["-y", "package"]], ["command": .string("server"), "args": .array([.string("-y"), .string("package")])]),
            (["type": "stdio", "command": "server", "args": [], "env": ["TOKEN": "${TOKEN}"]], ["command": .string("server"), "env_vars": .array([.string("TOKEN")])]),
            (["type": "http", "url": url], ["url": .string(url)]),
            (["type": "http", "url": url, "headers": ["Authorization": "Bearer ${TOKEN}"]], ["url": .string(url), "bearer_token_env_var": .string("TOKEN")]),
            (["type": "http", "url": url, "headers": ["X-Key": "${KEY}"]], ["url": .string(url), "env_http_headers": .table(["X-Key": .string("KEY")])]),
            (["type": "http", "url": url, "headersHelper": "headers-helper"], ["url": .string(url), "http_headers_helper": .string("headers-helper")]),
            (["type": "http", "url": url, "timeout": 120_000], ["url": .string(url), "tool_timeout_sec": .integer(120)]),
            (["type": "http", "url": url, "timeout": 1500], ["url": .string(url), "tool_timeout_sec": .float(1.5)]),
        ]
        for row in rows {
            let fromClaude = try #require(MCPSetup.translate(claude: row.claude).spec)
            let fromCodex = try #require(MCPSetup.translate(codex: .table(row.codex)).spec)
            #expect(fromClaude == fromCodex)
            #expect(MCPSetup.codexTable(fromClaude) == row.codex)
            #expect(MCPSetup.json(MCPSetup.claudeEntry(fromCodex)) == MCPSetup.json(row.claude))
        }
    }

    @Test func aTransportSwitchKeepsOnlyTheOwnFieldsThatFitIt() {
        let stdio = MCPSetup.MCPSpec(command: "server"), http = MCPSetup.MCPSpec(url: "https://example.org/mcp")
        // Codex refuses cwd on an HTTP server and auth, oauth and oauth_resource on a stdio one.
        let codexStdio: [String: TOMLValue] = ["command": .string("old"), "cwd": .string("/Users/me"), "enabled_tools": .array([.string("read")])]
        #expect(MCPSetup.codexTable(http, keeping: codexStdio) == ["url": .string("https://example.org/mcp"), "enabled_tools": .array([.string("read")])])
        let codexHTTP: [String: TOMLValue] = ["url": .string("https://old.example"), "oauth_resource": .string("https://old.example"), "auth": .string("chatgpt"),
                                               "oauth": .table(["client_id": .string("id")]), "startup_timeout_sec": .integer(30)]
        #expect(MCPSetup.codexTable(stdio, keeping: codexHTTP) == ["command": .string("server"), "startup_timeout_sec": .integer(30)])
        // Claude drops oauth, tools and the other HTTP-only fields from a stdio server, so they would never verify.
        let claudeHTTP: [String: Any] = ["type": "http", "url": "https://old.example", "oauth": ["clientId": "id"], "tools": [["name": "read"]],
                                         "request_timeout_ms": 5000, "toolPermissions": ["read": "allow"], "discoveryCache": true, "alwaysLoad": true]
        #expect(MCPSetup.json(MCPSetup.claudeEntry(stdio, keeping: claudeHTTP)) == MCPSetup.json(["type": "stdio", "command": "server", "args": [String](), "alwaysLoad": true]))
        let claudeStdio: [String: Any] = ["type": "stdio", "command": "old", "args": ["a"], "env": ["A": "${A}"], "alwaysLoad": true]
        #expect(MCPSetup.json(MCPSetup.claudeEntry(http, keeping: claudeStdio)) == MCPSetup.json(["type": "http", "url": "https://example.org/mcp", "alwaysLoad": true]))
    }

    @Test func aServerMovedToAURLInClaudeLeavesCodexAConfigItLoads() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{"gh":{"type":"stdio","command":"gh-mcp","args":[]}}}"#)
        try home.write(".codex/config.toml", "[mcp_servers.gh]\ncommand = \"gh-mcp\"\ncwd = \"/Users/me\"\nstartup_timeout_sec = 60\n")
        let context = home.context(run: claudeCLI(home))
        #expect(SetupApplier(context: context).apply(MCPSetup.scan(context).changes).skipped.isEmpty)
        try home.write(".claude.json", #"{"mcpServers":{"gh":{"type":"http","url":"https://api.example.com/mcp/"}}}"#)
        let change = try #require(MCPSetup.scan(context).changes.first { $0.id == "mcp.codex.changed.gh" })
        #expect(SetupApplier(context: context).apply([change]).skipped.isEmpty)
        let config = try #require(home.read(".codex/config.toml").flatMap(TOMLFile.init(text:)))
        #expect(config.mcpServers["gh"] == .table(["url": .string("https://api.example.com/mcp/"), "startup_timeout_sec": .integer(60)]))
        #expect(MCPSetup.scan(context).changes.isEmpty)
    }

    @Test func anArglessStdioServerReachesClaudeInTheShapeClaudeStores() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", "[mcp_servers.localtool]\ncommand = \"/opt/tools/localtool-mcp\"\n\n[mcp_servers.figma]\nurl = \"https://mcp.figma.com/mcp\"\n")
        let context = home.context(run: claudeCLI(home))
        let result = SetupApplier(context: context).apply(MCPSetup.scan(context).changes)
        #expect(result.skipped.isEmpty)
        #expect(MCPSetup.readClaude(context)?.servers.keys.sorted() == ["figma", "localtool"])
        #expect(MCPSetup.scan(context).changes.isEmpty)
    }

    @Test func keysInArgsOrURLsAreNeverCopiedOrShown() throws {
        let home = try SetupHome()
        let secret = "FAKE-SECRET-4f8a", pathSecret = "zp4kq8Hc2nT7wV1xR9mB3yL6dJ0fG5sA"
        try home.write(".claude.json", """
            {"mcpServers":{
              "context7":{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp","--api-key","\(secret)"]},
              "exa":{"type":"http","url":"https://mcp.exa.ai/mcp?exaApiKey=\(secret)"},
              "basic":{"type":"http","url":"https://me:\(secret)@example.org/mcp"},
              "zap":{"type":"http","url":"https://mcp.zapier.com/api/mcp/s/\(pathSecret)/mcp"},
              "remote":{"type":"stdio","command":"npx","args":["mcp-remote","https://example.org/mcp?access_token=\(secret)"]}
            }}
            """)
        try home.write(".codex/config.toml", """
            [mcp_servers.zap]
            url = "https://mcp.zapier.com/api/mcp/mcp"

            [mcp_servers.tokens]
            command = "server"
            args = ["--token=\(secret)"]
            """)
        let report = MCPSetup.scan(home.context())
        #expect(report.changes.isEmpty)
        #expect(report.items.allSatisfy { $0.claude == .notShared && $0.codex == .notShared })
        #expect(report.items.first { $0.name == "exa" }?.note == "Its URL holds what looks like a key, so it is not copied")
        #expect(report.items.first { $0.name == "tokens" }?.note == "Its arguments hold what looks like a key, so it is not copied")
        let everything = String(describing: report)
        #expect(!everything.contains(secret) && !everything.contains(pathSecret))
        // Ordinary arguments and URLs still travel.
        #expect(MCPSetup.translate(claude: ["command": "npx", "args": ["-y", "@playwright/mcp@latest", "--browser", "chrome", "--port=8931"]]).spec != nil)
        #expect(MCPSetup.translate(codex: .table(["url": .string("https://developer.example.com/mcp?branch=main")])).spec != nil)
    }

    @Test func aNameClaudeRefusesStaysInCodexAndTheOthersStillReachClaude() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", """
            [mcp_servers.figma]
            url = "https://mcp.figma.com/mcp"

            [mcp_servers."docs.internal"]
            url = "https://docs.example/mcp"

            [mcp_servers.instant]
            url = "https://instant.example/mcp"
            tool_timeout_sec = 0
            """)
        let context = home.context(run: claudeCLI(home))
        let report = MCPSetup.scan(context)
        #expect(report.changes.map(\.title) == ["Claude gets figma from Codex"])
        #expect(report.items.first { $0.name == "docs.internal" }?.note == "Claude takes only letters, digits, - and _ in a server name")
        #expect(report.items.first { $0.name == "instant" }?.note == "Claude can't take its tool_timeout_sec")
        #expect(SetupApplier(context: context).apply(report.changes).skipped.isEmpty)
        #expect(MCPSetup.scan(context).changes.isEmpty)
    }

    @Test func aSideResetAfterASyncRemovesNothingFromTheOtherAndGetsItsServersBack() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{"a":{"type":"http","url":"https://a.example/mcp"},"b":{"type":"http","url":"https://b.example/mcp"}}}"#)
        try home.write(".codex/config.toml", "[mcp_servers.a]\nurl = \"https://a.example/mcp\"\n\n[mcp_servers.b]\nurl = \"https://b.example/mcp\"\n")
        let context = home.context(run: claudeCLI(home))
        let applier = SetupApplier(context: context)
        #expect(applier.apply(MCPSetup.scan(context).changes).skipped.isEmpty)

        try FileManager.default.removeItem(atPath: home.path(".codex/config.toml"))
        var report = MCPSetup.scan(context)
        #expect(!report.changes.contains(where: removes))
        #expect(report.attention.map(\.text) == ["Codex has no MCP servers, so none are removed from Claude"])
        #expect(report.attention.first?.level == .broken)
        #expect(report.changes.map(\.title) == ["Codex gets 2 servers from Claude"])
        #expect(applier.apply(report.changes).skipped.isEmpty)
        #expect(MCPSetup.scan(context).changes.isEmpty)

        try home.write(".claude.json", "{}")
        report = MCPSetup.scan(context)
        #expect(!report.changes.contains(where: removes))
        #expect(report.attention.map(\.text) == ["Claude has no MCP servers, so none are removed from Codex"])
        #expect(report.changes.map(\.title) == ["Claude gets 2 servers from Codex"])
    }

    @Test func aServerTurnedOffInCodexIsNotAddedToClaude() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", "[mcp_servers.off]\nurl = \"https://example.org/mcp\"\nenabled = false\n")
        let report = MCPSetup.scan(home.context())
        #expect(report.changes.isEmpty)
        #expect(report.items.first?.note == "Turned off in Codex")
    }

    @Test func aTimeoutClaudeCantTakeIsNotSharedAndNeverTraps() {
        for timeout: TOMLValue in [.integer(10_000_000_000_000_000), .integer(-10_000_000_000_000_000), .float(1e20), .float(.infinity), .integer(0)] {
            let translation = MCPSetup.translate(codex: .table(["url": .string("https://example.org/mcp"), "tool_timeout_sec": timeout]))
            #expect(translation == .unshared("Claude can't take its tool_timeout_sec"))
        }
    }

    @Test func notesSayTheTrueReason() {
        let app = TOMLValue.table(["command": .string("/Applications/ChatGPT.app/Contents/Resources/node"), "env": .table(["DEBUG": .string("1")])])
        #expect(MCPSetup.translate(codex: app) == .unshared("Runs from inside ChatGPT.app, so it stays with that app"))
        let registry = TOMLValue.table(["command": .string("npx"), "env": .table(["NPM_CONFIG_REGISTRY": .string("https://registry.npmjs.org")])])
        #expect(MCPSetup.translate(codex: registry) == .unshared("Codex's env holds values written in the file. List them in env_vars to share it."))
        let headers = TOMLValue.table(["url": .string("https://example.org/mcp"), "http_headers": .table(["X-Team": .string("one")])])
        #expect(MCPSetup.translate(codex: headers) == .unshared("Codex's http_headers hold values written in the file. Use env_http_headers to share it."))
        #expect(MCPSetup.translate(claude: ["command": "server", "env": ["PROJECT": "one"]]) == .unshared("Claude's env holds values written in the file. Write each as ${NAME} to share it."))
        #expect(MCPSetup.translate(claude: ["type": "http", "url": "https://example.org/mcp", "headers": ["X-Team": "one"]])
            == .unshared("Claude's headers hold values written in the file. Write each as ${VAR} to share it."))
        // Claude reads streamable-http as http.
        #expect(MCPSetup.translate(claude: ["type": "streamable-http", "url": "https://example.org/mcp"]).spec == MCPSetup.MCPSpec(url: "https://example.org/mcp"))
    }
}

/// Whether a change takes a server away from either tool.
private func removes(_ change: SetupChange) -> Bool {
    change.operations.contains {
        switch $0 {
        case .toml(_, ["mcp_servers"], _, nil, _?), .claudeMCP(_, nil, _?): true
        default: false
        }
    }
}

/// Claude's CLI as 2.1.307 behaves: it refuses a name other than letters, digits, - and _, a timeout not above 0
/// and an empty command; it reads streamable-http as http and stores a stdio server with "args" (even none) and
/// without HTTP-only fields.
private func claudeCLI(_ home: SetupHome) -> @Sendable ([String]) -> (status: Int32, output: String)? {
    { argv in
        guard argv.count >= 6, argv[0] == "claude" else { return nil }
        let file = home.url.appending(path: ".claude.json"), name = argv[5]
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        if argv[2] == "remove" {
            guard servers.removeValue(forKey: name) != nil else { return (1, "") }
        } else {
            guard name.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil, argv.count == 7,
                  var entry = (try? JSONSerialization.jsonObject(with: Data(argv[6].utf8))) as? [String: Any],
                  (entry["timeout"] as? Int ?? 1) > 0 else { return (1, "") }
            if entry["url"] == nil {
                guard let command = entry["command"] as? String, !command.isEmpty else { return (1, "") }
                entry["args"] = entry["args"] ?? [String]()
                for key in ["oauth", "request_timeout_ms", "tools", "toolPermissions", "discoveryCache", "cwd"] { entry[key] = nil }
            } else if entry["type"] as? String == "streamable-http" {
                entry["type"] = "http"
            }
            servers[name] = entry
        }
        object["mcpServers"] = servers
        do { try home.write(".claude.json", MCPSetup.json(object)); return (0, "") } catch { return (1, "") }
    }
}
