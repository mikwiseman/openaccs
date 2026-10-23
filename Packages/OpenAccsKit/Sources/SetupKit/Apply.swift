import CryptoKit
import Darwin
import Foundation
import OpenAccsCore

enum Digest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One applied change, kept in History with the operations that undo it.
public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var area: SetupArea
    public var title: String
    public var undo: [FileOperation]
    public var undoneAt: Date?
}

public struct ApplyResult: Sendable {
    public var applied: [HistoryEntry] = []
    /// Changes left alone, with why ("waits for ChatGPT to close", "changed since you reviewed it").
    public var skipped: [(change: SetupChange, reason: String)] = []
}

/// Applies planned changes: each one only if every path still holds what was planned, after backing up what
/// it replaces, and all or nothing (a failure puts back what that change did). Records History for Undo.
public struct SetupApplier: Sendable {
    public let context: SetupContext
    public static let keepHistory: TimeInterval = 90 * 86_400

    public init(context: SetupContext) { self.context = context }

    var historyFile: URL { context.paths.appSupport.appending(path: "setup-history.json") }

    public func history() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSON.decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    public func apply(_ changes: [SetupChange], now: Date = Date()) -> ApplyResult {
        var result = ApplyResult()
        let backups = context.paths.backupsDir.appending(path: "\(Self.stamp(now)) setup", directoryHint: .isDirectory)
        for change in changes {
            if let app = change.waitsFor, context.isRunning(app) {
                result.skipped.append((change, "waits for \(Self.name(app)) to close"))
                continue
            }
            guard isAsPlanned(change.operations) else {
                result.skipped.append((change, "changed since you reviewed it"))
                continue
            }
            var undo: [FileOperation] = []
            do {
                for operation in change.operations {
                    undo.insert(contentsOf: try perform(operation, backups: backups), at: 0)
                }
                result.applied.append(HistoryEntry(id: UUID(), date: now, area: change.area, title: change.title, undo: undo))
            } catch {
                for operation in undo { _ = try? perform(operation, backups: backups) }
                result.skipped.append((change, error.localizedDescription))
            }
        }
        if !result.applied.isEmpty { try? save(history().filter { now.timeIntervalSince($0.date) < Self.keepHistory } + result.applied) }
        return result
    }

    /// Undoes one applied change. Throws when something changed since, and leaves things as they are then.
    public func undo(_ id: UUID, now: Date = Date()) throws {
        var all = history()
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].undoneAt == nil else { throw SetupError.nothingToUndo }
        guard isAsPlanned(all[i].undo) else { throw SetupError.changedSince }
        let backups = context.paths.backupsDir.appending(path: "\(Self.stamp(now)) setup undo", directoryHint: .isDirectory)
        for operation in all[i].undo { _ = try perform(operation, backups: backups) }
        all[i].undoneAt = now
        try save(all)
    }

    // MARK: Operations

    /// Every path holds what its first operation expects (later ones on the same path expect what earlier ones leave).
    func isAsPlanned(_ operations: [FileOperation]) -> Bool {
        var seen = Set<String>()
        for operation in operations {
            switch operation {
            case .write(let path, _, _, let expected), .link(let path, _, let expected), .remove(let path, let expected),
                 .restore(let path, _, let expected):
                guard seen.insert(path).inserted else { continue }
                if FileState.of(URL(filePath: path)) != expected { return false }
            case .move(let path, let destination, let expected):
                if seen.insert(path).inserted, FileState.of(URL(filePath: path)) != expected { return false }
                if seen.insert(destination).inserted, FileState.of(URL(filePath: destination)) != .absent { return false }
            case .command:
                continue
            }
        }
        return true
    }

    /// Does it, returning the operations that undo it.
    func perform(_ operation: FileOperation, backups: URL) throws -> [FileOperation] {
        switch operation {
        case .write(let path, let contents, let permissions, let expected):
            let url = URL(filePath: path)
            let saved = try backUp(url, expected: expected, into: backups, keepOriginal: true)
            try AtomicFile.write(contents, to: url, permissions: mode_t(permissions))
            let now = FileState.file(sha256: Digest.sha256(contents))
            return saved.map { [.restore(path: path, backup: $0, expected: now)] } ?? [.remove(path: path, expected: now)]
        case .link(let path, let target, let expected):
            let url = URL(filePath: path)
            let saved = try backUp(url, expected: expected, into: backups, keepOriginal: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            let removeLink = FileOperation.remove(path: path, expected: .link(target: target))
            return [removeLink] + (saved.map { [.restore(path: path, backup: $0, expected: .absent)] } ?? [])
        case .remove(let path, let expected):
            guard let saved = try backUp(URL(filePath: path), expected: expected, into: backups, keepOriginal: false) else { return [] }
            return [.restore(path: path, backup: saved, expected: .absent)]
        case .move(let path, let destination, let expected):
            let to = URL(filePath: destination)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            return [.move(path: destination, destination: path, expected: FileState.of(to))]
        case .restore(let path, let backup, let expected):
            let url = URL(filePath: path)
            if expected != .absent, FileState.of(url) != .absent {
                _ = try backUp(url, expected: expected, into: backups, keepOriginal: false)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: backup, toPath: path)
            return []
        case .command(let argv, let undo):
            guard let run = context.run(argv), run.status == 0 else {
                throw SetupError.commandFailed(argv.prefix(3).joined(separator: " "))
            }
            return [.command(argv: undo, undo: argv)]
        }
    }

    /// Copies (or moves) what is at `url` into the backup folder, mirroring its path. nil when nothing is there.
    private func backUp(_ url: URL, expected: FileState, into backups: URL, keepOriginal: Bool) throws -> String? {
        guard expected != .absent else { return nil }
        let destination = backups.appending(path: String(url.standardizedFileURL.path.drop { $0 == "/" }))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var slot = destination, n = 1
        while FileManager.default.fileExists(atPath: slot.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: slot.path)) != nil {
            slot = destination.deletingLastPathComponent().appending(path: "\(destination.lastPathComponent).\(n)")
            n += 1
        }
        if keepOriginal { try FileManager.default.copyItem(at: url, to: slot) } else { try FileManager.default.moveItem(at: url, to: slot) }
        return slot.path
    }

    private func save(_ entries: [HistoryEntry]) throws {
        try AtomicFile.write(JSON.encoder.encode(entries), to: historyFile, permissions: 0o600)
    }

    static func name(_ app: SetupApp) -> String {
        switch app {
        case .chatGPT: "ChatGPT"
        case .claude(let dir): "the Claude window using \((dir as NSString).lastPathComponent)"
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }
}

public enum SetupError: LocalizedError, Equatable {
    case nothingToUndo, changedSince
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToUndo: "There is nothing to undo."
        case .changedSince: "Something changed since; nothing was undone."
        case .commandFailed(let what): "\(what) failed."
        }
    }
}
