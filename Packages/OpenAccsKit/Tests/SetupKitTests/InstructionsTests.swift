import Foundation
import Testing
@testable import SetupKit

@Suite struct InstructionsTests {
    static let claude = """
        # Global agent instructions

        Simplicity is power.

        ## How to work

        Make the smallest change that fully solves the problem.

        ## Communication

        Lead with the answer.

        ## Tools and surfaces

        Use Claude in Chrome for sites where Mik is signed in.

        """
    /// Like ~/.agents.md on Mik's Mac: older, no Communication section, one extra line.
    static let older = """
        # Global agent instructions

        Simplicity is power.
        Be concise.

        ## How to work

        Make the smallest change that fully solves the problem.

        ## Tools and surfaces

        Use Claude in Chrome for sites where Mik is signed in.

        """
    /// Like ~/AGENTS.md from ChatGPT Import: the same file with Claude rewritten to Codex.
    static let imported = claude.replacingOccurrences(of: "Claude in Chrome", with: "Codex in Chrome")

    /// The shape of Mik's Mac: CLAUDE.md, ~/.codex/AGENTS.md linking to an older ~/.agents.md, and ~/AGENTS.md.
    func macLikeHome() throws -> SetupHome {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", Self.claude)
        try home.write(".agents.md", Self.older)
        try home.write("AGENTS.md", Self.imported)
        try link(home, ".codex/AGENTS.md", to: home.path(".agents.md"))
        return home
    }

    func link(_ home: SetupHome, _ relative: String, to target: String) throws {
        let url = home.url.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    func bytes(_ home: SetupHome, _ relative: String) -> Data? { try? Data(contentsOf: home.url.appending(path: relative)) }

    /// What every path in the home holds (OpenAccs's own Library folder aside), to tell that nothing changed.
    func snapshot(_ home: SetupHome) -> [String: FileState] {
        var all: [String: FileState] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: home.url.path)! where !path.hasPrefix("Library") {
            all[path] = FileState.of(home.url.appending(path: path))
        }
        return all
    }

    @Test func oneFileWhenCodexLinksToClaudeMD() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", String(repeating: String(repeating: "x", count: 99) + "\n", count: 40))
        try link(home, ".codex/AGENTS.md", to: home.path(".claude/CLAUDE.md"))

        let report = InstructionsSetup.scan(home.context())

