import SwiftUI
import SetupKit

/// Your instructions, and the files other people publish: read them, adopt rules from them, or write yours.
struct InstructionsView: View {
    @State var model: InstructionsModel
    @State private var selection: String? = "yours"
    @State private var writing = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Yours") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your instructions")
                        Text(model.saved.isEmpty ? "None yet" : InstructionsModel.measure(model.saved))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .tag("yours")
                }
                Section("Gallery") {
                    if model.feedFailed {
                        Button("Couldn't load. Try again") { Task { await model.loadFeed() } }
                    }
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.author).lineLimit(1)
                            Text("\(entry.kind == "personal" ? "Personal" : "Project") · \(entry.license ?? "no license")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { writing = true } label: { Label("Write mine…", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if selection == "yours" || selection == nil {
                YoursView(model: model)
            } else if let entry = model.entries.first(where: { $0.id == selection }) {
                EntryView(model: model, entry: entry)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            model.load()
            await model.loadFeed()
        }
        .sheet(isPresented: $writing) { WizardView(model: model) { writing = false } }
        .sheet(isPresented: Binding(get: { model.proposal != nil }, set: { if !$0 { model.proposal = nil } })) {
            ProposalView(model: model)
        }
    }
}

/// The one file, editable. Saving goes through Setup, so it can be undone from History.
private struct YoursView: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.draft)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(InstructionsModel.measure(model.draft)) · Claude and Codex read this")
                    let one = InstructionsModel.oneProductLines(model.draft)
                    if one > 0 {
                        Text("\(one) line\(one == 1 ? "" : "s") name only Claude or only Codex.")
                            .foregroundStyle(.orange)
                    } else if let message = model.message {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.load() }.disabled(!model.isEdited)
                Button("Save") { model.save(model.draft) }
                    .keyboardShortcut("s")
                    .disabled(!model.isEdited)
            }
            .padding(12)
        }
        .navigationTitle("Your instructions")
    }
}

/// Someone else's file as rules to tick, with what its license allows.
private struct EntryView: View {
    let model: InstructionsModel
    let entry: InstructionsModel.Entry
    @State private var picked: Set<Int> = []

