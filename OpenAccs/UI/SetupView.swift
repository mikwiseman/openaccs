import SwiftUI
import SetupKit

/// The Setup tab: what Claude and Codex share, what needs the user, and the changes One setup would make.
/// Every sentence is what was read from the files; nothing changes until the user applies.
struct SetupView: View {
    let model: SetupModel
    @State private var reviewing: Set<String>?
    @State private var showsHistory = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("One setup").font(.system(size: 15, weight: .semibold))
                        Text("What Claude and Codex share on this Mac, read from their files.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(model.changes.isEmpty ? "Nothing to change" : "Review \(model.changes.count)…") {
                        reviewing = Self.defaultSelection(model)
                    }
                    .disabled(model.changes.isEmpty || model.isApplying)
                }
            }
            if !model.attention.isEmpty {
                Section("Needs you · \(model.attention.count)") {
                    ForEach(model.attention, id: \.item.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(entry.item.level == .broken ? Color.red : Color.orange)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(entry.item.text).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if !entry.item.fixes.isEmpty {
                                Button(entry.item.fixes.count > 1 ? "Choose…" : "Fix…") {
                                    reviewing = entry.item.fixes.count > 1 ? [] : Set(entry.item.fixes)
                                }
                            }
                        }
                    }
                }
            }
            Section("Shared") {
                ForEach([SetupArea.instructions, .skills, .mcp, .claudeApp], id: \.self) { area in
                    if let report = model.report(area) { AreaRow(report: report) }
                }
                HStack {
                    Text("Your instructions, other people's, and a wizard").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open…") {
                        NSApp.activate()
                        openWindow(id: "instructions")
                    }
                }
            }
            if let defaults = model.report(.defaults) {
                Section("Defaults") { AreaRow(report: defaults) }
            }
            if let importSync = model.report(.importSync), !importSync.attention.isEmpty || !importSync.changes.isEmpty {
                Section("ChatGPT Import") { AreaRow(report: importSync) }
            }
            if !model.outcome.isEmpty {
                Section {
                    ForEach(model.outcome, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Section {
                HStack {
                    Button("History…") { showsHistory = true }
                        .disabled(model.history.isEmpty)
                    Spacer()
                    Text("Never shared: logins, connectors, account skills.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .topTrailing) {
            if model.isScanning || model.isApplying { ProgressView().controlSize(.small).padding(10) }
        }
        .task { await model.refresh() }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            ReviewSheet(model: model, selected: reviewing ?? []) { reviewing = nil }
        }
        .sheet(isPresented: $showsHistory) { HistorySheet(model: model) { showsHistory = false } }
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
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review changes").font(.system(size: 15, weight: .semibold))
                Text("Nothing changes until you apply. Each change goes to History, where you can undo it.")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(SetupArea.allCases, id: \.self) { area in
                    let changes = model.changes.filter { $0.area == area }
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
                    let ids = selected
                    close()
                    Task { await model.apply(ids) }
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
                selected.formUnion(change.requires)
            } else {
                selected.remove(change.id)
                for other in model.changes where other.requires.contains(change.id) { selected.remove(other.id) }
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
                    Text("Applies once ChatGPT is closed.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if change.waitsFor != nil {
                    Text("Applies once that Claude window is closed.").font(.system(size: 11)).foregroundStyle(.secondary)
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
