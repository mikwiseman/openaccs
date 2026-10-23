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

    @Test func aChangeThatNeedsAnotherAppliesOnlyAfterIt() throws {
        let home = try SetupHome()
        let old = try home.write(".agents.md", "# Old\n")
        let link = home.path(".codex/AGENTS.md")
        try FileManager.default.createDirectory(atPath: home.path(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: old)
        let claude = try home.write(".claude/CLAUDE.md", "# Mine\n")
        let relink = SetupChange(id: "link", area: .instructions, title: "Codex reads your CLAUDE.md",
                                 operations: [.link(path: link, target: claude, expected: FileState.of(URL(filePath: link)))])
        let removeOld = SetupChange(id: "old", area: .instructions, title: "Remove the old copy",
                                    operations: [.remove(path: old, expected: FileState.of(URL(filePath: old)))], requires: ["link"])
        let applier = SetupApplier(context: home.context())

        // Alone, it would leave Codex's link broken: skipped.
        let alone = applier.apply([removeOld])
        #expect(alone.applied.isEmpty && alone.skipped.first?.reason == "needs “link” too")
        #expect(home.read(".agents.md") == "# Old\n")
        // Listed first, it still goes after what it needs.
        let both = applier.apply([removeOld, relink])
        #expect(both.applied.map(\.title) == ["Codex reads your CLAUDE.md", "Remove the old copy"])
        #expect(home.linkTarget(".codex/AGENTS.md") == claude)
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

    @Test func undoWaitsWhileItsAppRuns() throws {
        let home = try SetupHome()
        let profile = home.path("Profiles/ai41")
        let file = try home.write("Profiles/ai41/claude_desktop_config.json", "{}")
        let change = SetupChange(id: "claudeApp.ai41", area: .claudeApp, title: "ai41 gets 1 setting", operations: [
            .write(path: file, contents: Data(#"{"a":1}"#.utf8), expected: FileState.of(URL(filePath: file))),
        ], waitsFor: .claude(profile))
        let entry = try #require(SetupApplier(context: home.context()).apply([change]).applied.first)

        // Opened again since: the app would save its copy over the undo.
        #expect(throws: SetupError.appRunning("the Claude window using ai41")) {
            try SetupApplier(context: home.context(running: [.claude(profile)])).undo(entry.id)
        }
        #expect(home.read("Profiles/ai41/claude_desktop_config.json") == #"{"a":1}"#)
        try SetupApplier(context: home.context()).undo(entry.id)
        #expect(home.read("Profiles/ai41/claude_desktop_config.json") == "{}")
    }

    @Test func historyFromBeforeChangeIDsStillLoadsAndUndoes() throws {
        let home = try SetupHome()
        let file = try home.write("CLAUDE.md", "one")
        let applier = SetupApplier(context: home.context())
        _ = applier.apply([SetupChange(id: "x", area: .instructions, title: "x", operations: [
            .write(path: file, contents: Data("two".utf8), expected: FileState.of(URL(filePath: file))),
        ], waitsFor: .chatGPT)])
        // As OpenAccs 0.4.0 saved it, without the keys added since.
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: applier.historyFile)) as? [[String: Any]])
        for key in ["changeID", "requires", "waitsFor"] { saved[0][key] = nil }
        try JSONSerialization.data(withJSONObject: saved).write(to: applier.historyFile)

        let entry = try #require(applier.history().first)
        #expect(entry.changeID == nil && entry.requires == nil && entry.waitsFor == nil)
        try applier.undo(entry.id)
        #expect(home.read("CLAUDE.md") == "one")
    }

    @Test func undoWithItsBackupGoneChangesNothing() throws {
        let home = try SetupHome()
        let file = try home.write(".claude/settings.json", "{}")
        let applier = SetupApplier(context: home.context())
        let entry = try #require(applier.apply([SetupChange(id: "x", area: .defaults, title: "x", operations: [
            .write(path: file, contents: Data(#"{"cleanupPeriodDays":3650}"#.utf8), expected: FileState.of(URL(filePath: file))),
        ])]).applied.first)
        try FileManager.default.removeItem(at: home.context().paths.backupsDir)   // Backups cleared by hand

        for _ in 0..<2 { #expect(throws: SetupError.backupGone) { try applier.undo(entry.id) } }
        #expect(home.read(".claude/settings.json") == #"{"cleanupPeriodDays":3650}"#)
        #expect(applier.history().first?.undoneAt == nil)
    }

    @Test func aFailedUndoPutsBackWhatItDid() throws {
        let home = try SetupHome()
        let file = try home.write("a.md", "before")
        let applier = SetupApplier(context: home.context { argv in (argv.first == "fail" ? 1 : 0, "") })
        let entry = try #require(applier.apply([SetupChange(id: "x", area: .mcp, title: "x", operations: [
            .command(argv: ["add"], undo: ["fail"]),
            .write(path: file, contents: Data("after".utf8), expected: FileState.of(URL(filePath: file))),
        ])]).applied.first)

        // Undo puts a.md back first, then the command fails: a.md goes back to what Apply left.
        #expect(throws: SetupError.commandFailed("fail")) { try applier.undo(entry.id) }
        #expect(home.read("a.md") == "after")
        #expect(applier.history().first?.undoneAt == nil)
    }

    @Test func aBackupThatCantBeCopiedLeavesTheFileInPlace() throws {
        let home = try SetupHome()
        let file = try home.write("a.md", "before")
        let applier = SetupApplier(context: home.context())
        let entry = try #require(applier.apply([SetupChange(id: "x", area: .instructions, title: "x", operations: [
            .write(path: file, contents: Data("after".utf8), expected: FileState.of(URL(filePath: file))),
        ])]).applied.first)
        guard case .restore(_, let backup, _)? = entry.undo.first else { Issue.record("no backup"); return }
        // Unreadable, so copying it back fails the way a full disk would.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: backup)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup) }

        #expect(throws: (any Error).self) { try applier.undo(entry.id) }
        #expect(home.read("a.md") == "after")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.url.path).sorted() == ["Library", "a.md"])
    }
}
