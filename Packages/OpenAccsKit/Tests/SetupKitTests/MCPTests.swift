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
        let context = home.context { argv in
            guard argv.count >= 6, argv[0] == "claude" else { return nil }
            var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.url.appending(path: ".claude.json")))) as? [String: Any] ?? [:]
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            servers[argv[5]] = argv[2] == "remove" ? nil : (try? JSONSerialization.jsonObject(with: Data(argv[6].utf8)))
            object["mcpServers"] = servers
            do { try home.write(".claude.json", MCPSetup.json(object)); return (0, "") } catch { return (1, "") }
        }
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
}
