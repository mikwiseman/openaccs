import Darwin
import Foundation
import OpenAccsCore

public struct MigrationReport: Sendable, Hashable {
    /// Missing in the shared folder; copied.
    public var copied = 0
    /// The shared copy was an older, shorter version of the same file; replaced after a backup.
    public var extended = 0
    /// Already there: identical, or the shared copy is the longer one.
    public var skipped = 0
    /// Two copies that grew apart, combined without losing a line (after a backup): project memory
    /// (`*/memory/*.md`, legacy lines appended) and transcripts (`*.jsonl`: the legacy file plus the lines
    /// only the shared copy has; Claude follows each entry's parent link, so every branch survives).
    public var merged = 0
    /// Paths (relative to the config folder) whose two copies differ; both left as they are.
    public var conflicts: [String] = []
}

/// Imports an adopted profile's Claude Code history into the shared `~/.claude`: every regular file under
/// `projects/` (transcripts, subagents, tool results, project memory) and `file-history/` (rewind
/// checkpoints). Keeps modification dates, never follows links, never changes or deletes anything in the
/// legacy folder. Idempotent and cheap to repeat: files with the same size and date are skipped unread.
public enum TranscriptMigration {
    static let folders = ["projects", "file-history"]

    public static func run(from legacyConfigDir: URL, to sharedConfigDir: URL, backups: URL) throws -> MigrationReport {
        let backup = Backups(base: backups, label: "transcripts")
        var report = MigrationReport()
        for folder in folders {
            let source = legacyConfigDir.appending(path: folder, directoryHint: .isDirectory)
            for relative in regularFiles(under: source) where !relative.hasSuffix(".DS_Store") {
                try migrate("\(folder)/\(relative)", from: legacyConfigDir, to: sharedConfigDir, backup: backup, report: &report)
            }
        }
        return report
    }

    private static func migrate(
        _ relative: String, from source: URL, to target: URL, backup: Backups, report: inout MigrationReport
    ) throws {
        let from = source.appending(path: relative)
        let to = target.appending(path: relative)
        guard FS.noLinks(below: target, to: to.deletingLastPathComponent()) else {
            report.conflicts.append(relative)
            return
        }
        let date = FS.modificationDate(from)
        // Copies keep the legacy date to the microsecond, so the same size and the same microsecond = done.
        // (Two separately written files practically never share a microsecond.)
        if FS.isRegularFile(to), FS.size(to) == FS.size(from), let a = FS.modificationMicros(from), a == FS.modificationMicros(to) {
            report.skipped += 1
            return
        }
        let data = try Data(contentsOf: from, options: .mappedIfSafe)
        switch FS.kind(to) {
        case nil:
            try FS.makeDirectory(to.deletingLastPathComponent())
            guard try AtomicFile.createExclusively(data, at: to) else {
                report.conflicts.append(relative)
                return
            }
            try keepDate(date, of: to)
            report.copied += 1
        case S_IFREG:
            let existing = try Data(contentsOf: to, options: .mappedIfSafe)
            if existing == data || (data.count < existing.count && existing.prefix(data.count) == data) {
                report.skipped += 1
            } else if existing.count < data.count && data.prefix(existing.count) == existing {
                try backup.copy(to)
                try AtomicFile.write(data, to: to)
                try keepDate(date, of: to)
                report.extended += 1
            } else if isProjectMemory(relative) || relative.hasSuffix(".jsonl") {
                // Memory: shared notes plus the legacy ones. Transcript: the legacy file plus shared-only lines.
                let merged = relative.hasSuffix(".jsonl") ? merge(existing, into: data) : merge(data, into: existing)
                if merged == existing {
                    report.skipped += 1
                } else {
                    try backup.copy(to)
                    try AtomicFile.write(merged, to: to)
                    report.merged += 1
                }
            } else {
                report.conflicts.append(relative)
            }
        default:
            report.conflicts.append(relative)
        }
    }

    /// `*/memory/*.md`: a project's memory notes, which are safe to merge line by line.
    static func isProjectMemory(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        return parts.count >= 3 && parts[parts.count - 2] == "memory" && relative.hasSuffix(".md")
    }

    /// `shared` plus each line of `legacy` it lacks, in legacy order, after a newline if it needs one.
    static func merge(_ legacy: Data, into shared: Data) -> Data {
        func lines(_ data: Data) -> [Data] {
            var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
            if parts.last?.isEmpty == true { parts.removeLast() }
            return parts
        }
        var seen = Set(lines(shared))
        var result = shared
        for line in lines(legacy) where seen.insert(line).inserted {
            if let last = result.last, last != 0x0A { result.append(0x0A) }
            result.append(line)
            result.append(0x0A)
        }
        return result
    }

    private static func keepDate(_ date: Date?, of url: URL) throws {
        guard let date else { return }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Regular files below `dir` (relative paths), without entering symlinked folders.
    /// Changes whenever a file under `projects/` or `file-history/` is added, removed, renamed, resized or
    /// touched (FNV-1a over every path, size and date): an old folder with the same fingerprint as at its
    /// last import has nothing new to import.
    public static func fingerprint(of legacyConfigDir: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        var count = 0
        for folder in folders {
            let root = legacyConfigDir.appending(path: folder, directoryHint: .isDirectory)
            for relative in regularFiles(under: root) {
                let file = root.appending(path: relative)
                count += 1
                for byte in "\(folder)/\(relative)|\(FS.size(file) ?? 0)|\(FS.modificationMicros(file) ?? 0)\n".utf8 {
                    hash = (hash ^ UInt64(byte)) &* 0x100000001b3
                }
            }
        }
        return "\(count):\(String(hash, radix: 16))"
    }

    static func regularFiles(under dir: URL) -> [String] {
        var result: [String] = []
        for name in (FS.names(in: dir) ?? []).sorted() {
            let item = dir.appending(path: name)
            if FS.isRegularFile(item) {
                result.append(name)
            } else if FS.isDirectory(item) {
                result += regularFiles(under: item).map { "\(name)/\($0)" }
            }
        }
        return result
    }
}
