import SwiftUI
import OpenAccsCore

/// Adds one account, inside the panel. Each provider gets a few lines of guidance and one action.
/// Also connects a Claude account's live limits, guided the same way.
struct AddAccountView: View {
    let provider: Provider
    /// Claude: the window whose account gets live limits, instead of adding an account.
    var connecting: UUID? = nil
    let model: any PanelModel
    let done: () -> Void

    @State private var label = ""
    @State private var key = ""
    @State private var region = "global"
    @State private var task: Task<Void, Never>?
    @State private var waiting: String?
    @State private var failure: String?
    @State private var browser = Browser.current
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        // The window was removed (say from the terminal) while its sign-in ran: the sign-in ends with it.
        .onChange(of: connecting.map { id in model.rows.contains { $0.id == id } }) { _, present in
            if present == false {
                task?.cancel()
                done()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button {
                task?.cancel()
                done()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -9)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back")
            Text(connecting == nil ? "Add \(provider.displayName)" : "Connect live limits")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    @ViewBuilder private var content: some View {
        if let connecting {
            connect(connecting)
        } else {
            add
        }
    }

    /// Names the account by its windows (no email is known before the first sign-in), opens Anthropic's
    /// sign-in privately when the browser can, and waits for it.
    @ViewBuilder private func connect(_ id: UUID) -> some View {
        let row = model.rows.first { $0.id == id }
        let windows = model.rows.filter { $0.provider == .claude && $0.limitsGroup != nil && $0.limitsGroup == row?.limitsGroup }.map(\.label)
        let names = Text(windowList(windows.isEmpty ? [row?.label ?? "this window"] : windows)).bold()
        let browserName = Text(browser?.name ?? "Your browser").bold()
        hints {
            Hint("person.crop.circle", Text("Sign in with the account you use in \(names). One sign-in covers every window on that account."))
            if browser?.privateFlag != nil {
                Hint("eye.slash", Text("\(browserName) opens it in a private window. Close any other private windows first, because private windows share one sign-in."))
            } else {
                Hint("safari", Text("\(browserName) opens it. If claude.ai there is signed in to another account, open the link in a private window instead."))
            }
            Hint("lock", "Claude Code keeps this sign-in itself. OpenAccs only asks it what's left.")
        }
        VStack(alignment: .leading, spacing: 10) {
            action("Sign in", waiting: "Waiting for the browser…") { try await model.connectExactLimits(id) }
            if waiting != nil, let link = row?.signInLink {
                HStack(spacing: 0) {
                    CopyLinkButton(link: link)
                    Text(" to open it in another window").foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    @ViewBuilder private var add: some View {
        switch provider {
        case .claude:
            field("Name", text: $label, prompt: "Work")
            hints {
                Hint("envelope", "In the new Claude window choose **Continue with email** and type the code.")
                Hint("exclamationmark.triangle", "Avoid Google sign-in while another Claude is open.")
                Hint("externaldrive", "Each Claude profile also downloads ~12 GB for Cowork.")
            }
            action("Open Claude", disabled: label.trimmingCharacters(in: .whitespaces).isEmpty, waiting: "Opening Claude…") {
                try await model.addClaude(label: label.trimmingCharacters(in: .whitespaces))
            }
        case .codex:
            hints {
                Hint("safari", "Sign in in the browser that opens.")
                Hint("person.crop.circle", "Pick the account you want.")
                Hint("arrow.triangle.2.circlepath", "Codex stays on its current account until you switch.")
            }
            action("Sign in with ChatGPT", waiting: "Waiting for the browser…") { try await model.addCodex() }
        case .grok:
            grok
        case .kimi:
            keyForm(
                hint: region == "china"
                    ? "Create a Kimi Code key at [kimi.com/code/console](https://www.kimi.com/code/console)."
                    : "Create a Kimi Code key at [kimi.ai/code/console](https://www.kimi.ai/code/console)."
            ) { try await model.addKimi(key: $0, region: $1) }
        case .zai:
            keyForm(
                hint: region == "china"
                    ? "Create a key at [open.bigmodel.cn](https://open.bigmodel.cn)."
                    : "Create a key at [z.ai/manage-apikey](https://z.ai/manage-apikey/apikey-list)."
            ) { try await model.addZai(key: $0, region: $1) }
        }
    }

    private var grok: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                subhead("Grok Bot app")
                Text("Reads the weekly usage Grok Bot keeps on this Mac. No sign-in.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.grokBotAccounts.isEmpty {
                    Text("Open Grok Bot and sign in first.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.grokBotAccounts, id: \.self) { account in
                        HStack {
                            Text(account)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Add") { start(nil) { try await model.addGrokBot(account: account) } }
                                .buttonStyle(.pill)
                                .disabled(waiting != nil)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    subhead("Grok CLI")
                    Chip(text: "Experimental")
                }
                Text("SuperGrok and Grok Build usage through the official grok CLI. Sign in in the browser that opens.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action("Sign in", waiting: "Waiting for the browser…") { try await model.addGrokCLI() }
            }
        }
    }

    private func keyForm(hint: LocalizedStringKey, add: @escaping @MainActor (String, String) async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                field("API key", text: $key, prompt: "Paste your key", secure: true)
                RegionPicker(region: $region)
            }
            hints { Hint("key", hint) }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            action("Add", disabled: trimmed.isEmpty, waiting: "Checking the key…") { try await add(trimmed, region) }
        }
    }

    // MARK: Pieces

    private func subhead(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5, weight: .semibold))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(title, text: text, prompt: Text(prompt).foregroundStyle(.tertiary))
                } else {
                    TextField(title, text: text, prompt: Text(prompt).foregroundStyle(.tertiary))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .labelsHidden()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
            .disabled(waiting != nil)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }
        }
    }

