import SwiftUI
import OpenAccsCore

/// One account: who, how much is left, when it comes back. Click opens or switches.
struct AccountRow: View {
    let row: PanelRow
    let model: any PanelModel
    let now: Date
    /// Scrolls the list so this whole row shows, with the question it just opened.
    let reveal: () -> Void
    /// Claude: the guided connect for this window's account. Others: the add flow again (expired login or key).
    let signIn: (PanelRow) -> Void

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
    /// Claude numbers are live or an exact limit hit, never old.
    private var staleNote: String? { row.provider == .claude ? nil : row.usage.flatMap { UsageText.stale($0.asOf, now: now) } }
    /// Claude without live limits: why, and the one way to get them (none while a sign-in already runs).
    private var offersConnect: Bool { row.provider == .claude && row.needsSignIn && row.signInLink == nil }

    /// Meters and captions start under the label, not under the dot.
    static let indent: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !meters.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(meters, id: \.kind) { Meter(window: $0, now: now) }
                }
                .padding(.leading, Self.indent)
                // Old numbers fade, so nobody picks an account on a guess.
                .opacity(staleNote == nil ? 1 : 0.5)
                .allowsHitTesting(false)
            }
            caption.padding(.leading, Self.indent)
            if let confirm {
                confirmation(confirm)
                    .padding(.leading, Self.indent)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The row is a button underneath its content; text lets clicks through, links keep theirs.
        .background {
            Button(action: tap) { Color.clear }
                .buttonStyle(RowButtonStyle(hovering: hovering && confirm == nil && !renaming))
                .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .onChange(of: row.state) { old, new in if old == .idle && new != .idle { pulse += 1 } }
        // Live limits arrived, from the panel or a terminal sign-in.
        .onChange(of: row.isLive) { old, new in if !old && new { pulse += 1 } }
        .onChange(of: confirm) { _, new in if new != nil { reveal() } }
        .animation(.snappy(duration: 0.22), value: confirm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, tap)
        .accessibilityActions {
            if offersConnect { Button("Connect live limits") { signIn(row) } }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 0) {
            AccountDot(color: color, filled: row.state != .idle, working: working != nil, pulse: pulse)
                .frame(width: Self.indent, alignment: .leading)
                .allowsHitTesting(false)
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
                HStack(spacing: 5) {
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
                    }
                }
                .allowsHitTesting(false)
                if row.isBest {
                    Text("✦")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .contentShape(.rect)
                        .help("Most left")
                        .onTapGesture(perform: tap)
                        .accessibilityLabel("most left")
                }
            }
            Spacer(minLength: 10)
            if let plan = row.plan {
                Chip(text: plan).allowsHitTesting(false)
            }
        }
        .frame(height: 18)
    }

    @ViewBuilder private var caption: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .captionStyle(lines: 2)
                .allowsHitTesting(false)
        } else if let working {
            HStack(spacing: 8) {
                Text(working).foregroundStyle(.secondary).allowsHitTesting(false)
                Button("Cancel") { task?.cancel() }.buttonStyle(.inlineLink)
            }
            .captionStyle()
        } else if row.needsSignIn && row.provider != .claude {
            HStack(spacing: 0) {
                Text(signedOutNote).foregroundStyle(.orange).allowsHitTesting(false)
                separator
                Button(usesKey ? "Replace key" : "Sign in") { signIn(row) }
                    .buttonStyle(.inlineLink)
            }
            .captionStyle()
        } else {
            let notes = notes
            let waiting = ControlAccount.pendingText(new: row.pendingSessions, changed: row.pendingChanges)
            // A Claude Code sign-in running for this window offers its link for a private window; without live
            // limits, the row says why and offers the one way to get them.
            let limitsLine = row.provider == .claude && (offersConnect || row.signInLink != nil)
            if limitsLine {
                HStack(spacing: 0) {
                    if let link = row.signInLink {
                        Text("Signing in to Claude Code").foregroundStyle(.secondary).allowsHitTesting(false)
                        separator
                        CopyLinkButton(link: link)
                    } else {
                        Text(row.error ?? "No live limits").foregroundStyle(.secondary).allowsHitTesting(false)
                        separator
                        Button("Connect") { signIn(row) }.buttonStyle(.inlineLink)
                    }
                }
                .captionStyle()
            }
            let error = limitsLine ? nil : row.error
            if waiting != nil || !notes.isEmpty || error != nil {
                HStack(spacing: 0) {
                    if let error {
                        Text(error).foregroundStyle(.secondary).allowsHitTesting(false)
                        if waiting != nil || !notes.isEmpty { separator }
                    }
                    if let waiting {
                        Text(waiting)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                        Text(" ").allowsHitTesting(false)
                        Button("Restart", action: restart).buttonStyle(.inlineLink)
                        if !notes.isEmpty { separator }
                    }
                    Text(notes).foregroundStyle(.secondary).allowsHitTesting(false)
                }
                .captionStyle()
            }
        }
    }

    private var usesKey: Bool { row.provider == .kimi || row.provider == .zai }

    /// Says what stopped working, so the link next to it reads as the fix. Claude rows say it in their limits line.
    private var signedOutNote: String {
        switch row.provider {
        case .kimi, .zai: row.error ?? "Key no longer works"
        case .claude, .codex, .grok: "Signed out"
        }
    }

    private var separator: some View {
        Text("  ·  ").foregroundStyle(.tertiary).allowsHitTesting(false)
    }

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
        if let staleNote { parts.append(staleNote) }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.05)))
        .contentShape(.rect)
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
            let refreshes = row.state == .running && row.pendingSessions + row.pendingChanges > 0
            run(refreshes ? "Refreshing Claude…" : row.state == .running ? "Switching…" : "Opening Claude…") { try await model.open(row.id) }
        default:
            run("Opening…") { try await model.open(row.id) }
        }
    }

    private func restart() {
        run("Restarting Claude…") { try await model.restart(row.id) }
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
            let reveal = Task {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }   // finished just as the delay ran out
                working = caption
            }
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
        if row.isBest { parts.append("most left") }
        for w in meters { parts.append("\(UsageText.spokenWindow(w)), \(UsageText.spoken(w, now: now))") }
        if row.provider == .claude, row.signInLink != nil { parts.append("Signing in to Claude Code") }
        else if offersConnect { parts.append((row.error ?? "No live limits") + ", connect") }
        else if row.needsSignIn { parts.append(signedOutNote + (usesKey ? "" : ", sign in again")) }
        else if let error = row.error { parts.append(error) }
        if let waiting = ControlAccount.pendingText(new: row.pendingSessions, changed: row.pendingChanges) { parts.append(waiting) }
        if !notes.isEmpty { parts.append(notes.replacingOccurrences(of: "  ·  ", with: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// The row's own surface: a soft fill on hover, a firmer one while pressed.
private struct RowButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.055 : 0))
            )
            .contentShape(.rect)
    }
}

private extension View {
    func captionStyle(lines: Int = 1) -> some View {
        font(.system(size: 11)).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
    }
}
