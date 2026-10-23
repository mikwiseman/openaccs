import Foundation
import Testing
@testable import SetupKit

@Suite struct IntegrationTests {
    @Test func matchingSkillDocumentsDoNotMakeDifferentScriptsDuplicates() throws {
        let home = try SetupHome()
        for directory in [".agents", ".codex"] {
            try home.write("\(directory)/skills/example/SKILL.md", "---\nname: example\ndescription: Test skill\n---\nRun scripts/run.sh\n")
            try home.write("\(directory)/skills/example/scripts/run.sh", "echo \(directory)\n")
        }
        #expect(!SkillsSetup.scan(home.context()).changes.contains { $0.id == "skills.duplicates" })
    }
    @Test func anIndividualSkillDoesNotRequireEarlierUnselectedSkills() throws {
        let home = try SetupHome()
        for name in ["first", "second"] {
            try home.write(".claude/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: Test skill\n---\nHello\n")
        }
        let change = try #require(SkillsSetup.scan(home.context()).changes.first { $0.id == "skills.share.second" })
        #expect(SetupApplier(context: home.context()).apply([change]).applied.count == 1)
        #expect(home.linkTarget(".claude/skills/first") == nil)
        #expect(home.linkTarget(".claude/skills/second") != nil)
    }

    @Test func importCleanupPrecedesSharingTheOriginalSkill() throws {
        let home = try SetupHome()
        try home.write(".codex/config.toml", "[desktop]\nexternal-agent-import-sync-enabled = true\n")
        let original = "---\nname: sample\ndescription: Test skill\n---\nUse Claude\n"
        try home.write(".claude/skills/sample/SKILL.md", original)
        try home.write(".agents/skills/sample/SKILL.md", original.replacingOccurrences(of: "Claude", with: "Codex"))
        let context = home.context { _ in (0, #"[{"provider_id":"claude","item_type":"SKILLS","source":"sample","target":"sample"}]"#) }
        let reports = OneSetup.scan(context)
        let share = try #require(reports.changes.first { $0.id == "skills.share.sample" })
        #expect(share.requires.contains("importSync.remove-copies"))
        let result = SetupApplier(context: context).apply(reports.recommendedChanges)
        #expect(result.skipped.isEmpty)
        #expect(home.read(".agents/skills/sample/SKILL.md") == original)
        #expect(home.linkTarget(".claude/skills/sample") == home.path(".agents/skills/sample"))
    }

    @Test func failedHistoryWriteRollsBackChanges() throws {
        let home = try SetupHome()
        try home.write("Library/Application Support/OpenAccs/setup-history.json/block", "a folder blocks saving history")
        let path = try home.write("example", "before")
        let result = SetupApplier(context: home.context()).apply([
            SetupChange(id: "x", area: .instructions, title: "x", operations: [
                .write(path: path, contents: Data("after".utf8), expected: FileState.of(URL(filePath: path)))
            ])
        ])
        #expect(result.applied.isEmpty)
        #expect(home.read("example") == "before")
    }
    @Test func selectedAreasShareOneConfigAndUndoRestoresIt() throws {
        let home = try SetupHome()
        let original = "model = \"keep-me\" # stays\n\n[desktop]\nexternal-agent-import-sync-enabled = true\n"
        try home.write(".codex/config.toml", original)
        try home.write(".claude.json", #"{"mcpServers":{"sample":{"command":"sample-server"}}}"#)
        let context = home.context()
        let changes = [ImportSyncSetup.scan(context), MCPSetup.scan(context), DefaultsSetup.scan(context)].changes
        let applier = SetupApplier(context: context)
        let result = applier.apply(changes)
        #expect(result.skipped.isEmpty)
        #expect(result.applied.count == changes.count)
        let config = try #require(home.read(".codex/config.toml").flatMap(TOMLFile.init(text:)))
        #expect(config.value(ImportSyncSetup.syncKey, in: ["desktop"]) == .bool(false))
        #expect(config.mcpServers["sample"]?.table?["command"] == .string("sample-server"))
        #expect(config.value(DefaultsSetup.fallbackKey, in: []) == .array([.string("CLAUDE.md")]))
        #expect(config.text.contains("model = \"keep-me\" # stays"))
        for entry in result.applied.reversed() { try applier.undo(entry.id) }
        #expect(home.read(".codex/config.toml") == original)
    }

    @Test func choosingOneMCPConflictNeverIncludesAnother() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{"a":{"command":"claude-a"},"b":{"command":"claude-b"}}}"#)
        try home.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"codex-a\"\n[mcp_servers.b]\ncommand = \"codex-b\"\n")
        let report = MCPSetup.scan(home.context())
        let choice = try #require(report.changes.first { $0.id == "mcp.use-claude.b" })
        let result = SetupApplier(context: home.context()).apply([choice])
        #expect(result.skipped.isEmpty)
        let config = try #require(home.read(".codex/config.toml").flatMap(TOMLFile.init(text:)))
        #expect(config.mcpServers["a"]?.table?["command"] == .string("codex-a"))
        #expect(config.mcpServers["b"]?.table?["command"] == .string("claude-b"))
    }

