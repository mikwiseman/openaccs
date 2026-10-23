import Foundation
import Observation
import OpenAccsCore
import SetupKit

/// The Instructions window's state: your one instructions file (~/.claude/CLAUDE.md, which Codex reads through
/// its link), the gallery of files other people publish, and merging rules into yours with your own Claude Code.
@MainActor @Observable
final class InstructionsModel {
    struct Entry: Codable, Hashable, Identifiable {
        enum Adopt: String, Codable { case use, rules, read }
        var id: String
        var author: String
        var title: String
        var kind: String
        var raw: URL
        var source: URL
        var license: String?
        var adopt: Adopt
        var note: String
    }

    static let feedURL = URL(string: "https://mikwiseman.github.io/openaccs/agents-feed.json")!

    private(set) var saved = ""
    var draft = ""
    private(set) var entries: [Entry] = []
    private(set) var texts: [String: String] = [:]
    private(set) var feedFailed = false
    private(set) var merging = false
    /// A merge waiting for the user to look at it: the file it would save. A new one starts with no old message.
    var proposal: String? { didSet { if proposal != nil, oldValue == nil { message = nil } } }
    private(set) var message: String?

    @ObservationIgnored private let makeContext: @MainActor () -> SetupContext

    init(context: @escaping @MainActor () -> SetupContext) {
        makeContext = context
    }

    var file: URL { makeContext().home.appending(path: ".claude/CLAUDE.md") }
    var isEdited: Bool { draft != saved }

    func load() {
        saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        draft = saved
        message = nil
    }

    /// The gallery, from the feed next to the update feed (so it can grow without a new version).
    func loadFeed() async {
        struct Feed: Decodable { var entries: [Entry] }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.feedURL)
            entries = try JSONDecoder().decode(Feed.self, from: data).entries
            feedFailed = false
        } catch {
            feedFailed = true
        }
    }

    /// The entry's file as published now (fetched only while the window is open).
    func text(of entry: Entry) async {
        guard texts[entry.id] == nil, entry.raw.host == "raw.githubusercontent.com" else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: entry.raw),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        texts[entry.id] = String(decoding: data, as: UTF8.self)
    }

    /// Saves through Setup's apply, so it lands in History with Undo, and only if nobody changed the file since.
    func save(_ text: String) {
        let context = makeContext()
        let result = SetupApplier(context: context).apply([InstructionsSetup.edit(context, from: saved, to: text)])
        if let skipped = result.skipped.first {
            message = "Not saved: \(skipped.reason.trimmingCharacters(in: CharacterSet(charactersIn: ".")))."
        } else {
            message = nil
            saved = text
            draft = text
            proposal = nil
        }
    }

    /// Asks the user's own Claude Code to merge the rules into their file: their voice and headings kept, rules
    /// already covered dropped, nothing else added. The result is shown as a diff before anything is saved.
    func adopt(_ rules: [String], from author: String) async {
        guard !rules.isEmpty, !merging else { return }
        merging = true
        message = nil
        defer { merging = false }
        let mine = draft.isEmpty ? saved : draft
        let prompt = """
        Merge these rules into this instructions file for coding agents. Keep the owner's voice, wording and \
        headings. Drop rules the file already covers. Adapt rules written for someone else (their name, their \
        machines, their projects) to be general, or drop them. Add nothing else. Output only the complete file, \
        with no preamble and no code fence.

        <file>
        \(mine)
        </file>

        <rules from="\(author)">
        \(rules.joined(separator: "\n\n"))
        </rules>
        """
        let context = makeContext()
        let result = await Task.detached {
            context.run(["claude", "-p", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                         "--setting-sources", "", "--disable-slash-commands", prompt])
        }.value
        guard let result, result.status == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = switch result?.status {
            case nil: "Adopting needs Claude Code (~/.local/bin/claude)."
            case -1: "Claude Code took over three minutes, so it was stopped. Nothing changed."
            default: "Claude Code couldn't merge them. Nothing changed."
            }
            return
        }
        proposal = result.output.hasSuffix("\n") ? result.output : result.output + "\n"
    }

    // MARK: Text

    /// "61 lines · ≈1.4k tokens" (a token is about four characters).
    static func measure(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        let tokens = Double(text.count) / 4
        let size = tokens < 1000 ? "\(Int(tokens.rounded())) tokens" : String(format: "%.1fk tokens", tokens / 1000)
        return "\(max(lines, 0)) lines · ≈\(size)"
    }

    /// Both Claude and Codex read the file: lines that name only one of them may not fit the other.
    static func oneProductLines(_ text: String) -> Int {
        text.split(separator: "\n").filter { line in
            let l = line.lowercased()
            return l.contains("claude") != l.contains("codex")
        }.count
    }

    /// A file as rules to pick: each bullet (with its continuation lines) and each paragraph is one rule;
    /// headings and code stay out.
    static func rules(in text: String) -> [String] {
        var rules: [String] = [], current: [String] = [], inCode = false
        func flush() {
            let rule = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rule.isEmpty { rules.append(rule) }
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                flush()
                continue
            }
            if inCode { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") {
                flush()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.first?.isNumber == true && trimmed.contains(". ") {
                flush()
                current.append(trimmed)
            } else {
                current.append(trimmed)
            }
        }
        flush()
        return rules
    }
}
