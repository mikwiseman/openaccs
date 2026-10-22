import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

@Suite struct TranscriptMigrationTests {
    let old = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every item below `dir` without following links: kind, bytes, link target and modification date.
    func snapshot(_ dir: URL) -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        func walk(_ url: URL, _ relative: String) {
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                let item = url.appending(path: name)
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                let mtime = FS.modificationDate(item)?.timeIntervalSince1970 ?? -1
                switch FS.kind(item) {
                case S_IFDIR:
                    result[path] = "dir"
                    walk(item, path)
                case S_IFLNK:
                    result[path] = "link → \((try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? "?")"
                default:
                    let bytes = (try? Data(contentsOf: item)).map { $0.base64EncodedString() } ?? "?"
                    result[path] = "file \(bytes) \(mtime)"
                }
            }
        }
        walk(dir, "")
        return result
    }

    @Test func fingerprintChangesOnlyWithTheFolder() throws {
        let home = try TempHome()
        try home.write("legacy/projects/-p/a.jsonl", "{}\n")
        try home.write("legacy/file-history/x/1", "v1")
        let dir = home.url.appending(path: "legacy", directoryHint: .isDirectory)
        let first = TranscriptMigration.fingerprint(of: dir)
        #expect(TranscriptMigration.fingerprint(of: dir) == first)
        try home.write("legacy/projects/-p/a.jsonl", "{}\n{}\n")   // a transcript grew
        let second = TranscriptMigration.fingerprint(of: dir)
        #expect(second != first)
        try home.write("legacy/file-history/x/2", "v2")             // a checkpoint appeared
        let third = TranscriptMigration.fingerprint(of: dir)
        #expect(third != second)
        // A project folder renamed: same count, size and dates, other paths.
        try FileManager.default.moveItem(at: dir.appending(path: "projects/-p"), to: dir.appending(path: "projects/-q"))
        #expect(TranscriptMigration.fingerprint(of: dir) != third)
    }

    @Test func importsLegacyHistoryIntoTheSharedFolder() throws {
        let home = try TempHome()
        let legacy = home.url.appending(path: "legacy-cli", directoryHint: .isDirectory)
        let shared = home.paths.claudeSharedConfigDir
        @discardableResult
        func inLegacy(_ relative: String, _ text: String) throws -> URL {
            let file = try home.write("legacy-cli/projects/\(relative)", text)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            return file
        }
        @discardableResult
        func inShared(_ relative: String, _ text: String) throws -> URL {
            try home.write(".claude/projects/\(relative)", text)
        }
        func sharedText(_ relative: String) -> String? {
            (try? Data(contentsOf: shared.appending(path: "projects/\(relative)"))).map { String(decoding: $0, as: UTF8.self) }
        }

        try inLegacy("-p/new.jsonl", "1\n2\n")                                          // missing → copied
        try inLegacy("-p/new/subagents/agent-a1.jsonl", "sub\n")                        // nested → copied
        try inLegacy("-p/new/tool-results/toolu_01.txt", "result")
        try inLegacy("-q/memory/notes.md", "# notes\n")
        try inLegacy("-p/same.jsonl", "same\n"); try inShared("-p/same.jsonl", "same\n")  // identical → skipped
        try inLegacy("-p/grown.jsonl", "1\n2\n3\n"); try inShared("-p/grown.jsonl", "1\n")  // shared is older → replaced
        try inLegacy("-p/shorter.jsonl", "1\n"); try inShared("-p/shorter.jsonl", "1\n2\n") // shared is newer → skipped
        try inLegacy("-p/split.jsonl", "1\nA\n"); try inShared("-p/split.jsonl", "1\nB\n")  // diverged → merged, nothing lost
        try inLegacy(".DS_Store", "finder")
        // Links in the legacy folder are never followed.
        try home.write("outside/secret.jsonl", "secret\n")
        try home.write("outside/dir/x.jsonl", "x\n")
        try FileManager.default.createSymbolicLink(at: legacy.appending(path: "projects/-p/link.jsonl"), withDestinationURL: home.url.appending(path: "outside/secret.jsonl"))
        try FileManager.default.createSymbolicLink(at: legacy.appending(path: "projects/-linked"), withDestinationURL: home.url.appending(path: "outside/dir"))
        // A linked folder in the shared side is never written through.
        try inLegacy("-r/t.jsonl", "t\n")
        try FileManager.default.createDirectory(at: home.url.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shared.appending(path: "projects/-r"), withDestinationURL: home.url.appending(path: "elsewhere"))
        let before = snapshot(legacy)

        let report = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)

        #expect(report.copied == 4)
        #expect(report.extended == 1)
        #expect(report.skipped == 2)
        #expect(report.merged == 1)
        #expect(report.conflicts == ["projects/-r/t.jsonl"])

        #expect(sharedText("-p/new.jsonl") == "1\n2\n")
        #expect(sharedText("-p/new/subagents/agent-a1.jsonl") == "sub\n")
        #expect(sharedText("-p/new/tool-results/toolu_01.txt") == "result")
        #expect(sharedText("-q/memory/notes.md") == "# notes\n")
        #expect(FS.modificationDate(shared.appending(path: "projects/-p/new.jsonl")) == old)
        #expect(FS.modificationDate(shared.appending(path: "projects/-q/memory/notes.md")) == old)
        #expect(sharedText("-p/same.jsonl") == "same\n")
        #expect(sharedText("-p/grown.jsonl") == "1\n2\n3\n")
        #expect(FS.modificationDate(shared.appending(path: "projects/-p/grown.jsonl")) == old)
        #expect(sharedText("-p/shorter.jsonl") == "1\n2\n")
        #expect(sharedText("-p/split.jsonl") == "1\nA\nB\n")  // the legacy file plus the shared-only line
        #expect(!FS.exists(shared.appending(path: "projects/-p/link.jsonl")))
        #expect(!FS.exists(shared.appending(path: "projects/-linked")))
        #expect(!FS.exists(shared.appending(path: "projects/.DS_Store")))
        #expect(home.files(under: "elsewhere").isEmpty)

        // Only the replaced and merged files were backed up, with their old bytes.
        let backups = home.files(under: "Library/Application Support/OpenAccs/Backups").sorted()
        #expect(backups.count == 2)
        let grown = try #require(backups.first { $0.hasSuffix(".claude/projects/-p/grown.jsonl") })
        #expect(grown.contains(" transcripts/"))
        #expect(try Data(contentsOf: home.paths.backupsDir.appending(path: grown)) == Data("1\n".utf8))
        let split = try #require(backups.first { $0.hasSuffix(".claude/projects/-p/split.jsonl") })
        #expect(try Data(contentsOf: home.paths.backupsDir.appending(path: split)) == Data("1\nB\n".utf8))

        // The legacy folder is exactly as it was.
        #expect(snapshot(legacy) == before)
        #expect((FileManager.default.subpaths(atPath: home.url.path) ?? []).allSatisfy { !$0.hasSuffix(".partial") && !$0.hasSuffix(".tmp") })

        // Running again changes nothing.
        let again = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)
        #expect(again.copied == 0 && again.extended == 0 && again.merged == 0)
        #expect(again.skipped == 8)
        #expect(again.conflicts == report.conflicts)
        #expect(snapshot(legacy) == before)
    }

    @Test func differingProjectMemoryIsMergedLineByLine() throws {
        let home = try TempHome()
        let legacy = home.url.appending(path: "legacy-cli", directoryHint: .isDirectory)
        let shared = home.paths.claudeSharedConfigDir
        func sharedText(_ relative: String) -> String? {
            (try? Data(contentsOf: shared.appending(path: "projects/\(relative)"))).map { String(decoding: $0, as: UTF8.self) }
        }
        try home.write("legacy-cli/projects/-q/memory/MEMORY.md", "# Memory\n\n- fact A\n- [Topic](topic.md)\n- fact B\n- fact A\n")
        try home.write(".claude/projects/-q/memory/MEMORY.md", "# Memory\n\n- fact C\n- [Topic](topic.md)")  // no final newline
        try home.write("legacy-cli/projects/-q/memory/topic.md", "b\na\n")                // same lines, other order
        try home.write(".claude/projects/-q/memory/topic.md", "a\nb\n")
        try home.write("legacy-cli/projects/-q/notes.md", "mine\n")                       // not project memory
        try home.write(".claude/projects/-q/notes.md", "theirs\n")
        try home.write("legacy-cli/projects/-q/memory/log.jsonl", "1\nA\n")               // transcripts: legacy + shared-only
        try home.write(".claude/projects/-q/memory/log.jsonl", "1\nB\n")
        let before = snapshot(legacy)

        let report = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)

        #expect(report.merged == 2)
        #expect(report.skipped == 1)
        #expect(report.conflicts == ["projects/-q/notes.md"])
        #expect(sharedText("-q/memory/MEMORY.md") == "# Memory\n\n- fact C\n- [Topic](topic.md)\n- fact A\n- fact B\n")
        #expect(sharedText("-q/memory/topic.md") == "a\nb\n")
        #expect(sharedText("-q/notes.md") == "theirs\n")
        #expect(sharedText("-q/memory/log.jsonl") == "1\nA\nB\n")
        // Both merged files were backed up before the merge.
        let backups = home.files(under: "Library/Application Support/OpenAccs/Backups")
        #expect(backups.count == 2)
        let backup = try #require(backups.first { $0.hasSuffix(".claude/projects/-q/memory/MEMORY.md") })
        #expect(try Data(contentsOf: home.paths.backupsDir.appending(path: backup)) == Data("# Memory\n\n- fact C\n- [Topic](topic.md)".utf8))
        #expect(snapshot(legacy) == before)

        // Running again finds nothing left to merge.
        let again = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)
        #expect(again.merged == 0 && again.skipped == 3)
        #expect(again.conflicts == report.conflicts)
        #expect(home.files(under: "Library/Application Support/OpenAccs/Backups").count == 2)
    }

    @Test func missingLegacyFolderIsNothingToDo() throws {
        let home = try TempHome()
        let report = try TranscriptMigration.run(from: home.url.appending(path: "nope"), to: home.paths.claudeSharedConfigDir, backups: home.paths.backupsDir)
        #expect(report == MigrationReport())
        #expect(!FS.exists(home.paths.claudeSharedConfigDir))
    }
}