        #expect(report.summary == "One file · 40 lines · ≈1.0k tokens")
        #expect(report.changes.isEmpty && report.attention.isEmpty)
        #expect(report.items == [
            SetupItem(id: "instructions.claude-md", name: "~/.claude/CLAUDE.md", claude: .same, codex: .same, note: "40 lines"),
            SetupItem(id: "instructions.codex-md", name: "~/.codex/AGENTS.md", claude: .notShared, codex: .same, note: "Link to ~/.claude/CLAUDE.md · 40 lines"),
        ])
    }

    @Test func macShapedHomeOffersTheLinkAndRemovesBothCopies() throws {
        let home = try macLikeHome()

        let report = InstructionsSetup.scan(home.context())

        #expect(report.summary == "Claude and Codex read different instructions")
        #expect(report.attention == [
            Attention(id: "instructions.codex-differs", text: "Codex reads different instructions (5 lines differ)", fixes: ["instructions.link-codex"]),
            Attention(id: "instructions.home-copy", text: "Claude reads ~/AGENTS.md too, a second copy", fixes: ["instructions.remove-home-copy"]),
        ])
        #expect(report.changes.map(\.title) == ["Codex reads your CLAUDE.md", "Remove the second copy ~/AGENTS.md", "Remove the old copy ~/.agents.md"])
        #expect(report.changes.map(\.operations) == [
            [.link(path: home.path(".codex/AGENTS.md"), target: home.path(".claude/CLAUDE.md"), expected: .link(target: home.path(".agents.md")))],
            [.remove(path: home.path("AGENTS.md"), expected: FileState.of(home.url.appending(path: "AGENTS.md")))],
            [.remove(path: home.path(".agents.md"), expected: FileState.of(home.url.appending(path: ".agents.md")))],
        ])
        // What Codex would lose is marked "- ", what it gains "+ ".
        let codexDiff = try #require(report.changes[0].detail)
        #expect(codexDiff.contains("- Be concise.") && codexDiff.contains("+ ## Communication") && codexDiff.contains("+ Lead with the answer."))
        #expect(report.changes[1].detail == [
            "  ## Tools and surfaces", "  ", "- Use Codex in Chrome for sites where Mik is signed in.", "+ Use Claude in Chrome for sites where Mik is signed in.",
        ].joined(separator: "\n"))
        #expect(report.changes[2].detail == codexDiff)
        #expect(report.items == [
            SetupItem(id: "instructions.claude-md", name: "~/.claude/CLAUDE.md", claude: .same, codex: .missing, note: "15 lines"),
            SetupItem(id: "instructions.codex-md", name: "~/.codex/AGENTS.md", claude: .notShared, codex: .differs, note: "Link to ~/.agents.md · 12 lines"),
            SetupItem(id: "instructions.home-copy", name: "~/AGENTS.md", claude: .differs, codex: .notShared, note: "15 lines"),
            SetupItem(id: "instructions.old-copy", name: "~/.agents.md", claude: .notShared, codex: .differs, note: "12 lines"),
        ])
    }

    @Test func appliesThenScansCleanThenUndoesByteForByte() throws {
        let home = try macLikeHome()
        let context = home.context()
        let before = snapshot(home)

        let report = InstructionsSetup.scan(context)
        #expect(snapshot(home) == before)   // scanning only reads

        let applier = SetupApplier(context: context)
        let result = applier.apply(report.changes)
        #expect(result.applied.count == 3 && result.skipped.isEmpty)
        #expect(home.linkTarget(".codex/AGENTS.md") == home.path(".claude/CLAUDE.md"))
        #expect(bytes(home, ".claude/CLAUDE.md") == Data(Self.claude.utf8))
        #expect(!FileManager.default.fileExists(atPath: home.path("AGENTS.md")))
        #expect(!FileManager.default.fileExists(atPath: home.path(".agents.md")))

        let again = InstructionsSetup.scan(context)
        #expect(again.changes.isEmpty && again.attention.isEmpty)
        #expect(again.summary == "One file · 15 lines · ≈0.1k tokens")

        for entry in result.applied.reversed() { try applier.undo(entry.id) }
        #expect(snapshot(home) == before)
        #expect(home.linkTarget(".codex/AGENTS.md") == home.path(".agents.md"))
        #expect(bytes(home, "AGENTS.md") == Data(Self.imported.utf8))
        #expect(bytes(home, ".agents.md") == Data(Self.older.utf8))
    }

    @Test func codexWithNoInstructionsGetsTheLink() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", "# Mine\n\nBe brief.\n")

        let report = InstructionsSetup.scan(home.context())

        #expect(report.summary == "Claude and Codex read different instructions")
        #expect(report.attention == [Attention(id: "instructions.codex-none", text: "Codex has no instructions", fixes: ["instructions.link-codex"])])
        #expect(report.changes.map(\.operations) == [[.link(path: home.path(".codex/AGENTS.md"), target: home.path(".claude/CLAUDE.md"), expected: .absent)]])
        #expect(report.changes.first?.detail == "+ # Mine\n+ \n+ Be brief.")
    }

    @Test func codexOwnFileIsBackedUpAndComesBack() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", "# Mine\nBe brief.\n")
        try home.write(".codex/AGENTS.md", "# Mine\nBe thorough.\n")
        let applier = SetupApplier(context: home.context())

        let report = InstructionsSetup.scan(home.context())
        #expect(report.attention.map(\.text) == ["Codex reads different instructions (1 line differs)"])
        #expect(report.changes.map(\.id) == ["instructions.link-codex"])   // a real file is no old copy to remove
        #expect(report.changes.first?.detail == "  # Mine\n- Be thorough.\n+ Be brief.")

        let result = applier.apply(report.changes)
        #expect(home.linkTarget(".codex/AGENTS.md") == home.path(".claude/CLAUDE.md"))
        try applier.undo(result.applied[0].id)
        #expect(home.linkTarget(".codex/AGENTS.md") == nil)
        #expect(home.read(".codex/AGENTS.md") == "# Mine\nBe thorough.\n")
    }

    @Test func twoFilesWithTheSameTextAreNotCalledDifferent() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", "# Mine\n")
        try home.write(".codex/AGENTS.md", "# Mine\n")

        let report = InstructionsSetup.scan(home.context())

        #expect(report.summary == "Claude and Codex read two copies of the same text")
        #expect(report.attention.isEmpty)
        #expect(report.changes.map(\.detail) == ["Same text as CLAUDE.md."])
    }

    @Test func codexReadsAnOverrideFileInstead() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", "# Mine\n")
        try link(home, ".codex/AGENTS.md", to: home.path(".claude/CLAUDE.md"))
        try home.write(".codex/AGENTS.override.md", "# For now\n")

        let report = InstructionsSetup.scan(home.context())

        #expect(report.summary == "Claude and Codex read different instructions")
        #expect(report.attention == [Attention(id: "instructions.override", text: "Codex reads AGENTS.override.md instead")])
        #expect(report.changes.isEmpty)
        #expect(report.items.map(\.codex) == [.missing, .notShared, .differs])

        // Codex skips an override with no text.
        try home.write(".codex/AGENTS.override.md", " \n")
        let empty = InstructionsSetup.scan(home.context())
        #expect(empty.attention.isEmpty && empty.summary.hasPrefix("One file"))
    }

    @Test func anOldCopySomethingElseLinksToStays() throws {
        let home = try SetupHome()
        try home.write(".claude/CLAUDE.md", Self.claude)
        try home.write(".agents.md", Self.older)
        try link(home, ".codex/AGENTS.md", to: home.path(".agents.md"))
        try link(home, "AGENTS.md", to: home.path(".agents.md"))

        let report = InstructionsSetup.scan(home.context())

        #expect(report.changes.map(\.id) == ["instructions.link-codex", "instructions.remove-home-copy"])
        #expect(report.changes[1].operations == [.remove(path: home.path("AGENTS.md"), expected: .link(target: home.path(".agents.md")))])
    }

    @Test func anOldCopyOtherToolsReadThroughLinksStaysAndSaysWhichOnes() throws {
        // Like this Mac: Gemini CLI and opencode read ~/.agents.md through links, one of them relative.
        let home = try macLikeHome()
        try link(home, ".gemini/GEMINI.md", to: home.path(".agents.md"))
        try link(home, ".config/opencode/AGENTS.md", to: "../../.agents.md")

        let report = InstructionsSetup.scan(home.context())

        #expect(report.changes.map(\.id) == ["instructions.link-codex", "instructions.remove-home-copy"])
        #expect(report.items.last == SetupItem(id: "instructions.old-copy", name: "~/.agents.md", claude: .notShared, codex: .differs,
                                               note: "Kept: ~/.config/opencode/AGENTS.md and ~/.gemini/GEMINI.md link to it · 12 lines"))
        let result = SetupApplier(context: home.context()).apply([report].recommendedChanges)
        #expect(result.applied.count == 2)
        #expect(home.read(".gemini/GEMINI.md") == Self.older && home.read(".config/opencode/AGENTS.md") == Self.older)
    }

    @Test func savingThroughALinkWritesTheFileItPointsAtAndKeepsTheLink() throws {
        let home = try SetupHome()
        let real = try home.write("dotfiles/CLAUDE.md", "# Mine\n")
        try link(home, ".claude/CLAUDE.md", to: real)
        let applier = SetupApplier(context: home.context())

        let result = applier.apply([InstructionsSetup.edit(home.context(), from: "# Mine\n", to: "# Mine\nBe brief.\n")])

        #expect(result.applied.count == 1 && result.skipped.isEmpty)
        #expect(home.linkTarget(".claude/CLAUDE.md") == real)
        #expect(home.read("dotfiles/CLAUDE.md") == "# Mine\nBe brief.\n")
        // Planned from text that is no longer there: refused, and nothing changes.
        let stale = applier.apply([InstructionsSetup.edit(home.context(), from: "# Mine\n", to: "# Other\n")])
        #expect(stale.skipped.map(\.reason) == ["changed since you reviewed it"])
        try applier.undo(result.applied[0].id)
        #expect(home.linkTarget(".claude/CLAUDE.md") == real && home.read("dotfiles/CLAUDE.md") == "# Mine\n")
    }

    @Test func savingANewFileCreatesIt() throws {
        let home = try SetupHome()
        let result = SetupApplier(context: home.context()).apply([InstructionsSetup.edit(home.context(), from: "", to: "# Mine\n")])
        #expect(result.applied.count == 1 && home.read(".claude/CLAUDE.md") == "# Mine\n")
    }

    @Test func codexTextBecomesClaudeMDWordForWord() throws {
        let home = try SetupHome()
        try home.write(".claude/settings.json", "{}")
        let theirs = "# Rules\r\nUse “quotes” — ünïcode\nno newline at the end"
        try home.write(".agents.md", theirs)
        try link(home, ".codex/AGENTS.md", to: home.path(".agents.md"))
        let context = home.context()
        let before = snapshot(home)

        let report = InstructionsSetup.scan(context)
        #expect(report.summary == "Claude and Codex read different instructions")
        #expect(report.attention == [Attention(id: "instructions.claude-none", text: "Claude has no CLAUDE.md", fixes: ["instructions.from-codex"])])
        #expect(report.changes.map(\.title) == ["Make Codex's instructions your CLAUDE.md", "Remove the old copy ~/.agents.md"])
        #expect(report.changes[1].detail == "Same text as CLAUDE.md.")

        let applier = SetupApplier(context: context)
        let result = applier.apply(report.changes)
        #expect(result.applied.count == 2)
        #expect(bytes(home, ".claude/CLAUDE.md") == Data(theirs.utf8))
        #expect(home.linkTarget(".codex/AGENTS.md") == home.path(".claude/CLAUDE.md"))

        let again = InstructionsSetup.scan(context)
        #expect(again.changes.isEmpty && again.summary.hasPrefix("One file · 3 lines"))

        for entry in result.applied.reversed() { try applier.undo(entry.id) }
        #expect(snapshot(home) == before)
    }

    @Test func noInstructionsYet() throws {
        let home = try SetupHome()
        let report = InstructionsSetup.scan(home.context())
        #expect(report == AreaReport(area: .instructions, summary: "No instructions yet"))
    }

    @Test func lineDiffShowsChangesWithContextAndACap() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\n", new = "a\nB\nc\nd\ne\nf\ng\nh\nI\n"
        #expect(InstructionsSetup.lineDiff(old, new, context: 1) == "  a\n- b\n+ B\n  c\n…\n  h\n- i\n+ I")
        #expect(InstructionsSetup.lineDiff("same\n", "same") == "")

        let long = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let capped = InstructionsSetup.lineDiff("", long).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(capped.count == 121 && capped[119] == "+ line 120" && capped[120] == "… 80 more lines")
    }

    @Test func aChangedLineCountsOnce() {
        #expect(InstructionsSetup.differingLines("a\nb\nc\n", "a\nB\nc\n") == 1)
        #expect(InstructionsSetup.differingLines("a\n", "a\nb\nc\n") == 2)
        #expect(InstructionsSetup.differingLines("a\nb\n", "a\nb") == 0)
    }
}
