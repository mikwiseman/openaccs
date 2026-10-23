import Foundation
import Observation
import SetupKit

/// What the Setup tab shows: the last scan of every area, History, and the outcome of the last Apply.
@MainActor @Observable
final class SetupModel {
    private(set) var reports: [AreaReport] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var isScanning = false
    private(set) var isApplying = false
    /// After Apply: one line for what was done and one per change left alone.
    private(set) var outcome: [String] = []

    @ObservationIgnored private let makeContext: @MainActor () -> SetupContext
    @ObservationIgnored private let scanner: @Sendable (SetupContext) -> [AreaReport]

    init(context: @escaping @MainActor () -> SetupContext, scan: @escaping @Sendable (SetupContext) -> [AreaReport]) {
        makeContext = context
        scanner = scan
    }

    /// For snapshots: fixed reports, no files read.
    init(demo reports: [AreaReport]) {
        self.reports = reports
        makeContext = { SetupContext(home: URL(filePath: "/nonexistent"), claudeProfiles: [], isRunning: { _ in false }, run: { _ in nil }) }
        scanner = { _ in reports }
    }

    var attention: [(area: SetupArea, item: Attention)] {
        reports.flatMap { report in report.attention.map { (report.area, $0) } }
    }

    var changes: [SetupChange] { reports.flatMap(\.changes) }

    func report(_ area: SetupArea) -> AreaReport? { reports.first { $0.area == area } }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let context = makeContext(), scanner = self.scanner
        reports = await Task.detached { scanner(context) }.value
        history = SetupApplier(context: context).history()
    }

    /// Applies the chosen changes from the last scan, then scans again.
    func apply(_ ids: Set<String>) async {
        await applyChanges(changes.filter { ids.contains($0.id) })
    }

    func autonomyChanges(to level: DefaultsSetup.Autonomy) -> [SetupChange] {
        DefaultsSetup.autonomyChanges(makeContext(), to: level)
    }

    func applyChanges(_ chosen: [SetupChange]) async {
        guard !chosen.isEmpty, !isApplying else { return }
        isApplying = true
        let context = makeContext()
        let result = await Task.detached { SetupApplier(context: context).apply(chosen) }.value
        isApplying = false
        outcome = (result.applied.isEmpty ? [] : ["Done: \(result.applied.map(\.title).joined(separator: ", "))."])
            + result.skipped.map { "Not done: \($0.change.title), \($0.reason)." }
        await refresh()
    }

    func undo(_ id: UUID) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let context = makeContext()
        do {
            try await Task.detached { try SetupApplier(context: context).undo(id) }.value
            outcome = ["Undone."]
        } catch {
            outcome = [error.localizedDescription]
        }
        await refresh()
    }
}

extension SetupModel {
    /// What the Setup tab looks like on a Mac with a few things to fix (for `--snapshot --setup --demo`).
    static let demoReports: [AreaReport] = [
        AreaReport(area: .instructions, summary: "Claude and Codex read different instructions",
                   attention: [Attention(id: "i1", text: "Codex reads different instructions (38 lines differ)", fixes: ["instructions.link"])],
                   changes: [SetupChange(id: "instructions.link", area: .instructions, title: "Codex reads your CLAUDE.md", operations: [])],
                   items: [SetupItem(id: "a", name: "~/.claude/CLAUDE.md", claude: .same, codex: .differs, note: "61 lines")]),
        AreaReport(area: .skills, summary: "67 in Codex · 9 not in Claude",
                   changes: [SetupChange(id: "skills.link", area: .skills, title: "Claude gets 9 skills from ~/.agents/skills", operations: [])]),
        AreaReport(area: .mcp, summary: "22 in both · 6 only in Codex",
                   attention: [Attention(id: "m1", text: "playwright differs: Claude 0.0.83, Codex 0.0.79", fixes: ["mcp.claude.playwright", "mcp.codex.playwright"])],
                   changes: [SetupChange(id: "mcp.claude.playwright", area: .mcp, title: "Use Claude's playwright", operations: [], waitsFor: .chatGPT),
                             SetupChange(id: "mcp.codex.playwright", area: .mcp, title: "Use Codex's playwright", operations: [])]),
        AreaReport(area: .claudeApp, summary: "3 profiles · 1 differs"),
        AreaReport(area: .defaults, summary: "2 of 4 recommended · Autonomy mixed"),
        AreaReport(area: .importSync, summary: "Keep imports in sync is on · 34 copied skills",
                   attention: [Attention(id: "s1", text: "ChatGPT Import still copies Claude into Codex", fixes: ["import.off"])],
                   changes: [SetupChange(id: "import.off", area: .importSync, title: "Turn off ChatGPT's Keep imports in sync", operations: [], waitsFor: .chatGPT)]),
    ]
}
