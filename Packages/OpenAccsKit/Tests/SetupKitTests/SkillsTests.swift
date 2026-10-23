import Foundation
import Testing
@testable import SetupKit

private extension SetupHome {
    /// A skill folder whose SKILL.md is named after the folder, or holds `text`.
    @discardableResult
    func skill(_ relative: String, _ text: String? = nil) throws -> String {
        let name = (relative as NSString).lastPathComponent
        try write("\(relative)/SKILL.md", text ?? "---\nname: \(name)\ndescription: Does \(name) things.\n---\n\nSteps.\n")
        return path(relative)
    }

    func link(_ relative: String, to target: String) throws {
        let item = url.appending(path: relative)
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: item.path, withDestinationPath: target)
    }

    /// Everything under these paths ("" is the whole home) without following links: kind, then bytes or link target.
    func snapshot(_ relatives: [String]) -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ relative: String) {
            let item = relative.isEmpty ? url : url.appending(path: relative)
            var info = stat()
            guard lstat(item.path, &info) == 0 else { return }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                result[relative] = "link → \(linkTarget(relative) ?? "?")"
            case S_IFDIR:
                result[relative] = "folder"
                for name in (try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? [] {
                    walk(relative.isEmpty ? name : "\(relative)/\(name)")
                }
            default:
                result[relative] = "file \((try? Data(contentsOf: item))?.base64EncodedString() ?? "?")"
            }
        }
        relatives.forEach(walk)
        return result
    }

    var managedLinks: [String]? {
        let legacy = URL(filePath: path("Library/Application Support/OpenAccs/setup-skills.json"))
        let directory = URL(filePath: path("Library/Application Support/OpenAccs/setup-skills"))
        let files = [legacy] + ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        let links = files.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(SkillsSetup.ManagedLinks.self, from: $0) }.flatMap(\.managedLinks)
        return links.isEmpty ? nil : Set(links).sorted()
    }

}

@Suite struct SkillsTests {
    /// Mik's setup in small: skills in all three folders, linked, copied, clashing, broken and reserved.
    func mixedHome() throws -> SetupHome {
        let home = try SetupHome()
        for name in ["alpha", "beta", "gamma", "dup"] { try home.skill(".agents/skills/\(name)") }
        try home.skill(".agents/skills/clash", "---\nname: clash\ndescription: Codex wording.\n---\n")
        try home.write(".agents/skills/broken/scripts/run.sh", "echo\n")
        try home.link(".claude/skills/gamma", to: "../../.agents/skills/gamma")
        try home.skill(".claude/skills/mine")
        try home.write(".claude/skills/mine/scripts/run.sh", "echo mine\n")
        try home.skill(".claude/skills/other")
        try home.skill(".claude/skills/clash", "---\nname: clash\ndescription: Claude wording.\n---\n")
        try home.skill(".claude/skills/synced/acct_org/pdf")
        try home.skill("plugins/ops/skills/ops-brief")
        try home.link(".claude/skills/ops-brief", to: home.path("plugins/ops/skills/ops-brief"))
        try home.skill(".codex/skills/dup")
        try home.skill(".codex/skills/solo")
        try home.skill(".codex/skills/.system/imagegen")
        try home.write("Library/Application Support/OpenAccs/setup-skills.json", "{\"managedLinks\":[\"/old/link\"]}\n")
        return home
    }