@Suite struct MigrationFoldersTests {
    @Test func rewindCheckpointsAreImportedAndRepeatsSkipUnchangedFilesUnread() throws {
        let home = try TempHome()
        let legacy = home.url.appending(path: "legacy-cli", directoryHint: .isDirectory)
        let shared = home.paths.claudeSharedConfigDir
        try home.write("legacy-cli/file-history/sess-1/abc@v1", "checkpoint")
        try home.write("legacy-cli/projects/-p/t.jsonl", "1\n")

        let first = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)
        #expect(first.copied == 2)
        #expect(try String(contentsOf: shared.appending(path: "file-history/sess-1/abc@v1"), encoding: .utf8) == "checkpoint")

        // Same size and date as the legacy file: skipped without reading, even if the bytes differ
        // (proves the fast path; real copies keep the date, so equal size+date means equal content).
        let target = shared.appending(path: "projects/-p/t.jsonl")
        let date = try #require(FS.modificationDate(shared.appending(path: "projects/-p/t.jsonl")))
        try Data("X\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        #expect(FS.modificationMicros(target) == FS.modificationMicros(legacy.appending(path: "projects/-p/t.jsonl")))
        let again = try TranscriptMigration.run(from: legacy, to: shared, backups: home.paths.backupsDir)
        #expect(again.skipped == 2 && again.copied == 0 && again.merged == 0 && again.conflicts.isEmpty)
    }
}
