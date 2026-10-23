import Darwin
import Foundation

/// Instructions: one real `~/.claude/CLAUDE.md` (Cowork skips a symlinked one) and `~/.codex/AGENTS.md` as a link
/// to it, so Claude and Codex read the same file and nothing needs syncing. Codex reads
/// `~/.codex/AGENTS.override.md` instead when that has text. `~/AGENTS.md` (ChatGPT Import writes it) is a second
/// copy Claude loads as project instructions in every folder under ~. No word inside any file is ever changed.
public enum InstructionsSetup {
    public static func scan(_ context: SetupContext) -> AreaReport {
        let claudeMD = context.url(".claude/CLAUDE.md"), codexMD = context.url(".codex/AGENTS.md")
        let override = context.url(".codex/AGENTS.override.md"), homeCopy = context.url("AGENTS.md")
        let name = { (url: URL) in tilde(url.path, home: context.home) }

        let claudeText = text(claudeMD), codexData = try? Data(contentsOf: codexMD)
        let codexText = codexData.map { String(decoding: $0, as: UTF8.self) }
        let overrideText = text(override), homeText = text(homeCopy)
        let usesOverride = hasText(overrideText)
        let codexReal = realPath(codexMD)
        let sameFile = claudeText != nil && codexReal != nil && codexReal == realPath(claudeMD)
        let codexReads = usesOverride ? overrideText : hasText(codexText) ? codexText : nil
        // The file Codex links to now, when it is another file than CLAUDE.md and ~/AGENTS.md (like ~/.agents.md).
        var oldCopy: URL?
        if case .link(let target) = FileState.of(codexMD) {
            let old = (target.hasPrefix("/") ? URL(filePath: target) : codexMD.deletingLastPathComponent().appending(path: target)).standardizedFileURL
            if case .file = FileState.of(old), let real = realPath(old), real != realPath(claudeMD), real != realPath(homeCopy) { oldCopy = old }
        }

        var attention: [Attention] = [], changes: [SetupChange] = []
        // What CLAUDE.md holds once the plan is applied; the diffs compare against it.
        var planned: String?
        // The change that points Codex at CLAUDE.md; removing what Codex reads now needs it first.
        var linkID: String?
        if let claudeText, !sameFile {
            let id = "instructions.link-codex"
            planned = claudeText
            linkID = id
            changes.append(SetupChange(id: id, area: .instructions, title: "Codex reads your CLAUDE.md", detail: detail(codexText ?? "", claudeText),
                                       operations: [.link(path: codexMD.path, target: claudeMD.path, expected: FileState.of(codexMD))]))
            if !usesOverride {
                if let codexReads {
                    let n = differingLines(codexReads, claudeText)
                    let differ = n == 1 ? "1 line differs" : "\(n) lines differ"
                    if n > 0 { attention.append(Attention(id: "instructions.codex-differs", text: "Codex reads different instructions (\(differ))", fixes: [id])) }
                } else {
                    attention.append(Attention(id: "instructions.codex-none", text: "Codex has no instructions", fixes: [id]))
                }
            }
        } else if claudeText == nil, let codexData, let codexText, hasText(codexText) {
            let id = "instructions.from-codex"
            planned = codexText
            linkID = id
            attention.append(Attention(id: "instructions.claude-none", text: "Claude has no CLAUDE.md", fixes: [id]))
            changes.append(SetupChange(id: id, area: .instructions, title: "Make Codex's instructions your CLAUDE.md",
                                       detail: "\(name(claudeMD)) gets the \(lineCount(codexText)) in \(name(codexMD)), word for word, and \(name(codexMD)) becomes a link to it.",
                                       operations: [.write(path: claudeMD.path, contents: codexData, expected: FileState.of(claudeMD)),
                                                    .link(path: codexMD.path, target: claudeMD.path, expected: FileState.of(codexMD))]))
        }

        if let claudeText, let homeText {
            let id = "instructions.remove-home-copy"
            attention.append(Attention(id: "instructions.home-copy", text: "Claude reads ~/AGENTS.md too, a second copy", fixes: [id]))
            let codexReadsIt = codexReal != nil && codexReal == realPath(homeCopy)
            changes.append(SetupChange(id: id, area: .instructions, title: "Remove the second copy ~/AGENTS.md", detail: detail(homeText, claudeText),
                                       operations: [.remove(path: homeCopy.path, expected: FileState.of(homeCopy))],
                                       requires: codexReadsIt ? linkID.map { [$0] } ?? [] : []))
        }

        // Once Codex links to CLAUDE.md, an old copy nothing else links to can go too; a change of its own so it can stay.
        if let planned, let oldCopy, let real = realPath(oldCopy), real != realPath(override) {
            changes.append(SetupChange(id: "instructions.remove-old-copy", area: .instructions, title: "Remove the old copy \(name(oldCopy))",
                                       detail: detail(text(oldCopy) ?? "", planned),
                                       operations: [.remove(path: oldCopy.path, expected: FileState.of(oldCopy))],
                                       requires: linkID.map { [$0] } ?? []))
        }

        if usesOverride {
            attention.append(Attention(id: "instructions.override", text: "Codex reads AGENTS.override.md instead"))
        }

        // Each row says, per tool, whether it reads that file and whether its lines match CLAUDE.md.
        func reads(_ text: String?, _ yes: Bool) -> SetupItem.Presence {
            guard yes, let text else { return .notShared }
            return claudeText.map { sameLines($0, text) } == true ? .same : .differs
        }
        var items: [SetupItem] = []
        if let claudeText {
            items.append(SetupItem(id: "instructions.claude-md", name: name(claudeMD), claude: .same,
                                   codex: sameFile && !usesOverride ? .same : .missing, note: note(claudeMD, claudeText, home: context.home)))
        }
        if FileState.of(codexMD) != .absent {
            items.append(SetupItem(id: "instructions.codex-md", name: name(codexMD), claude: .notShared,
                                   codex: reads(codexText, !usesOverride && hasText(codexText)), note: note(codexMD, codexText, home: context.home)))
        }
        if let overrideText {
            items.append(SetupItem(id: "instructions.codex-override", name: name(override), claude: .notShared,
                                   codex: reads(overrideText, usesOverride), note: note(override, overrideText, home: context.home)))
        }
        if let homeText {
            items.append(SetupItem(id: "instructions.home-copy", name: name(homeCopy), claude: reads(homeText, true), codex: .notShared,
                                   note: note(homeCopy, homeText, home: context.home)))
        }
        if let oldCopy {
            let oldText = text(oldCopy)
            items.append(SetupItem(id: "instructions.old-copy", name: name(oldCopy), claude: .notShared,
                                   codex: reads(oldText, !usesOverride && hasText(oldText)), note: note(oldCopy, oldText, home: context.home)))
        }

        let summary: String
        if claudeText == nil, codexReads == nil {
            summary = "No instructions yet"
        } else if let claudeText, sameFile, !usesOverride {
            summary = "One file · \(lineCount(claudeText)) · ≈\(String(format: "%.1f", Double(claudeText.count) / 4000))k tokens"
        } else if let claudeText, let codexReads, sameLines(claudeText, codexReads) {
            summary = "Claude and Codex read two copies of the same text"
        } else {
            summary = "Claude and Codex read different instructions"
        }
        return AreaReport(area: .instructions, summary: summary, attention: attention, changes: changes, items: items)
    }