    private func hints(@ViewBuilder _ lines: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) { lines() }
    }

    /// The one button, or a waiting line with Cancel while it runs.
    @ViewBuilder
    private func action(_ title: String, disabled: Bool = false, waiting text: String,
                        _ work: @escaping @MainActor () async throws -> Void) -> some View {
        HStack(spacing: 10) {
            if let waiting {
                AccountDot(color: .accentColor, filled: true, working: true)
                Text(waiting)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    self.waiting = nil
                }
                .buttonStyle(.pill)
            } else {
                Spacer()
                Button(title) { start(text, work) }
                    .buttonStyle(.prominentPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
    }

    /// Runs `work`; `text` (if any) replaces the button while it runs. Success returns to the list, also when
    /// Cancel came too late to stop it.
    private func start(_ text: String?, _ work: @escaping @MainActor () async throws -> Void) {
        failure = nil
        waiting = text
        task = Task {
            do {
                try await work()
                done()
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { failure = error.localizedDescription }
            }
            if !Task.isCancelled { waiting = nil }
        }
    }
}

/// One line of guidance with a symbol.
private struct Hint: View {
    let symbol: String
    let text: Text

    init(_ symbol: String, _ text: LocalizedStringKey) {
        self.symbol = symbol
        self.text = Text(text)
    }

    /// Built from parts, so a window's name stays plain text whatever characters it has.
    init(_ symbol: String, _ text: Text) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            text
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .tint(.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Global / China, as two pills.
private struct RegionPicker: View {
    @Binding var region: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach([("global", "Global"), ("china", "China")], id: \.0) { value, name in
                Button {
                    region = value
                } label: {
                    Text(name)
                        .font(.system(size: 11.5, weight: region == value ? .semibold : .regular))
                        .foregroundStyle(region == value ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(region == value ? (scheme == .dark ? Color.white.opacity(0.16) : .white) : .clear)
                                .shadow(color: .black.opacity(region == value ? 0.12 : 0), radius: 1, y: 0.5)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(region == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Region")
    }
}
