import Foundation
import Testing
@testable import SetupKit

/// A throwaway home folder. Tests never see the real one.
final class SetupHome: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "setupkit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> String { url.appending(path: relative).path }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.path
    }

    func read(_ relative: String) -> String? { try? String(contentsOfFile: path(relative), encoding: .utf8) }
    func linkTarget(_ relative: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: path(relative)) }

    func context(running: Set<SetupApp> = [], run: @escaping @Sendable ([String]) -> (status: Int32, output: String)? = { _ in (0, "") }) -> SetupContext {
        SetupContext(home: url, claudeProfiles: [], isRunning: { running.contains($0) }, run: run)
    }
}

final class Calls: @unchecked Sendable {
    var argv: [[String]] = []
}

@Suite struct ApplyTests {
    @Test func appliesWritesLinksAndRemovalsAndUndoesThemExactly() throws {
        let home = try SetupHome()
        let claudeMD = try home.write(".claude/CLAUDE.md", "# Mine\n")
        let old = try home.write(".codex/AGENTS.md", "# Old copy\n")
        let stray = try home.write("AGENTS.md", "# Stray\n")
        let applier = SetupApplier(context: home.context())
        let change = SetupChange(id: "instructions.one", area: .instructions, title: "One instructions file", operations: [
            .write(path: claudeMD, contents: Data("# Mine, merged\n".utf8), expected: FileState.of(URL(filePath: claudeMD))),
            .link(path: old, target: claudeMD, expected: FileState.of(URL(filePath: old))),
            .remove(path: stray, expected: FileState.of(URL(filePath: stray))),
        ])

        let result = applier.apply([change])

        #expect(result.applied.count == 1 && result.skipped.isEmpty)
        #expect(home.read(".claude/CLAUDE.md") == "# Mine, merged\n")
        #expect(home.linkTarget(".codex/AGENTS.md") == claudeMD)
        #expect(!FileManager.default.fileExists(atPath: stray))
        #expect(applier.history().count == 1)

        try applier.undo(result.applied[0].id)

        #expect(home.read(".claude/CLAUDE.md") == "# Mine\n")
        #expect(home.linkTarget(".codex/AGENTS.md") == nil)
        #expect(home.read(".codex/AGENTS.md") == "# Old copy\n")
        #expect(home.read("AGENTS.md") == "# Stray\n")
        #expect(applier.history().first?.undoneAt != nil)
        #expect(throws: SetupError.nothingToUndo) { try applier.undo(result.applied[0].id) }
    }

    @Test func aChangeIsSkippedWhenAFileChangedSinceItWasPlanned() throws {
        let home = try SetupHome()
        let file = try home.write(".codex/config.toml", "model = \"a\"\n")
        let planned = FileState.of(URL(filePath: file))
        try home.write(".codex/config.toml", "model = \"b\"\n")   // Codex wrote meanwhile
        let result = SetupApplier(context: home.context()).apply([
            SetupChange(id: "x", area: .mcp, title: "x", operations: [.write(path: file, contents: Data("new".utf8), expected: planned)]),
        ])
        #expect(result.applied.isEmpty)
        #expect(result.skipped.first?.reason == "changed since you reviewed it")
        #expect(home.read(".codex/config.toml") == "model = \"b\"\n")
    }

    @Test func aChangeWaitsWhileItsAppRuns() throws {
        let home = try SetupHome()
        let file = home.path(".codex/config.toml")
        let result = SetupApplier(context: home.context(running: [.chatGPT])).apply([
            SetupChange(id: "x", area: .mcp, title: "x", operations: [.write(path: file, contents: Data("new".utf8), expected: .absent)], waitsFor: .chatGPT),
        ])
        #expect(result.skipped.first?.reason == "waits for ChatGPT to close")
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func aFailureHalfwayPutsBackWhatThatChangeDid() throws {
        let home = try SetupHome()
        let file = try home.write("a.md", "before")
        let calls = Calls()
        let applier = SetupApplier(context: home.context { argv in
            calls.argv.append(argv)
            return (argv.first == "fail" ? 1 : 0, "")
        })
        let result = applier.apply([SetupChange(id: "x", area: .mcp, title: "x", operations: [
            .write(path: file, contents: Data("after".utf8), expected: FileState.of(URL(filePath: file))),
            .command(argv: ["claude", "mcp", "add-json", "x", "{}"], undo: ["claude", "mcp", "remove", "x"]),
            .command(argv: ["fail"], undo: []),
        ])])
        #expect(result.applied.isEmpty)
        #expect(home.read("a.md") == "before")
        #expect(calls.argv == [["claude", "mcp", "add-json", "x", "{}"], ["fail"], ["claude", "mcp", "remove", "x"]])
        #expect(applier.history().isEmpty)
    }

    @Test func aSkillFolderMovesAndLinksBackAndUndoes() throws {
        let home = try SetupHome()
        try home.write(".claude/skills/liquid-glass/SKILL.md", "---\nname: liquid-glass\n---\n")
        let from = home.path(".claude/skills/liquid-glass"), to = home.path(".agents/skills/liquid-glass")
        let applier = SetupApplier(context: home.context())
        let result = applier.apply([SetupChange(id: "skills.share.liquid-glass", area: .skills, title: "Share liquid-glass with Codex", operations: [
            .move(path: from, destination: to, expected: .folder),
            .link(path: from, target: to, expected: .absent),
        ])])
        #expect(result.applied.count == 1)
        #expect(home.linkTarget(".claude/skills/liquid-glass") == to)
        #expect(home.read(".agents/skills/liquid-glass/SKILL.md") != nil)
        try applier.undo(result.applied[0].id)
        #expect(home.linkTarget(".claude/skills/liquid-glass") == nil)
        #expect(home.read(".claude/skills/liquid-glass/SKILL.md") != nil)
        #expect(!FileManager.default.fileExists(atPath: to))
    }

    @Test func undoIsRefusedWhenSomethingChangedSince() throws {
        let home = try SetupHome()
        let file = try home.write("CLAUDE.md", "one")
        let applier = SetupApplier(context: home.context())
        let result = applier.apply([SetupChange(id: "x", area: .instructions, title: "x", operations: [
            .write(path: file, contents: Data("two".utf8), expected: FileState.of(URL(filePath: file))),
        ])])
        try home.write("CLAUDE.md", "three")   // edited by hand after applying
        #expect(throws: SetupError.changedSince) { try applier.undo(result.applied[0].id) }
        #expect(home.read("CLAUDE.md") == "three")
    }
}
