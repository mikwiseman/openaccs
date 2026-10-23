import Foundation
import OpenAccsCore

/// Skills: each one lives once in ~/.agents/skills, which Codex reads itself. Claude reads only ~/.claude/skills
/// (one level deep, following links), so it gets one link per skill. Codex also lists ~/.codex/skills.
/// Left alone: ~/.claude/skills/synced (Claude's per-account skills), ~/.codex/skills/.system (Codex's own), dot
/// entries, and links someone else made. The links OpenAccs makes are listed in setup-skills.json, so it can
/// later tell them apart from those.
public enum SkillsSetup {
    public static func scan(_ context: SetupContext) -> AreaReport {
        let agentsDir = context.url(".agents/skills"), claudeDir = context.url(".claude/skills"), codexDir = context.url(".codex/skills")
        let agents = entries(in: agentsDir), codex = entries(in: codexDir)
        let claude = entries(in: claudeDir).filter { $0.key != reserved }
        var changes: [SetupChange] = []

        // Every change that makes links rewrites the record. Each expects what the change before it leaves,
        // so a whole plan applies in one go, and Undo puts the record back together with the links.
        let record = context.paths.appSupport.appending(path: "setup-skills.json")
        var managed = Set((try? Data(contentsOf: record)).flatMap { try? JSON.decoder.decode(ManagedLinks.self, from: $0) }?.managedLinks ?? [])
        var recordState = FileState.of(record)
        func remember(_ links: [String]) -> FileOperation {
            managed.formUnion(links)
            let data = (try? JSON.encoder.encode(ManagedLinks(managedLinks: managed.sorted()))) ?? Data()
            let write = FileOperation.write(path: record.path, contents: data, expected: recordState)
            recordState = .file(sha256: Digest.sha256(data))
            return write
        }

        // Valid skills in ~/.agents/skills that Claude has no entry for: one link each, all in one change.
        let forClaude = agents.filter { name, entry in
            name != reserved && entry.problem == nil && FileState.of(claudeDir.appending(path: name)) == .absent
        }.keys.sorted()
        if !forClaude.isEmpty {
            changes.append(SetupChange(
                id: "skills.claude", area: .skills,
                title: forClaude.count == 1 ? "Claude gets \(forClaude[0]) from ~/.agents/skills" : "Claude gets \(forClaude.count) skills from ~/.agents/skills",
                detail: "Links in ~/.claude/skills to ~/.agents/skills: \(forClaude.joined(separator: ", "))",
                operations: forClaude.map { .link(path: claudeDir.appending(path: $0).path, target: agentsDir.appending(path: $0).path, expected: .absent) }
                    + [remember(forClaude.map { claudeDir.appending(path: $0).path })]))
        }

        // A real folder in ~/.claude/skills that Codex doesn't see moves to ~/.agents/skills and is linked back.
        let toShare = claude.filter { name, entry in
            !entry.isLink && entry.problem == nil
                && FileState.of(agentsDir.appending(path: name)) == .absent && FileState.of(codexDir.appending(path: name)) == .absent
        }.keys.sorted()
        for name in toShare {
            let from = claudeDir.appending(path: name).path, to = agentsDir.appending(path: name).path
            changes.append(SetupChange(
                id: "skills.share.\(name)", area: .skills, title: "Share \(name) with Codex",
                detail: "Moves ~/.claude/skills/\(name) to ~/.agents/skills/\(name) and links it back. Nothing inside changes.",
                operations: [.move(path: from, destination: to, expected: .folder), .link(path: from, target: to, expected: .absent), remember([from])]))
        }

        // A real folder in ~/.codex/skills with the same SKILL.md as in ~/.agents/skills makes Codex list it twice.
        // A copy that something still reads through a link stays.
        let everything = [agents, claude, codex].flatMap(\.values)
        let duplicates = codex.filter { name, copy in
            guard !copy.isLink, let skill = copy.skill, agents[name]?.skill == skill, let real = copy.real else { return false }
            return !everything.contains { $0.path != copy.path && ($0.real == real || $0.real?.hasPrefix(real + "/") == true) }
        }.keys.sorted()
        if !duplicates.isEmpty {
            changes.append(SetupChange(
                id: "skills.duplicates", area: .skills,
                title: duplicates.count == 1 ? "Remove 1 duplicate copy Codex lists twice" : "Remove \(duplicates.count) duplicate copies Codex lists twice",
                detail: "Same SKILL.md as in ~/.agents/skills; these folders in ~/.codex/skills go to Backups: \(duplicates.joined(separator: ", "))",
                operations: duplicates.map { .remove(path: codexDir.appending(path: $0).path, expected: .folder) }))
        }

        var items: [SetupItem] = [], attention: [Attention] = []
        var inBoth = 0, notInClaude = 0, onlyClaude = 0
        for name in Set(agents.keys).union(claude.keys).union(codex.keys).sorted() {
            let mine = claude[name], theirs = [agents[name], codex[name]].compactMap { $0 }
            switch (mine != nil, !theirs.isEmpty) {
            case (true, true): inBoth += 1
            case (false, true): notInClaude += 1
            case (true, false): onlyClaude += 1
            case (false, false): break
            }
            var claudeSide = presence(mine.map { [$0] } ?? [], added: forClaude.contains(name))
            var codexSide = presence(theirs, added: toShare.contains(name))
            let valid = theirs.filter { $0.problem == nil }
            if let mine, mine.problem == nil, !valid.isEmpty, !valid.contains(where: { $0.real == mine.real || $0.skill == mine.skill }) {
                claudeSide = .differs
                codexSide = .differs
                attention.append(Attention(id: "skills.differs.\(name)", text: "\(name) differs between Claude and Codex"))
            }
            let note: String?
            if let problem = ((mine.map { [$0] } ?? []) + theirs).lazy.compactMap(\.problem).first {
                note = problem
            } else if theirs.isEmpty {
                note = "only Claude"
            } else if mine == nil {
                note = forClaude.contains(name) ? nil : "only Codex"
            } else if let mine, mine.isLink, theirs.contains(where: { $0.real == mine.real }) {
                note = "linked"
            } else {
                note = nil
            }
            items.append(SetupItem(id: name, name: name, claude: claudeSide, codex: codexSide, note: note))
        }

        let summary: String
        if inBoth + notInClaude + onlyClaude == 0 {
            summary = "No skills in ~/.agents/skills, ~/.claude/skills or ~/.codex/skills"
        } else if notInClaude + onlyClaude == 0 {
            summary = "\(inBoth) · in Claude and Codex"
        } else {
            summary = ["\(inBoth + notInClaude) in Codex",
                       notInClaude > 0 ? "\(notInClaude) not in Claude" : nil,
                       onlyClaude > 0 ? "\(onlyClaude) only in Claude" : nil].compactMap { $0 }.joined(separator: " · ")
        }
        return AreaReport(area: .skills, summary: summary, attention: attention, changes: changes, items: items)
    }

