import SwiftUI
import OpenAccsCore

/// One account: who, how much is used, when it resets. Click opens or switches.
struct AccountRow: View {
    let row: PanelRow
    let model: any PanelModel
    let now: Date
    /// Opens the add flow for this provider again (expired login or key).
    let signIn: (Provider) -> Void

    @State private var hovering = false
    @State private var confirm: Confirm?
    @State private var renaming = false
    @State private var draft = ""
    @State private var busy = false
    @State private var working: String?
    @State private var task: Task<Void, Never>?
    @State private var failure: String?
    @State private var pulse = 0
    @FocusState private var nameFocused: Bool

    enum Confirm { case switchCodex, remove }


    private var color: Color { AccountColor.color(row.color) }
    private var meters: [UsageWindow] { UsageText.meters(row.usage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if !meters.isEmpty {
                VStack(spacing: 6) {
                    ForEach(meters, id: \.kind) { Meter(window: $0, now: now) }
                }
                .padding(.leading, Self.indent)
            }
            caption.padding(.leading, Self.indent)
            if let confirm {
                confirmation(confirm)
                    .padding(.leading, Self.indent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(hovering && confirm == nil && !renaming ? 0.055 : 0))
        )
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .contextMenu { menu }
        .onChange(of: row.state) { old, new in if old == .idle && new != .idle { pulse += 1 } }
        .animation(.snappy(duration: 0.25), value: confirm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, tap)
    }

    /// Meters and captions start under the label, not under the dot.
    static let indent: CGFloat = 18

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            AccountDot(color: color, filled: row.state != .idle, working: working != nil, pulse: pulse)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onAppear { nameFocused = true }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.07)))
                    .padding(.horizontal, -6)
            } else {
                Text(row.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if namesProvider {
                    Text(row.provider.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, -4)
                }
            }
            if row.isBest {
                Text("✦")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .help("Most room left")
            }
            Spacer(minLength: 6)
            if let plan = row.plan { Chip(text: plan) }
        }
    }

    @ViewBuilder private var caption: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .captionStyle()
        } else if let working {
            HStack(spacing: 6) {
                Text(working).foregroundStyle(.secondary).captionStyle()
                Button("Cancel") { task?.cancel() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        } else if row.needsSignIn {
            HStack(spacing: 0) {
                Text(row.error ?? "Signed out").foregroundStyle(.orange)
                dot
                Button(row.provider == .kimi || row.provider == .zai ? "Replace key" : "Sign in") {
                    row.provider == .claude ? connectLimits() : signIn(row.provider)
                }
                .buttonStyle(.inlineLink)
            }
            .captionStyle()
        } else {
            let notes = notes
            if row.pendingSessions > 0 || !notes.isEmpty || row.error != nil {
                HStack(spacing: 0) {
                    if let error = row.error {
                        Text(error).foregroundStyle(.orange)
                        if row.pendingSessions > 0 || !notes.isEmpty { dot }
                    }
                    if row.pendingSessions > 0 {
                        Text(row.pendingSessions == 1 ? "1 new session " : "\(row.pendingSessions) new sessions ")
                            .foregroundStyle(.secondary)
                        Button("Restart", action: restart).buttonStyle(.inlineLink)
                        if !notes.isEmpty { dot }
                    }
                    Text(notes).foregroundStyle(.secondary)
                }
                .captionStyle()
            }
        }
    }

    private var dot: some View { Text("  ·  ").foregroundStyle(.tertiary) }

    /// Limits rows don't sit under a product heading, so a custom label also names the provider.
    private var namesProvider: Bool {
        row.provider != .claude && row.provider != .codex
            && !row.label.localizedCaseInsensitiveContains(row.provider.displayName)
    }

    /// Banked resets, credits and staleness, quiet.
    private var notes: String {
        guard let usage = row.usage else { return "" }
        var parts: [String] = []
        if let n = usage.resetsAvailable, n > 0 { parts.append(UsageText.resets(n)) }
        if let c = usage.credits { parts.append(UsageText.credits(c)) }
        if let stale = UsageText.stale(usage.asOf, now: now) { parts.append(stale) }
        return parts.joined(separator: "  ·  ")
    }

    /// What Remove really does, per provider.
    private var removalNote: String {
        switch row.provider {
        case .claude: "OpenAccs forgets it. The Claude profile and its history stay on disk."
        case .codex where row.state == .active: "OpenAccs stops showing it. Codex stays signed in."
        case .codex: "OpenAccs deletes its saved sign-in for this account. Adding it back needs a browser sign-in."
        case .grok, .kimi, .zai: "OpenAccs forgets this account and its saved key."
        }
    }

    private func confirmation(_ kind: Confirm) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind == .switchCodex ? "Restart Codex as \(row.label)?" : "Remove \(row.label)?")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind == .switchCodex ? "Codex quits and reopens on this account. Your local history stays." : removalNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { confirm = nil }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button(kind == .switchCodex ? "Restart Codex" : "Remove") {
                    confirm = nil
                    if kind == .switchCodex {
                        run("Restarting Codex…") { try await model.open(row.id) }
                    } else {
                        model.remove(row.id)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true, tint: kind == .switchCodex ? .accentColor : .red))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.05)))
    }

    @ViewBuilder private var menu: some View {
        Button("Rename") {
            draft = row.label
            renaming = true
        }
        Picker("Color", selection: Binding(get: { row.color }, set: { model.setColor(row.id, to: $0) })) {
            ForEach(AccountColor.all.indices, id: \.self) { i in
                Label { Text(AccountColor.all[i].name) } icon: { Image(nsImage: AccountColor.swatch(i)) }
                    .tag(i)
            }
        }
        .pickerStyle(.menu)
        if row.canConnectLimits {
            Button("Connect Exact Limits…", action: connectLimits)
        }
        if row.hasFolder {
            Button("Show Data Folder") { model.revealFolder(row.id) }
        }
        Divider()
        Button("Remove…", role: .destructive) { confirm = .remove }
    }

    // MARK: Actions

    private func tap() {
        guard confirm == nil, !renaming, !busy else { return }
        failure = nil
        switch row.provider {
        case .codex where row.state != .active:
            confirm = .switchCodex
        case .claude:
            run(row.state == .running ? "Switching…" : "Opening Claude…") { try await model.open(row.id) }
        default:
            run("Opening…") { try await model.open(row.id) }
        }
    }

    private func restart() {
        run("Restarting Claude…") { try await model.restart(row.id) }
    }

    private func connectLimits() {
        run("Sign in to Claude Code in your browser…") { try await model.connectExactLimits(row.id) }
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != row.label { model.rename(row.id, to: name) }
        renaming = false
    }

    /// Runs an action; shows `caption` only if it takes long enough to notice, pulses on success.
    private func run(_ caption: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        failure = nil
        busy = true
        task = Task {
            let reveal = Task { try await Task.sleep(for: .milliseconds(250)); working = caption }
            do {
                try await action()
                pulse += 1
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            reveal.cancel()
            working = nil
            busy = false
        }
    }

    private var spokenSummary: String {
        var parts = [row.label, row.provider.displayName]
        if let plan = row.plan { parts.append(plan) }
        parts.append(row.state == .running ? "open" : row.state == .active ? "active" : "not open")
        for w in meters {
            parts.append("\(UsageText.spokenWindow(w)) \(UsageText.percent(w.usedPercent)) used, \(UsageText.spokenReset(w.resetsAt, now: now))")
        }
        if row.isBest { parts.append("most room left") }
        if row.needsSignIn { parts.append(row.error ?? "sign in again") }
        if row.pendingSessions > 0 { parts.append("\(row.pendingSessions) new sessions") }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    func captionStyle() -> some View {
        font(.system(size: 11)).lineLimit(1)
    }
}
