import Foundation
import OpenAccsCore

/// One change to a Code-tab card folder.
public struct SyncOperation: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A new card for a session the profile lacks (exclusive create; fine while it runs).
        case create
        /// A stopped profile's older card gets the newest title and activity time.
        case update
        /// An OpenAccs-made copy of a deleted session moves to Backups (stopped profiles only).
        case remove
    }

    public var kind: Kind
    /// The profile's data folder.
    public var dataDir: URL
    public var file: URL
    public var cliSessionId: String
    /// Bytes to write (create, update).
    var contents: Data?
    /// The card as planned; apply skips the change if the file changed since (update, remove).
    var expected: Data?
}

public struct SyncPlan: Sendable, Hashable {
    public var operations: [SyncOperation]
    /// Deleted sessions noticed while planning; apply remembers them so they are never recreated.
    public var tombstones: [String]

    public var isEmpty: Bool { operations.isEmpty && tombstones.isEmpty }

    /// Number of operations of one kind, optionally for one profile ("3 new sessions").
    public func count(_ kind: SyncOperation.Kind, for dataDir: URL? = nil) -> Int {
        let path = dataDir?.standardizedFileURL.path
        return operations.filter { $0.kind == kind && (path == nil || $0.dataDir.standardizedFileURL.path == path) }.count
    }
}

public struct SyncReport: Sendable, Hashable {
    public var created = 0
    public var updated = 0
    public var removed = 0
    /// Changes left out because the file changed since planning or the profile may be running.
    public var skipped = 0
    public var failures: [String] = []
}

/// Keeps every profile's Code-tab session list complete over the shared `~/.claude` transcripts.
/// Cards are copied through an allow-list (never account-bound fields), created exclusively,
/// edited only in stopped profiles after a backup, and never deleted (moved to Backups).
public struct CardSync: Sendable {
    public let paths: Paths
    let claude: ClaudeProfiles

    public init(paths: Paths) {
        self.init(claude: ClaudeProfiles(paths: paths))
    }

    init(claude: ClaudeProfiles) {
        self.paths = claude.paths
        self.claude = claude
    }

    /// Card fields that are safe to carry to another account.
    static let copiedFields = [
        "sessionId", "cliSessionId", "cwd", "originCwd", "title", "titleSource", "createdAt", "lastActivityAt",
        "isArchived", "model", "effort", "permissionMode", "completedTurns",
    ]
    static let refreshedFields = ["title", "titleSource", "lastActivityAt"]
    /// Titles someone chose: a rename in the app ("user") or through Claude's rename tool ("tool").
    /// Claude itself never lets an "auto" title replace these.
    static let chosenTitleSources: Set<String> = ["user", "tool"]

    /// What a sync would do now. Reads only; `running` = data folders of running profiles.
    public func plan(profiles: [ClaudeProfile], running: Set<URL>) throws -> SyncPlan {
        let scan = try Scan(profiles: profiles, paths: paths)
        let runningPaths = Set(running.map(\.standardizedFileURL.path))
        let madeByUs = Set(scan.state.created.map(\.file))
        var operations: [SyncOperation] = []
        for folder in scan.folders {
            let dataDir = folder.profile.dataDir
            var names = folder.names
            for id in scan.universe.keys.sorted() where !folder.claims.contains(id) {
                guard let source = scan.universe[id], let (name, data) = Self.newCard(from: source, avoiding: &names) else { continue }
                operations.append(SyncOperation(kind: .create, dataDir: dataDir, file: folder.dir.appending(path: name), cliSessionId: id, contents: data))
            }
            guard !runningPaths.contains(dataDir.standardizedFileURL.path) else { continue }
            for card in folder.cards {
                guard let id = card.cliSessionId else { continue }
                if scan.deleted.contains(id) {
                    guard madeByUs.contains(card.file.path) else { continue }
                    operations.append(SyncOperation(kind: .remove, dataDir: dataDir, file: card.file, cliSessionId: id, expected: card.raw))
                } else if let fresh = scan.universe[id], fresh.lastActivityAt > card.lastActivityAt,
                          let data = Self.refreshed(card, from: fresh) {
                    operations.append(SyncOperation(kind: .update, dataDir: dataDir, file: card.file, cliSessionId: id, contents: data, expected: card.raw))
                }
            }
        }
        return SyncPlan(operations: operations, tombstones: scan.noticedDeletions.sorted())
    }

