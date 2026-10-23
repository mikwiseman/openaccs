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
    /// The change's id, what it needed and the app it waited for, which its Undo respects too (nil in older History).
    public var changeID: String?
    public var requires: [String]?
    public var waitsFor: SetupApp?
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
        var done = Set<String>()
        // Resolve dependencies even when they span several areas (Import off → cleanup → shared skills).
        var pending = changes
        while !pending.isEmpty {
            let index = pending.firstIndex { change in
                change.requires.allSatisfy { dependency in !pending.contains { $0.id == dependency } }
            } ?? 0
            let change = pending.remove(at: index)
            if let missing = change.requires.first(where: { !done.contains($0) }) {
                let title = changes.first { $0.id == missing }?.title ?? missing
                result.skipped.append((change, "needs “\(title)” too"))
                continue
            }
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
                let entry = HistoryEntry(id: UUID(), date: now, area: change.area, title: change.title, undo: undo,
                                         changeID: change.id, requires: change.requires, waitsFor: change.waitsFor)
                try save(history().filter { now.timeIntervalSince($0.date) < Self.keepHistory } + [entry])
                result.applied.append(entry)
                done.insert(change.id)
            } catch {
                for operation in undo { _ = try? perform(operation, backups: backups) }
                result.skipped.append((change, error.localizedDescription))
            }
        }
        return result
    }

    /// Undoes one applied change, all or nothing, like Apply: it throws and leaves things as they are when its app
    /// is open, a later change still needs it, something changed since, a backup is gone, or a step fails.
    public func undo(_ id: UUID, now: Date = Date()) throws {
        var all = history()
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].undoneAt == nil else { throw SetupError.nothingToUndo }
        let entry = all[i]
        if let app = entry.waitsFor, context.isRunning(app) { throw SetupError.appRunning(Self.name(app)) }
        if let change = entry.changeID,
           let later = all[(i + 1)...].first(where: { $0.undoneAt == nil && $0.requires?.contains(change) == true }) {
            throw SetupError.neededBy(later.title)
        }
        guard isAsPlanned(entry.undo) else { throw SetupError.changedSince }
        for case .restore(_, let backup, _) in entry.undo where FileState.of(URL(filePath: backup)) == .absent { throw SetupError.backupGone }
        let backups = context.paths.backupsDir.appending(path: "\(Self.stamp(now)) setup undo", directoryHint: .isDirectory)
        var redo: [FileOperation] = []
        do {
            for operation in entry.undo { redo.insert(contentsOf: try perform(operation, backups: backups), at: 0) }
            all[i].undoneAt = now
            try save(all)
        } catch {
            for operation in redo { _ = try? perform(operation, backups: backups) }
            throw error
        }
    }

    // MARK: Operations

    /// Every path holds what its first operation expects (later ones on the same path expect what earlier ones leave).
    func isAsPlanned(_ operations: [FileOperation]) -> Bool {
        var seen = Set<String>()
        for operation in operations {
            switch operation {
            case .claudeMCP(let name, _, let expected):
                guard claudeHolds(name, expected) else { return false }
            case .toml(let path, let table, let key, _, let expected):
                guard seen.insert("toml:\(path):\(table + [key])").inserted else { continue }
                guard let file = readTOML(path), file.value(key, in: table) == expected else { return false }
            case .json(let path, let key, _, let expected):
                guard seen.insert("json:\(path):\(key)").inserted else { continue }
                guard let object = readJSON(path), Self.jsonText(object[key]) == expected else { return false }
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
        case .claudeMCP(let name, let value, let expected):
            guard claudeHolds(name, expected) else { throw SetupError.changedSince }
            if expected != nil {
                guard context.run(MCPSetup.removeCommand(name))?.status == 0 else { throw SetupError.commandFailed("claude mcp remove") }
            }
            if let value, context.run(["claude", "mcp", "add-json", "--scope", "user", name, value])?.status != 0 {
                if let expected { _ = context.run(["claude", "mcp", "add-json", "--scope", "user", name, expected]) }
                throw SetupError.commandFailed("claude mcp add-json")
            }
            guard claudeHolds(name, value) else {
                _ = context.run(MCPSetup.removeCommand(name))
                if let expected { _ = context.run(["claude", "mcp", "add-json", "--scope", "user", name, expected]) }
                throw SetupError.commandFailed("claude mcp verification")
            }
            return [.claudeMCP(name: name, value: expected, expected: value)]
        case .toml(let path, let table, let key, let value, let expected):
            guard var file = readTOML(path), file.value(key, in: table) == expected else { throw SetupError.changedSince }
            let edited = table == ["mcp_servers"] ? file.setServer(key, value)
                : value.map { file.set(key, $0, in: table) } ?? file.remove(key, in: table)
            guard edited else { throw SetupError.changedSince }
            let url = URL(filePath: path)
            let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? 0o600
            return try perform(.write(path: path, contents: Data(file.text.utf8), permissions: mode, expected: FileState.of(url)), backups: backups)
        case .json(let path, let key, let value, let expected):
            guard var object = readJSON(path), Self.jsonText(object[key]) == expected,
                  let new = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) else { throw SetupError.changedSince }
            object[key] = new
            guard let data = ClaudeAppSetup.serialize(object) else { throw SetupError.changedSince }
            let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? 0o600
            return try perform(.write(path: path, contents: data, permissions: mode, expected: FileState.of(URL(filePath: path))), backups: backups)
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
        case .move(let path, let destination, _):
            let to = URL(filePath: destination)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            return [.move(path: destination, destination: path, expected: FileState.of(to))]
        case .restore(let path, let backup, let expected):
            let url = URL(filePath: path)
            // Copied in next to it first, so a copy that fails leaves what is there in place.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let copy = url.deletingLastPathComponent().appending(path: ".openaccs-\(UUID().uuidString).partial")
            do { try FileManager.default.copyItem(atPath: backup, toPath: copy.path) } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            let restored = FileState.of(copy)
            var saved: String?
            do {
                if expected != .absent, FileState.of(url) != .absent { saved = try backUp(url, expected: expected, into: backups, keepOriginal: false) }
                try FileManager.default.moveItem(at: copy, to: url)
            } catch {
                if let saved { try? FileManager.default.moveItem(atPath: saved, toPath: path) }
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            return [.remove(path: path, expected: restored)] + (saved.map { [.restore(path: path, backup: $0, expected: .absent)] } ?? [])
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

    /// Whether Claude holds `entry` (JSON; nil: no server) under `name`. `claude mcp add-json` stores a stdio
    /// server without args with "args": [], so an empty args list counts as none.
    private func claudeHolds(_ name: String, _ entry: String?) -> Bool {
        guard let config = MCPSetup.readClaude(context) else { return false }
        func kept(_ entry: Any?) -> String? {
            guard var object = entry as? [String: Any] else { return entry.map { MCPSetup.json($0) } }
            if (object["args"] as? [Any])?.isEmpty == true { object["args"] = nil }
            return MCPSetup.json(object)
        }
        return kept(config.servers[name]) == entry.flatMap { kept(JSON.object(Data($0.utf8))) }
    }

    private func save(_ entries: [HistoryEntry]) throws {
        try AtomicFile.write(JSON.encoder.encode(entries), to: historyFile, permissions: 0o600)
    }

    private func readTOML(_ path: String) -> TOMLFile? {
        if FileState.of(URL(filePath: path)) == .absent { return TOMLFile(text: "") }
        return (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(TOMLFile.init(text:))
    }

    private func readJSON(_ path: String) -> [String: Any]? {
        if FileState.of(URL(filePath: path)) == .absent { return [:] }
        return (try? Data(contentsOf: URL(filePath: path))).flatMap(JSON.object)
    }

    /// A JSON value as text with sorted keys, so equal values read alike; nil when there is none.
    static func jsonText(_ value: Any?) -> String? {
        value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) }
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
    case nothingToUndo, changedSince, backupGone
    case commandFailed(String)
    /// The app (by name) that keeps the file in memory is open.
    case appRunning(String)
    /// A later change (by title) that is still applied needs this one.
    case neededBy(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToUndo: "There is nothing to undo."
        case .changedSince: "Something changed since; nothing was undone."
        case .backupGone: "Its backup is gone from Backups; nothing was undone."
        case .commandFailed(let what): "\(what) failed."
        case .appRunning(let app): "Close \(app) first; nothing was undone."
        case .neededBy(let title): "Undo “\(title)” first, it needs this; nothing was undone."
        }
    }
}
