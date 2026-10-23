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

    @Test func aggregatorReportsAllSixAreasWithoutApplying() throws {
        let home = try SetupHome()
        let reports = OneSetup.scan(home.context())
        #expect(Set(reports.map(\.area)) == Set(SetupArea.allCases))
        #expect(home.read(".claude/settings.json") == nil)
        #expect(home.read(".codex/config.toml") == nil)
    }
}