    @Test func claudeGetsEveryValidSkillFromAgentsInOneChange() throws {
        let home = try SetupHome()
        try home.skill(".agents/skills/alpha")
        try home.skill(".agents/skills/beta")
        try home.write(".agents/skills/broken/scripts/run.sh", "echo\n")
        let report = SkillsSetup.scan(home.context())

        #expect(report.changes.count == 1)
        let change = try #require(report.changes.first)
        #expect(change.title == "Claude gets 2 skills from ~/.agents/skills")
        #expect(Array(change.operations.prefix(2)) == [
            .link(path: home.path(".claude/skills/alpha"), target: home.path(".agents/skills/alpha"), expected: .absent),
            .link(path: home.path(".claude/skills/beta"), target: home.path(".agents/skills/beta"), expected: .absent),
        ])
        guard case .write(let path, let contents, _, let expected) = change.operations.last else { Issue.record("no record"); return }
        #expect(path.hasPrefix(home.path("Library/Application Support/OpenAccs/setup-skills/")) && expected == .absent)
        #expect(try JSONDecoder().decode(SkillsSetup.ManagedLinks.self, from: contents).managedLinks == [home.path(".claude/skills/alpha"), home.path(".claude/skills/beta")])
        #expect(report.items == [
            SetupItem(id: "alpha", name: "alpha", claude: .missing, codex: .same),
            SetupItem(id: "beta", name: "beta", claude: .missing, codex: .same),
            SetupItem(id: "broken", name: "broken", claude: .notShared, codex: .notShared, note: "no SKILL.md"),
        ])
        #expect(report.summary == "3 in Codex · 3 not in Claude")

        let one = try SetupHome()
        try one.skill(".agents/skills/alpha")
        #expect(SkillsSetup.scan(one.context()).changes.map(\.title) == ["Claude gets alpha from ~/.agents/skills"])
    }

    @Test func aLinkIntoAgentsIsTheSameSkill() throws {
        let home = try SetupHome()
        try home.skill(".agents/skills/alpha")
        try home.skill(".agents/skills/beta")
        try home.link(".claude/skills/alpha", to: "../../.agents/skills/alpha")
        try home.link(".claude/skills/beta", to: home.path(".agents/skills/beta"))
        let report = SkillsSetup.scan(home.context())
        #expect(report.changes.isEmpty && report.attention.isEmpty)
        #expect(report.items == [
            SetupItem(id: "alpha", name: "alpha", claude: .same, codex: .same, note: "linked"),
            SetupItem(id: "beta", name: "beta", claude: .same, codex: .same, note: "linked"),
        ])
        #expect(report.summary == "2 · in Claude and Codex")
    }

    @Test func aClaudeFolderCodexLacksMovesToAgentsAndIsLinkedBack() throws {
        let home = try SetupHome()
        try home.skill(".claude/skills/liquid-glass")
        try home.write(".claude/skills/liquid-glass/references/glass.md", "notes\n")
        let from = home.path(".claude/skills/liquid-glass"), to = home.path(".agents/skills/liquid-glass")
        let report = SkillsSetup.scan(home.context())

        #expect(report.changes.count == 1)
        let change = try #require(report.changes.first)
        #expect(change.id == "skills.share.liquid-glass" && change.title == "Share liquid-glass with Codex")
        #expect(Array(change.operations.prefix(2)) == [.move(path: from, destination: to, expected: .folder), .link(path: from, target: to, expected: .absent)])
        #expect(report.items == [SetupItem(id: "liquid-glass", name: "liquid-glass", claude: .same, codex: .missing, note: "only Claude")])
        #expect(report.summary == "0 in Codex · 1 only in Claude")

        #expect(SetupApplier(context: home.context()).apply(report.changes).applied.count == 1)
        #expect(home.linkTarget(".claude/skills/liquid-glass") == to)
        #expect(home.read(".agents/skills/liquid-glass/references/glass.md") == "notes\n")
        #expect(home.managedLinks == [from])
    }

    @Test func identicalCodexCopiesAreRemovedInOneChange() throws {
        let home = try SetupHome()
        for name in ["apple-design", "android-cli", "emil", "tbank", "renamed"] { try home.skill(".agents/skills/\(name)") }
        try home.skill(".codex/skills/apple-design")
        try home.skill(".codex/skills/android-cli")
        try home.skill(".codex/skills/emil", "---\nname: emil\ndescription: Other words.\n---\n")   // not the same text
        try home.skill(".codex/skills/tbank")                                                        // Claude reads this copy
        try home.link(".claude/skills/tbank", to: home.path(".codex/skills/tbank"))
        try home.link(".codex/skills/renamed", to: "../../.agents/skills/renamed")                   // a link someone made
        try home.skill(".codex/skills/.system/imagegen")
        let report = SkillsSetup.scan(home.context())

        let change = try #require(report.changes.first { $0.id == "skills.duplicates" })
        #expect(change.title == "Remove 2 duplicate copies Codex lists twice")
        #expect(change.operations == [
            .remove(path: home.path(".codex/skills/android-cli"), expected: .folder),
            .remove(path: home.path(".codex/skills/apple-design"), expected: .folder),
        ])
        #expect(!report.items.contains { $0.name == ".system" || $0.name == "imagegen" })
        #expect(report.attention.isEmpty)

        #expect(SetupApplier(context: home.context()).apply([change]).applied.count == 1)
        #expect(!FileManager.default.fileExists(atPath: home.path(".codex/skills/apple-design")))
        #expect(home.read(".codex/skills/emil/SKILL.md") != nil && home.read(".codex/skills/tbank/SKILL.md") != nil)
        #expect(home.linkTarget(".codex/skills/renamed") != nil && home.read(".codex/skills/.system/imagegen/SKILL.md") != nil)
        #expect(!SkillsSetup.scan(home.context()).changes.contains { $0.id == "skills.duplicates" })
    }

    @Test func differentContentsNeedYouAndChangeNothing() throws {
        let home = try SetupHome()
        try home.skill(".agents/skills/wai-school-publish", "---\nname: wai-school-publish\ndescription: Publish without Codex.\n---\n")
        try home.skill(".claude/skills/wai-school-publish", "---\nname: wai-school-publish\ndescription: Publish without Claude.\n---\n")
        try home.skill(".claude/skills/kept")
        try home.skill(".codex/skills/kept")   // Codex already has it, so there is nothing to share
        let report = SkillsSetup.scan(home.context())
        #expect(report.changes.isEmpty)
        #expect(report.attention == [Attention(id: "skills.differs.wai-school-publish", text: "wai-school-publish differs between Claude and Codex")])
        #expect(report.items == [
            SetupItem(id: "kept", name: "kept", claude: .same, codex: .same),
            SetupItem(id: "wai-school-publish", name: "wai-school-publish", claude: .differs, codex: .differs),
        ])
        #expect(report.summary == "2 · in Claude and Codex")
    }

    @Test func invalidSkillsAreListedWithWhyAndNeverShared() throws {
        let home = try SetupHome()
        try home.write(".agents/skills/screencast/scripts/caption.sh", "echo\n")
        try home.skill(".agents/skills/spaced", "---\nname: Spaced Name\ndescription: x\n---\n")
        try home.skill(".agents/skills/long", "---\nname: \(String(repeating: "a", count: 65))\ndescription: x\n---\n")
        try home.skill(".agents/skills/wordy", "---\nname: wordy\ndescription: >-\n" + String(repeating: "  word word word word word\n", count: 50) + "---\n")
        try home.skill(".agents/skills/quoted", "---\nname: \"quoted\"\ndescription: >-\n  Folded over\n  two lines.\n---\n")
        try home.skill(".agents/skills/bare", "Steps only, no frontmatter.\n")
        try home.write(".claude/skills/helper/run.sh", "echo\n")
        try home.link(".claude/skills/gone", to: home.path("nowhere/gone"))
        let report = SkillsSetup.scan(home.context())

        #expect(report.changes.map(\.title) == ["Claude gets 2 skills from ~/.agents/skills"])
        #expect(report.changes.first?.detail == "Links in ~/.claude/skills to ~/.agents/skills: bare, quoted")
        let notes = Dictionary(uniqueKeysWithValues: report.items.map { ($0.name, $0.note) })
        #expect(notes == [
            "bare": nil, "quoted": nil,
            "gone": "the link leads nowhere", "helper": "no SKILL.md", "screencast": "no SKILL.md",
            "long": "name is longer than 64 characters",
            "spaced": "name is not only a-z, 0-9 and hyphens",
            "wordy": "description is longer than 1024 characters",
        ])
        #expect(report.items.first { $0.name == "spaced" }.map { [$0.claude, $0.codex] } == [.notShared, .notShared])
        #expect(report.items.first { $0.name == "helper" }.map { [$0.claude, $0.codex] } == [.notShared, .notShared])
    }

    @Test func frontmatterReadsQuotesAndBlockScalars() {
        let fields = SkillsSetup.frontmatter("---\r\nname: 'quoted'\r\ndescription: |\r\n  one\r\n  two\r\nmetadata:\r\n  author: x\r\n---\r\nname: body\r\n")
        #expect(fields == ["name": "quoted", "description": "one\ntwo", "metadata": "author: x"])
        #expect(SkillsSetup.frontmatter("# Title\n").isEmpty)
    }

    @Test func reservedAndOtherPeoplesEntriesAreLeftAlone() throws {
        let home = try SetupHome()
        try home.skill(".claude/skills/synced/acct_org/pdf")
        try home.skill(".agents/skills/synced")      // valid, yet Claude's synced folder is not ours to fill
        try home.skill(".codex/skills/.system/imagegen")
        try home.skill(".claude/skills/.hidden")
        try home.write(".claude/skills/README.md", "notes\n")
        try home.skill("plugins/ops/skills/ops-brief")
        try home.link(".claude/skills/ops-brief", to: home.path("plugins/ops/skills/ops-brief"))
        let report = SkillsSetup.scan(home.context())
        #expect(report.changes.isEmpty)
        #expect(report.items == [
            SetupItem(id: "ops-brief", name: "ops-brief", claude: .same, codex: .notShared, note: "only Claude"),
            SetupItem(id: "synced", name: "synced", claude: .notShared, codex: .same, note: "only Codex"),
        ])
    }

    @Test func anEmptyHomeHasNothingToDo() throws {
        let report = SkillsSetup.scan(try SetupHome().context())
        #expect(report.summary == "No skills in ~/.agents/skills, ~/.claude/skills or ~/.codex/skills")
        #expect(report.changes.isEmpty && report.items.isEmpty && report.attention.isEmpty)
    }

    @Test func scanningOnlyReads() throws {
        let home = try mixedHome()
        let before = home.snapshot([""])
        _ = SkillsSetup.scan(home.context())
        #expect(home.snapshot([""]) == before)
    }

    @Test func appliesThePlanThenFindsNothingLeftAndUndoesByteForByte() throws {
        let home = try mixedHome()
        let watched = [".agents", ".claude", ".codex", "plugins", "Library/Application Support/OpenAccs/setup-skills.json"]
        let before = home.snapshot(watched)
        let report = SkillsSetup.scan(home.context())
        #expect(report.summary == "7 in Codex · 5 not in Claude · 3 only in Claude")
        #expect(report.changes.map(\.title) == [
            "Claude gets 3 skills from ~/.agents/skills", "Share mine with Codex", "Share other with Codex", "Remove 1 duplicate copy Codex lists twice",
        ])
        #expect(report.attention.map(\.text) == ["clash differs between Claude and Codex"])

        let applier = SetupApplier(context: home.context())
        let result = applier.apply(report.changes)
        #expect(result.applied.count == 4 && result.skipped.isEmpty)
        for name in ["alpha", "beta", "dup", "mine", "other"] {
            #expect(home.linkTarget(".claude/skills/\(name)") == home.path(".agents/skills/\(name)"))
        }
        #expect(home.read(".agents/skills/mine/scripts/run.sh") == "echo mine\n")
        #expect(!FileManager.default.fileExists(atPath: home.path(".codex/skills/dup")))
        #expect(home.read(".claude/skills/clash/SKILL.md")?.contains("Claude wording") == true)
        #expect(home.read(".claude/skills/synced/acct_org/pdf/SKILL.md") != nil && home.read(".codex/skills/.system/imagegen/SKILL.md") != nil)
        #expect(home.managedLinks == ["/old/link"] + ["alpha", "beta", "dup", "mine", "other"].map { home.path(".claude/skills/\($0)") })

        let again = SkillsSetup.scan(home.context())
        #expect(again.changes.isEmpty)
        #expect(again.summary == "9 in Codex · 2 not in Claude · 1 only in Claude")
        #expect(again.items.first { $0.name == "mine" }?.note == "linked")

        for entry in applier.history().reversed() { try applier.undo(entry.id) }
        #expect(home.snapshot(watched) == before)
    }

    @Test func foldersAnotherChangeRemovesCountAsGone() throws {
        let home = try SetupHome()
        try home.write(".agents/skills/kept/SKILL.md", "---\nname: kept\n---\n")
        try home.write(".agents/skills/update-cursor-settings/SKILL.md", "---\nname: update-cursor-settings\n---\n")
        try home.write(".agents/skills/apple-design/SKILL.md", "---\nname: apple-design\n---\n")
        try home.write(".codex/skills/apple-design/SKILL.md", "---\nname: apple-design\n---\n")
        let leaving: Set<String> = [home.path(".agents/skills/update-cursor-settings"), home.path(".agents/skills/apple-design")]

        let report = SkillsSetup.scan(home.context(), excluding: leaving)

        // Claude gets only the skill that stays, and Codex's own copy of apple-design is not removed as a duplicate.
        #expect(report.changes.map(\.title) == ["Claude gets kept from ~/.agents/skills"])
    }
}