    /// Claude keeps the claude.ai skills of each account in ~/.claude/skills/synced; nothing else goes there.
    static let reserved = "synced"

    /// One entry in a skills folder, read through links.
    struct Entry {
        var path: String
        var isLink: Bool
        /// The folder it resolves to; nil when a link leads nowhere.
        var real: String?
        /// SKILL.md, if there is one.
        var skill: Data?
        /// Why it is not a valid skill, or nil.
        var problem: String?
    }

    /// What sits in a skills folder, by name. Dot entries and plain files are not skills.
    static func entries(in folder: URL) -> [String: Entry] {
        let fm = FileManager.default
        var found: [String: Entry] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
            var isFolder: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isFolder)
            guard exists ? isFolder.boolValue : isLink else { continue }
            let skill = try? Data(contentsOf: url.appending(path: "SKILL.md"))
            let why: String? = if !exists { "the link leads nowhere" } else if let skill { problem(in: skill) } else { "no SKILL.md" }
            found[name] = Entry(path: url.path, isLink: isLink, real: exists ? url.resolvingSymlinksInPath().path : nil, skill: skill, problem: why)
        }
        return found
    }

    /// ● when a valid copy is there; – when only invalid ones are, or none is and none is planned.
    static func presence(_ entries: [Entry], added: Bool) -> SetupItem.Presence {
        if entries.isEmpty { return added ? .missing : .notShared }
        return entries.contains { $0.problem == nil } ? .same : .notShared
    }

    /// Why a SKILL.md breaks the Agent Skills rules both tools follow, or nil: the name (when given) is
    /// a-z, 0-9 and hyphens, at most 64 characters, and the description is at most 1024 characters.
    static func problem(in skill: Data) -> String? {
        let fields = frontmatter(String(decoding: skill, as: UTF8.self))
        if let name = fields["name"] {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            if name.isEmpty || !name.unicodeScalars.allSatisfy(allowed.contains) { return "name is not only a-z, 0-9 and hyphens" }
            if name.count > 64 { return "name is longer than 64 characters" }
        }
        if let description = fields["description"], description.count > 1024 { return "description is longer than 1024 characters" }
        return nil
    }

    /// The top-level fields of a YAML frontmatter as text: quotes dropped, and indented lines and block
    /// scalars (`>`, `|`) joined. Enough to check a name and measure a description.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---" else { return [:] }
        var fields: [String: String] = [:]
        var key: String?, parts: [String] = [], literal = false
        func finish() {
            guard let key, fields[key] == nil else { return }
            var value = parts.filter { !$0.isEmpty }.joined(separator: literal ? "\n" : " ")
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") {
                finish()
                key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                literal = value.hasPrefix("|")
                parts = value.hasPrefix("|") || value.hasPrefix(">") ? [] : [value]
            } else {
                parts.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        finish()
        return fields
    }

    /// setup-skills.json: the links in ~/.claude/skills that OpenAccs made, the only ones it may remove.
    struct ManagedLinks: Codable {
        var managedLinks: [String]
    }
}
