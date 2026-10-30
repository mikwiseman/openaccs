import SwiftUI
import SetupKit

/// One decision first; file-level choices live in Details and the review.
struct SetupView: View {
    let model: SetupModel
    @State private var reviewing: Set<String>?
    @State private var showsDetails = false
    @State private var showsHistory = false
    @State private var autonomyPlan: [SetupChange]?
    @Environment(\.openWindow) private var openWindow

    private var ready: Bool { model.changes.isEmpty && model.attention.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your setup, everywhere.")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("The same instructions, skills and tools in Claude and Codex.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach([SetupArea.instructions, .skills, .mcp], id: \.self) { area in
                    if let report = model.report(area) {
                        Button { showsDetails = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol(area))
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(area == .mcp ? "Tools" : area.title)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(report.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: report.changes.isEmpty && report.attention.isEmpty ? "checkmark" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 15)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if area != .mcp { Divider() }
                    }
                }
            }
            Spacer(minLength: 0)
            if let outcome = model.outcome.first {
                Text(outcome).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(3).help(model.outcome.joined(separator: "\n"))
            }
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 12) {
                    Button("Details…") { showsDetails = true }.buttonStyle(.glass)
                    Spacer()
                    if model.isScanning || model.isApplying {
                        ProgressView().controlSize(.small)
                    } else if ready {
                        Label("You're all set", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        Button(model.changes.isEmpty ? "Review details…" : "Review setup…") {
                            if model.changes.isEmpty { showsDetails = true } else { reviewing = Self.defaultSelection(model) }
                        }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(28)
        .task { await model.refresh() }
        .sheet(isPresented: $showsDetails) { details }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            ReviewSheet(model: model, selected: reviewing ?? []) { reviewing = nil }
        }
        .sheet(isPresented: $showsHistory) { HistorySheet(model: model) { showsHistory = false } }
        .sheet(isPresented: Binding(get: { autonomyPlan != nil }, set: { if !$0 { autonomyPlan = nil } })) {
            ReviewSheet(model: model, selected: Set((autonomyPlan ?? []).map(\.id)), planned: autonomyPlan) { autonomyPlan = nil }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Setup details").font(.headline)
                Spacer()
                Button("Done") { showsDetails = false }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Form {
                if !model.attention.isEmpty {
                    Section("Needs a decision") {
                        ForEach(model.attention, id: \.item.id) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.item.text).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if !entry.item.fixes.isEmpty {
                                    Button("Review…") {
                                        showsDetails = false
                                        reviewing = entry.item.fixes.count > 1 ? [] : model.changes.includingRequirements(Set(entry.item.fixes))
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Shared") {
                    ForEach(model.reports, id: \.area) { AreaRow(report: $0) }
                }
                Section {
                    Button("Edit instructions…") {
                        showsDetails = false
                        openWindow(id: "instructions")
                    }
                    LabeledContent("Permissions") {
                        Menu("Choose…") {
                            ForEach(DefaultsSetup.Autonomy.allCases, id: \.self) { level in
                                Button(level.rawValue.capitalized) {
                                    showsDetails = false
                                    autonomyPlan = model.autonomyChanges(to: level)
                                }
                            }
                        }
                    }
                    Button("History…") { showsDetails = false; showsHistory = true }
                        .disabled(model.history.isEmpty)
                }
            }.formStyle(.grouped)
        }
        .frame(width: 560, height: 540)
    }

    private func symbol(_ area: SetupArea) -> String {
        switch area {
        case .instructions: "text.alignleft"
        case .skills: "sparkles"
        default: "wrench.and.screwdriver"
        }
    }

    static func defaultSelection(_ model: SetupModel) -> Set<String> {
        Set(model.reports.recommendedChanges.map(\.id))
    }
}

/// One area: its sentence, and its items when opened.
private struct AreaRow: View {
    let report: AreaReport

    var body: some View {
        if report.items.isEmpty {
            row
        } else {
            DisclosureGroup {
                ForEach(report.items) { item in
                    HStack(spacing: 8) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let note = item.note {
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Mark(presence: item.claude, product: "Claude")
                        Mark(presence: item.codex, product: "Codex")
                    }
                }
            } label: { row }
        }
    }

    private var row: some View {
        LabeledContent(report.area.title) {
            Text(report.summary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// ● same · ◐ waiting · ! differs · ○ missing · – not shared
private struct Mark: View {
    let presence: SetupItem.Presence
    let product: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 14)
            .help("\(product): \(spoken)")
            .accessibilityLabel("\(product): \(spoken)")
    }

    private var symbol: String {
        switch presence {
        case .same: "●"
        case .waiting: "◐"
        case .differs: "!"
        case .missing: "○"
        case .notShared: "–"
        }
    }

    private var spoken: String {
        switch presence {
        case .same: "same"
        case .waiting: "waiting"
        case .differs: "differs"
        case .missing: "missing"
        case .notShared: "not shared"
        }
    }

    private var color: Color {
        switch presence {
        case .same: .secondary
        case .waiting, .differs: .orange
        case .missing, .notShared: Color.secondary.opacity(0.6)
        }
    }
}

/// Every change with a checkbox and what it does, then Apply.
struct ReviewSheet: View {
    let model: SetupModel
    @State var selected: Set<String>
    var planned: [SetupChange]? = nil
    let close: () -> Void

    private var changes: [SetupChange] { planned ?? model.changes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review changes").font(.system(size: 15, weight: .semibold))
                Text("Choose what to share. You can undo changes in History.")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(SetupArea.allCases, id: \.self) { area in
                    let changes = self.changes.filter { $0.area == area }
                    if !changes.isEmpty {
                        Section(area.title) {
                            ForEach(changes) { change in ChangeRow(change: change, isOn: binding(change)) }
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(selected.isEmpty ? "Apply" : "Apply \(selected.count)") {
                    let chosen = changes.filter { selected.contains($0.id) }
                    close()
                    Task { await model.applyChanges(chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    /// Picking one of several choices for the same thing unpicks the others; picking a change picks what it
    /// needs, and unpicking a change unpicks what needs it.
    private func binding(_ change: SetupChange) -> Binding<Bool> {
        Binding(get: { selected.contains(change.id) }, set: { on in
            if on {
                for entry in model.attention where entry.item.fixes.contains(change.id) { selected.subtract(entry.item.fixes) }
                selected.insert(change.id)
                selected = changes.includingRequirements(selected)
            } else {
                selected.remove(change.id)
                while let other = changes.first(where: { selected.contains($0.id) && !$0.requires.allSatisfy(selected.contains) }) {
                    selected.remove(other.id)
                }
            }
        })
    }
}

private struct ChangeRow: View {
    let change: SetupChange
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(change.title)
                if change.waitsFor == .chatGPT {
                    Text("Skipped while ChatGPT is open. Close it, then apply.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if change.waitsFor != nil {
                    Text("Skipped while that Claude window is open. Close it, then apply.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let detail = change.detail, !detail.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView(.horizontal) {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize()
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 220)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Applied changes, newest first, each with Undo.
private struct HistorySheet: View {
    let model: SetupModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History").font(.system(size: 15, weight: .semibold))
            List(model.history.reversed()) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.area.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let failed = model.failedUndo, failed.id == entry.id {
                            Text(failed.reason).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if entry.undoneAt != nil {
                        Text("Undone").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button("Undo") { Task { await model.undo(entry.id) } }
                    }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Text("Kept 90 days. Old files stay in Backups.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