    var body: some View {
        let text = model.texts[entry.id]
        let rules = text.map(InstructionsModel.rules) ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.system(size: 17, weight: .semibold))
                Text(entry.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(entry.author)
                    Text("·")
                    Text(entry.license ?? "No license given")
                    if let text {
                        Text("·")
                        Text(InstructionsModel.measure(text))
                    }
                    Spacer()
                    Link("Open on GitHub", destination: entry.source)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if text == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rules.indices, id: \.self) { i in
                    if entry.adopt == .read {
                        Text(rules[i]).textSelection(.enabled)
                    } else {
                        Toggle(isOn: Binding(get: { picked.contains(i) }, set: { on in if on { picked.insert(i) } else { picked.remove(i) } })) {
                            Text(rules[i]).fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Divider()
            HStack {
                switch entry.adopt {
                case .read:
                    Text("No license given: read only.").font(.system(size: 11)).foregroundStyle(.secondary)
                case .use, .rules:
                    Text("Adopt merges the rules into your file with your Claude Code, in your words.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.merging { ProgressView().controlSize(.small) }
                if entry.adopt == .use, let text {
                    Button("Use this file") { model.proposal = text }
                }
                if entry.adopt != .read {
                    Button(picked.isEmpty ? "Adopt" : "Adopt \(picked.count) rule\(picked.count == 1 ? "" : "s")") {
                        let chosen = picked.sorted().map { rules[$0] }
                        Task { await model.adopt(chosen, from: entry.author) }
                    }
                    .disabled(picked.isEmpty || model.merging)
                }
            }
            .padding(12)
        }
        .task(id: entry.id) {
            picked = []
            await model.text(of: entry)
        }
        .navigationTitle(entry.author)
    }
}

/// What saving would change, before it does.
private struct ProposalView: View {
    @Bindable var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your instructions after this").font(.system(size: 15, weight: .semibold))
            if let proposal = model.proposal {
                Text(InstructionsModel.measure(proposal)).font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(InstructionsSetup.lineDiff(model.draft, proposal, context: 2, limit: 400)
                            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("+ ") ? Color.green : line.hasPrefix("- ") ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            }
            HStack {
                Button("Cancel") { model.proposal = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if let p = model.proposal { model.save(p) } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }
}

/// Six questions, each answer a fixed sentence: a short file, instantly, with no model in the loop.
struct WizardView: View {
    let model: InstructionsModel
    let close: () -> Void
    @State private var name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    @State private var builds: Set<String> = []
    @State private var stack = ""
    @State private var talk: Set<String> = ["short"]
    @State private var language = ""
    @State private var work: Set<String> = ["smallest", "simplest"]
    @State private var proof: Set<String> = ["run"]
    @State private var never: Set<String> = ["git", "invent"]

    static let buildChoices = [("mac", "Mac and iPhone apps"), ("web", "web apps"), ("backend", "backend services"),
                               ("data", "data and ML"), ("tools", "scripts and tools")]
    static let talkChoices = [("short", "Short, answer first"), ("thorough", "Thorough")]
    static let workChoices = [("smallest", "Smallest change"), ("simplest", "Simplest thing first"),
                              ("pushback", "Push back once"), ("ask", "Ask before big changes")]
    static let proofChoices = [("tests", "Tests"), ("run", "Run it and look"), ("screenshot", "Screenshot the UI")]
    static let neverChoices = [("git", "Destructive git"), ("commit", "Commit unless asked"), ("deps", "New dependencies"),
                               ("shims", "Compatibility shims"), ("invent", "Invented facts"), ("dashes", "Em dashes")]

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("You") {
                    TextField("Your name", text: $name)
                    TextField("Reply in (language)", text: $language, prompt: Text("Any language"))
                }
                Section("You build") {
                    chips(Self.buildChoices, $builds)
                    TextField("Your stack", text: $stack, prompt: Text("Swift, TypeScript, Postgres…"))
                }
                Section("How they talk") { chips(Self.talkChoices, $talk) }
                Section("How they work") { chips(Self.workChoices, $work) }
                Section("Proof of done") { chips(Self.proofChoices, $proof) }
                Section("Never") { chips(Self.neverChoices, $never) }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview").font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(result).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("\(InstructionsModel.measure(result)). Short files work better: in one study, long ones lowered success and raised cost.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(model.saved.isEmpty ? "Use this" : "Merge into mine…") {
                        if model.saved.isEmpty {
                            model.proposal = result
                        } else {
                            let rules = InstructionsModel.rules(in: result)
                            Task { await model.adopt(rules, from: "the wizard") }
                        }
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 820, height: 600)
    }

    private func chips(_ choices: [(String, String)], _ picked: Binding<Set<String>>) -> some View {
        FlowChips(choices: choices, picked: picked)
    }

    /// The file: one fixed sentence per answer.
    var result: String {
        var lines = ["# How I work", ""]
        if !name.isEmpty { lines.append("I'm \(name). Call me \(name).") }
        let built = Self.buildChoices.filter { builds.contains($0.0) }.map(\.1)
        if !built.isEmpty || !stack.isEmpty {
            lines.append("I build \(built.isEmpty ? "software" : built.joined(separator: ", "))\(stack.isEmpty ? "" : " with \(stack)").")
        }
        lines += ["", "## Talking to me"]
        if talk.contains("short") { lines.append("- Lead with the answer. Keep replies short and cut what I wouldn't miss.") }
        if talk.contains("thorough") { lines.append("- Explain your reasoning in full when a decision matters.") }
        if !language.isEmpty { lines.append("- Reply in \(language).") }
        lines += ["", "## Working"]
        if work.contains("smallest") { lines.append("- Make the smallest change that fully solves the task. Touch only what it needs.") }
        if work.contains("simplest") { lines.append("- Start with the simplest solution that works. Add complexity only for a clear, proven benefit.") }
        if work.contains("pushback") { lines.append("- If you disagree, say why once, with evidence. If I still want my way, do it my way.") }
        if work.contains("ask") { lines.append("- Ask before large refactors, new architecture or anything hard to undo.") }
        if proof.contains("tests") { lines.append("- For a behavior change, write the failing test first, then make it pass.") }
        if proof.contains("run") { lines.append("- Run what you built and check it works before you say it's done.") }
        if proof.contains("screenshot") { lines.append("- For UI, look at a screenshot of the real screen before you say it's done.") }
        let nevers: [String: String] = [
            "git": "Never run destructive git commands (reset --hard, push --force, clean) unless I ask.",
            "commit": "Don't commit or push unless I ask.",
            "deps": "Don't add dependencies without asking.",
            "shims": "No backward-compatibility shims or fallbacks unless I ask.",
            "invent": "Never invent facts, APIs or numbers. Say when you don't know.",
            "dashes": "Don't use em dashes.",
        ]
        let chosen = Self.neverChoices.map(\.0).filter(never.contains).compactMap { nevers[$0] }
        if !chosen.isEmpty { lines += ["", "## Never"] + chosen.map { "- \($0)" } }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Toggle chips that wrap.
private struct FlowChips: View {
    let choices: [(String, String)]
    @Binding var picked: Set<String>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(choices, id: \.0) { id, label in
                Toggle(label, isOn: Binding(get: { picked.contains(id) }, set: { on in if on { picked.insert(id) } else { picked.remove(id) } }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