    /// A short line diff from `old` to `new`: lines only in `old` start with "- ", lines only in `new` with "+ ",
    /// and `context` unchanged lines around each change with two spaces. "…" marks skipped lines between changes.
    /// At most `limit` lines, then one line saying how many more there are. Empty when the lines are the same.
    public static func lineDiff(_ old: String, _ new: String, context: Int = 2, limit: Int = 120) -> String {
        let marked = diffLines(lines(old), lines(new))
        var keep = [Bool](repeating: false, count: marked.count)
        for (i, line) in marked.enumerated() where line.mark != " " {
            for j in max(0, i - context)...min(marked.count - 1, i + context) { keep[j] = true }
        }
        var out: [String] = []
        var last: Int?
        for i in marked.indices where keep[i] {
            if let last, i > last + 1 { out.append("…") }
            out.append("\(marked[i].mark) \(marked[i].text)")
            last = i
        }
        guard out.count > limit else { return out.joined(separator: "\n") }
        return (out.prefix(limit) + ["… \(out.count - limit) more lines"]).joined(separator: "\n")
    }

    /// Both texts' lines in order, each marked " " (in both), "-" (only in `old`) or "+" (only in `new`).
    static func diffLines(_ old: [String], _ new: [String]) -> [(mark: Character, text: String)] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var marked: [(mark: Character, text: String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                marked.append(("-", old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                marked.append(("+", new[j])); j += 1
            } else {
                marked.append((" ", old[i])); i += 1; j += 1
            }
        }
        return marked
    }

    /// How many lines differ: a changed line counts once, and so does an added or a dropped one.
    static func differingLines(_ old: String, _ new: String) -> Int {
        var count = 0, minus = 0, plus = 0
        for line in diffLines(lines(old), lines(new)) + [(" ", "")] {
            switch line.mark {
            case "-": minus += 1
            case "+": plus += 1
            default: count += max(minus, plus); minus = 0; plus = 0
            }
        }
        return count
    }

    // MARK: Reading

    /// The text of a file, through links; nil when nothing readable is there.
    static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Codex skips a file that is empty or only whitespace.
    static func hasText(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func sameLines(_ a: String, _ b: String) -> Bool { lines(a) == lines(b) }

    static func lineCount(_ text: String) -> String {
        let n = lines(text).count
        return n == 1 ? "1 line" : "\(n) lines"
    }

    /// The file a path ends at, through any links; nil when nothing is there.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func tilde(_ path: String, home: URL) -> String {
        let prefix = home.path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    private static func detail(_ old: String, _ new: String) -> String {
        let diff = lineDiff(old, new)
        return diff.isEmpty ? "Same text as CLAUDE.md." : diff
    }

    private static func note(_ url: URL, _ text: String?, home: URL) -> String {
        let size = text.map(lineCount) ?? "missing"
        guard case .link(let target) = FileState.of(url) else { return size }
        return "Link to \(tilde(target, home: home)) · \(size)"
    }
}