    @Test func undoWaitsWhileChatGPTRuns() throws {
        let home = try SetupHome()
        let on = "[desktop]\nexternal-agent-import-sync-enabled = true\n"
        try home.write(".codex/config.toml", on)
        let turnOff = try #require(ImportSyncSetup.scan(home.context()).changes.first { $0.id == "importSync.turn-off" })
        let entry = try #require(SetupApplier(context: home.context()).apply([turnOff]).applied.first)

        // ChatGPT opened since: it keeps config.toml in memory and would save its copy over the undo.
        #expect(throws: SetupError.appRunning("ChatGPT")) { try SetupApplier(context: home.context(running: [.chatGPT])).undo(entry.id) }
        #expect(home.read(".codex/config.toml") == on.replacingOccurrences(of: "true", with: "false"))
        try SetupApplier(context: home.context()).undo(entry.id)
        #expect(home.read(".codex/config.toml") == on)
    }

    @Test func undoIsRefusedWhileALaterChangeNeedsIt() throws {
        let home = try SetupHome()
        let claude = try home.write(".claude/CLAUDE.md", "# Mine\n")
        let old = try home.write(".agents.md", "# Old\n")
        try FileManager.default.createDirectory(atPath: home.path(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path(".codex/AGENTS.md"), withDestinationPath: old)
        let changes = InstructionsSetup.scan(home.context()).changes
        #expect(changes.map(\.id) == ["instructions.link-codex", "instructions.remove-old-copy"])
        let applier = SetupApplier(context: home.context())
        let applied = applier.apply(changes).applied

        // Undone alone, Codex would link to the removed copy again and read nothing.
        #expect(throws: SetupError.neededBy("Remove the old copy ~/.agents.md")) { try applier.undo(applied[0].id) }
        #expect(home.linkTarget(".codex/AGENTS.md") == claude)
        try applier.undo(applied[1].id)
        try applier.undo(applied[0].id)
        #expect(home.linkTarget(".codex/AGENTS.md") == old && home.read(".agents.md") == "# Old\n")
    }

    /// `claude mcp` as Claude Code 2.1 runs it: a stdio server without args is stored with "args": [].
    func claudeLike(_ home: SetupHome) -> @Sendable ([String]) -> (status: Int32, output: String)? {
        { argv in
            guard argv.count >= 6, argv[0] == "claude" else { return nil }
            var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.url.appending(path: ".claude.json")))) as? [String: Any] ?? [:]
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            if argv[2] == "remove" {
                servers[argv[5]] = nil
            } else {
                guard var entry = (try? JSONSerialization.jsonObject(with: Data(argv[6].utf8))) as? [String: Any] else { return (1, "") }
                if entry["url"] == nil, entry["args"] == nil { entry["args"] = [String]() }
                servers[argv[5]] = entry
            }
            object["mcpServers"] = servers
            do { try home.write(".claude.json", MCPSetup.json(object)); return (0, "") } catch { return (1, "") }
        }
    }

    @Test func aStdioServerWithoutArgsReachesClaudeAndUndoes() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{}}"#)
        try home.write(".codex/config.toml", "[mcp_servers.local]\ncommand = \"local-mcp\"\n")
        let context = home.context(run: claudeLike(home))
        let add = try #require(MCPSetup.scan(context).changes.first { $0.id == "mcp.claude.add" })
        let applier = SetupApplier(context: context)

        let result = applier.apply([add])

        #expect(result.skipped.isEmpty)
        #expect(MCPSetup.scan(context).changes.isEmpty)
        try applier.undo(try #require(result.applied.first).id)
        #expect(MCPSetup.readClaude(context)?.servers.isEmpty == true)
    }

    @Test func undoingARemovalBringsBackAClaudeEntryWithoutArgs() throws {
        let home = try SetupHome()
        try home.write(".claude.json", #"{"mcpServers":{"eye":{"command":"/opt/eye","type":"stdio"}}}"#)
        try home.write(".codex/config.toml", "[mcp_servers.eye]\ncommand = \"/opt/eye\"\n")
        let context = home.context(run: claudeLike(home))
        let applier = SetupApplier(context: context)
        #expect(applier.apply(MCPSetup.scan(context).changes).applied.count == 1)   // remembers eye as the same in both
        try home.write(".codex/config.toml", "[mcp_servers.other]\ncommand = \"other\"\n")   // then removed from Codex
        let removal = try #require(MCPSetup.scan(context).changes.first { $0.id == "mcp.claude.removed.eye" })
        let entry = try #require(applier.apply([removal]).applied.first)
        #expect(MCPSetup.readClaude(context)?.servers["eye"] == nil)

        try applier.undo(entry.id)

        #expect((MCPSetup.readClaude(context)?.servers["eye"] as? [String: Any])?["command"] as? String == "/opt/eye")
    }

    @Test func aggregatorReportsAllSixAreasWithoutApplying() throws {
        let home = try SetupHome()
        let reports = OneSetup.scan(home.context())
        #expect(Set(reports.map(\.area)) == Set(SetupArea.allCases))
        #expect(home.read(".claude/settings.json") == nil)
        #expect(home.read(".codex/config.toml") == nil)
    }
}