    /// Carries out a plan. Re-checks every edit against the disk and the running apps first.
    public func apply(_ plan: SyncPlan) throws -> SyncReport {
        var state = try SyncState.load(paths.syncStateFile)
        let running = claude.runningByPath()
        let backups = Backups(base: paths.backupsDir, label: "card-sync")
        var report = SyncReport()
        var changed = false
        for op in plan.operations {
            do {
                switch op.kind {
                case .create:
                    let dir = op.file.deletingLastPathComponent()
                    guard let contents = op.contents, FS.noLinks(below: op.dataDir, to: dir) else {
                        report.skipped += 1
                        continue
                    }
                    if !FS.exists(dir) { try FS.makeDirectory(dir) }
                    guard try AtomicFile.createExclusively(contents, at: op.file) else {
                        report.skipped += 1
                        continue
                    }
                    state.created.append(SyncState.Created(file: op.file.path, cliSessionId: op.cliSessionId, createdAt: Date()))
                    report.created += 1
                    changed = true
                case .update, .remove:
                    guard let running, running[op.dataDir.standardizedFileURL.path] == nil,
                          FS.noLinks(below: op.dataDir, to: op.file.deletingLastPathComponent()), FS.isRegularFile(op.file),
                          let expected = op.expected, (try? Data(contentsOf: op.file)) == expected else {
                        report.skipped += 1
                        continue
                    }
                    if op.kind == .update, let contents = op.contents {
                        try backups.copy(op.file)
                        try AtomicFile.write(contents, to: op.file)
                        report.updated += 1
                    } else {
                        try backups.move(op.file)
                        state.created.removeAll { $0.file == op.file.path }
                        report.removed += 1
                        changed = true
                    }
                }
            } catch {
                report.failures.append("\(op.file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let tombstones = Set(state.tombstones).union(plan.tombstones)
        if tombstones.count != state.tombstones.count { changed = true }
        state.tombstones = tombstones.sorted()
        if changed { try state.save(to: paths.syncStateFile) }
        return report
    }

    /// Sessions a running profile has not loaded: missing from it, or created by OpenAccs after it launched.
    /// 0 for a profile that is not running (it loads everything at launch).
    public func pendingCount(for profile: ClaudeProfile, among profiles: [ClaudeProfile]) -> Int {
        let path = profile.dataDir.standardizedFileURL.path
        guard let process = claude.processes().first(where: {
            guard let args = $0.arguments, !ClaudeProfiles.isHelper(args) else { return false }
            return claude.dataDir(fromArguments: args).standardizedFileURL.path == path
        }), let cardsDir = profile.cardsDir?.standardizedFileURL.path,
            let scan = try? Scan(profiles: profiles + [profile], paths: paths),
            let folder = scan.folders.first(where: { $0.dir.path == cardsDir }) else { return 0 }
        let launch = process.launchDate ?? .distantFuture
        let createdAt = Dictionary(scan.state.created.map { ($0.file, $0.createdAt) }, uniquingKeysWith: max)
        return scan.universe.keys.filter { id in
            let mine = folder.cards.filter { $0.claims.contains(id) }
            return mine.allSatisfy { card in createdAt[card.file.path].map { $0 > launch } ?? false }
        }.count
    }

    // MARK: Cards

    /// A copy of `source` through the allow-list, named after its sessionId unless that name is taken.
    static func newCard(from source: Card, avoiding names: inout Set<String>) -> (String, Data)? {
        var card: [String: Any] = [:]
        for key in copiedFields {
            if let value = source.object[key], !(value is NSNull) { card[key] = value }
        }
        if card["permissionMode"] as? String == "bypassPermissions" { card["permissionMode"] = nil }
        var sessionId = source.sessionId
        if !(sessionId.hasPrefix("local_") && FS.isSafeName(sessionId)) || names.contains(sessionId + ".json") {
            repeat { sessionId = "local_" + UUID().uuidString.lowercased() } while names.contains(sessionId + ".json")
        }
        card["sessionId"] = sessionId
        guard let data = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        names.insert(sessionId + ".json")
        return (sessionId + ".json", data)
    }

    /// `card` with lastActivityAt from `fresh`, and its title and titleSource too unless someone chose
    /// the card's title. nil when nothing changes.
    static func refreshed(_ card: Card, from fresh: Card) -> Data? {
        var object = card.object
        let titleIsChosen = (card.object["titleSource"] as? String).map(chosenTitleSources.contains) ?? false
        for key in titleIsChosen ? ["lastActivityAt"] : refreshedFields {
            if let value = fresh.object[key], !(value is NSNull) { object[key] = value }
        }
        guard !(object as NSDictionary).isEqual(to: card.object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}

/// One card file as read from disk.
struct Card {
    var file: URL
    var raw: Data
    var object: [String: Any]
    var sessionId: String
    /// nil after /clear until the next message starts a new transcript. Such a card is never a source
    /// and never edited; it only claims its lineage.
    var cliSessionId: String?
    var lastActivityAt: Double
    /// Earlier transcript ids this card replaced (`priorCliSessionIds`, `preClearCliSessionId`, and
    /// `unarchivedCliSessionId` while it has no `cliSessionId`).
    var lineage: Set<String>
    /// Every transcript id this card stands for in its profile.
    var claims: Set<String>

    init?(file: URL, raw: Data) {
        guard let object = JSON.object(raw), let sessionId = object["sessionId"] as? String else { return nil }
        let cli = object["cliSessionId"] as? String
        if let cli, !FS.isSafeName(cli) { return nil }
        self.file = file
        self.raw = raw
        self.object = object
        self.sessionId = sessionId
        cliSessionId = cli
        lastActivityAt = JSON.double(object["lastActivityAt"]) ?? 0
        let unarchived = object["unarchivedCliSessionId"] as? String
        var lineage = Set((object["priorCliSessionIds"] as? [Any] ?? []).compactMap { $0 as? String })
        if let id = object["preClearCliSessionId"] as? String { lineage.insert(id) }
        if let cli { lineage.remove(cli) } else if let unarchived { lineage.insert(unarchived) }
        self.lineage = lineage
        claims = lineage.union([cli, unarchived].compactMap { $0 })
    }

    /// Enough to become a new session elsewhere.
    var isCopyable: Bool { object["cwd"] is String }
}

/// One profile's current card folder.
struct CardFolder {
    var profile: ClaudeProfile
    var dir: URL
    /// The folder exists and was listed (only then can a missing card mean "deleted").
    var listed: Bool
    var names: Set<String> = []
    var cards: [Card] = []
    /// `deleted_<cliSessionId>` files Claude writes when a session is deleted.
    var tombstones: Set<String> = []
    var claims: Set<String> = []

    /// nil when the folder can't be used safely (symlinked, not a directory, unreadable).
    init?(profile: ClaudeProfile) {
        guard let cardsDir = profile.cardsDir else { return nil }
        self.profile = profile
        dir = cardsDir.standardizedFileURL
        guard FS.noLinks(below: profile.dataDir, to: dir) else { return nil }
        guard FS.exists(dir) else {
            listed = false
            return
        }
        guard let names = FS.names(in: dir) else { return nil }
        listed = true
        self.names = Set(names)
        for name in names.sorted() {
            if name.hasPrefix("deleted_") {
                let id = String(name.dropFirst("deleted_".count))
                if FS.isSafeName(id) { tombstones.insert(id) }
                continue
            }
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            let file = dir.appending(path: name)
            guard FS.isRegularFile(file), let raw = try? Data(contentsOf: file), let card = Card(file: file, raw: raw) else { continue }
            cards.append(card)
            claims.formUnion(card.claims)
        }
    }
}

/// Everything a sync decision needs, read once.
struct Scan {
    var folders: [CardFolder] = []
    var state: SyncState
    /// Sessions that must never be recreated.
    var deleted: Set<String>
    /// Deletions not yet in the sync state.
    var noticedDeletions: Set<String>
    /// cliSessionId → freshest copyable card of a live session whose transcript exists.
    var universe: [String: Card] = [:]

    init(profiles: [ClaudeProfile], paths: Paths) throws {
        state = try SyncState.load(paths.syncStateFile)
        var seen = Set<String>()
        for profile in profiles {
            guard let folder = CardFolder(profile: profile), seen.insert(folder.dir.path).inserted else { continue }
            folders.append(folder)
        }

        var noticed = folders.reduce(into: Set<String>()) { $0.formUnion($1.tombstones) }
        // A card OpenAccs created that is gone (and not replaced) was deleted by the user.
        for entry in state.created {
            let file = URL(filePath: entry.file)
            guard let folder = folders.first(where: { $0.listed && $0.dir.path == file.deletingLastPathComponent().path }) else { continue }
            if !FS.exists(file) && !folder.claims.contains(entry.cliSessionId) { noticed.insert(entry.cliSessionId) }
        }
        noticed.subtract(state.tombstones)
        noticedDeletions = noticed
        deleted = noticed.union(state.tombstones)

        let superseded = folders.reduce(into: Set<String>()) { set, folder in folder.cards.forEach { set.formUnion($0.lineage) } }
        let transcripts = TranscriptIndex(projects: paths.claudeSharedConfigDir.appending(path: "projects", directoryHint: .isDirectory))
        for folder in folders {
            for card in folder.cards where card.isCopyable {
                guard let id = card.cliSessionId, !deleted.contains(id), !superseded.contains(id) else { continue }
                if let current = universe[id], current.lastActivityAt >= card.lastActivityAt { continue }
                guard transcripts.exists(id) else { continue }
                universe[id] = card
            }
        }
    }
}

/// `~/.claude/projects/<any>/<id>.jsonl`, listed once.
struct TranscriptIndex {
    private var locations: [String: [URL]] = [:]

    init(projects: URL) {
        let fm = FileManager.default
        for project in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let dir = projects.appending(path: project, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jsonl") {
                locations[String(name.dropLast(".jsonl".count)), default: []].append(dir.appending(path: name))
            }
        }
    }

    /// True when a regular file (not a link) holds that transcript.
    func exists(_ id: String) -> Bool {
        locations[id]?.contains(where: FS.isRegularFile) ?? false
    }
}

/// `claude-sync.json`: cards OpenAccs created (for deletion detection and undo) and deleted sessions.
struct SyncState: Codable, Equatable {
    struct Created: Codable, Hashable {
        var file: String
        var cliSessionId: String
        var createdAt: Date
    }

    var created: [Created] = []
    var tombstones: [String] = []

    static func load(_ url: URL) throws -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        return try JSON.decoder.decode(SyncState.self, from: data)
    }

    func save(to url: URL) throws {
        try AtomicFile.write(JSON.encoder.encode(self), to: url, permissions: 0o600)
    }
}
