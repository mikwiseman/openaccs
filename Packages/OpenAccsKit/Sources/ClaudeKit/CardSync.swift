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
    /// The folder is (or may be) the one its profile's app shows: edit it only while that app is closed.
    var requiresStopped = true
    /// The chat settings the card holds once written (create, update).
    var settles: [String: String]?
    /// Keep a copy of the old card first; not needed when only its activity time moves on.
    var backup = true
}

public struct SyncPlan: Sendable, Hashable {
    public var operations: [SyncOperation]
    /// Deleted sessions noticed while planning; apply remembers them so they are never recreated.
    public var tombstones: [String]
    /// Chat settings to remember for the next sync; nil when nothing new.
    var records: SyncRecords?
    /// Folders an open app has loaded whose chats differ from the agreed settings: chats by folder path.
    /// They catch up when that app restarts.
    public var waiting: [String: Int] = [:]

    public var isEmpty: Bool { operations.isEmpty && tombstones.isEmpty && records == nil }

    /// Chats in an open app's folder that wait for a restart to show their pin, mode or other settings.
    public func waiting(in cardsDir: URL) -> Int {
        waiting[cardsDir.standardizedFileURL.path] ?? 0
    }

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

/// What `apply` remembers about chat settings: the agreed values and what each folder held.
struct SyncRecords: Sendable, Hashable {
    var settings: [String: [String: String]]
    var seen: [String: [String: [String: String]]]
}

/// Keeps every profile's Code-tab session list complete over the shared `~/.claude` transcripts, in
/// every account folder of every profile, with the same pins and chat settings everywhere.
/// Cards are copied through an allow-list (never account-bound fields), created exclusively,
/// edited only where no open app has them loaded after a backup, and never deleted (moved to Backups).
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
        "isArchived", "isStarred", "model", "effort", "permissionMode", "completedTurns",
    ]

    /// A chat setting that is the same in every window: the last change anywhere wins.
    struct Setting: Sendable {
        enum FirstTime: Sendable {
            /// On if any window has it on (pins: nothing pinned disappears).
            case any
            /// On only if every window has it on (archive: nothing shown disappears).
            case all
            /// From the copy used last.
            case freshest
        }

        var key: String
        /// true/false (missing = false); otherwise a string (missing = no opinion).
        var isFlag: Bool
        var firstTime: FirstTime
        /// Fields that go with this one, copied from the card that holds the agreed value.
        var companions: [String] = []

        func value(in object: [String: Any]) -> String? {
            isFlag ? ((object[key] as? Bool) ?? false ? "true" : "false") : object[key] as? String
        }

        func typed(_ value: String) -> Any {
            isFlag ? value == "true" : value
        }
    }

    static let settings = [
        Setting(key: "isStarred", isFlag: true, firstTime: .any),
        Setting(key: "isArchived", isFlag: true, firstTime: .all),
        Setting(key: "permissionMode", isFlag: false, firstTime: .freshest, companions: ["autoChosenInApp", "bypassChosenInApp"]),
        Setting(key: "effort", isFlag: false, firstTime: .freshest),
        Setting(key: "model", isFlag: false, firstTime: .freshest),
    ]
    static let refreshedFields = ["title", "titleSource", "lastActivityAt"]
    /// Titles someone chose: a rename in the app ("user") or through Claude's rename tool ("tool").
    /// Claude itself never lets an "auto" title replace these.
    static let chosenTitleSources: Set<String> = ["user", "tool"]

    /// What a sync would do now. Reads only; `running` = data folders of running profiles.
    public func plan(profiles: [ClaudeProfile], running: Set<URL>) throws -> SyncPlan {
        let runningPaths = Set(running.map(\.standardizedFileURL.path))
        // Each profile's folder for the account its app shows ("current"), plus one per account signed in
        // there before: the app reads those again on that account's next sign-in, so they can be edited
        // even while it runs. Unless Claude's log confirmed which folder the app shows: then any of them
        // may be loaded, so all of them wait for it to close.
        var targets: [ClaudeProfile] = [], current = Set<String>(), live = Set<String>(), guarded = Set<String>()
        for profile in profiles {
            let isRunning = runningPaths.contains(profile.dataDir.standardizedFileURL.path)
            let shown = profile.cardsDir?.standardizedFileURL.path
            let isSure = shown != nil && profile.isConfirmed
            for folder in claude.folders(of: profile) {
                guard let dir = folder.cardsDir?.standardizedFileURL.path else { continue }
                targets.append(folder)
                if dir == shown { current.insert(dir) }
                if dir == shown || !isSure { guarded.insert(dir) }
                if isRunning && (dir == shown || !isSure) { live.insert(dir) }
            }
        }
        let scan = try Scan(profiles: targets, paths: paths)
        let madeByUs = Set(scan.state.created.map(\.file))
        let agreement = Agreement(scan: scan, current: current, madeByUs: madeByUs)
        var operations: [SyncOperation] = []
        var waiting: [String: Int] = [:]
        for folder in scan.folders {
            let dir = folder.dir.path, dataDir = folder.profile.dataDir, isGuarded = guarded.contains(dir)
            var names = folder.names
            for id in scan.universe.keys.sorted() where !folder.claims.contains(id) {
                guard let source = scan.universe[id],
                      let (name, data, settles) = Self.newCard(from: source, settings: agreement.settings[id] ?? [:],
                                                               companions: agreement.companions[id], avoiding: &names) else { continue }
                operations.append(SyncOperation(kind: .create, dataDir: dataDir, file: folder.dir.appending(path: name), cliSessionId: id,
                                                contents: data, requiresStopped: isGuarded, settles: settles))
            }
            let isLive = live.contains(dir)
            var behind = 0
            for card in folder.cards {
                guard let id = card.cliSessionId else { continue }
                if scan.deleted.contains(id) {
                    guard !isLive, madeByUs.contains(card.file.path) else { continue }
                    operations.append(SyncOperation(kind: .remove, dataDir: dataDir, file: card.file, cliSessionId: id,
                                                    expected: card.raw, requiresStopped: isGuarded))
                    continue
                }
                guard let fresh = scan.universe[id] else { continue }
                let wanted = agreement.settings[id] ?? [:]
                if isLive {
                    if Self.differs(card.object, from: wanted) { behind += 1 }
                } else if let (data, settles, onlyActivity) = Self.updated(card, from: fresh, settings: wanted, companions: agreement.companions[id]) {
                    operations.append(SyncOperation(kind: .update, dataDir: dataDir, file: card.file, cliSessionId: id, contents: data,
                                                    expected: card.raw, requiresStopped: isGuarded, settles: settles, backup: !onlyActivity))
                }
            }
            if behind > 0 { waiting[dir] = behind }
        }
        // Added to what was remembered (a chat missing from one scan keeps its history); deleted chats go.
        var records = SyncRecords(settings: scan.state.settings, seen: scan.state.seen)
        records.settings.merge(agreement.settings) { _, new in new }
        for (dir, chats) in agreement.seen { records.seen[dir, default: [:]].merge(chats) { _, new in new } }
        for id in scan.deleted {
            records.settings[id] = nil
            for dir in records.seen.keys { records.seen[dir]?[id] = nil }
        }
        let isNew = records.settings != scan.state.settings || records.seen != scan.state.seen
        return SyncPlan(operations: operations, tombstones: scan.noticedDeletions.sorted(), records: isNew ? records : nil, waiting: waiting)
    }

    /// Carries out a plan. Re-checks every edit against the disk and the running apps first.
    public func apply(_ plan: SyncPlan) throws -> SyncReport {
        let before = try SyncState.load(paths.syncStateFile)
        var state = before
        if let records = plan.records {
            state.settings = records.settings
            state.seen = records.seen
        }
        let backups = Backups(base: paths.backupsDir, label: "card-sync")
        var report = SyncReport()
        for op in plan.operations {
            let folder = op.file.deletingLastPathComponent()
            do {
                switch op.kind {
                case .create:
                    guard let contents = op.contents, FS.noLinks(below: op.dataDir, to: folder) else {
                        report.skipped += 1
                        continue
                    }
                    if !FS.exists(folder) { try FS.makeDirectory(folder) }
                    guard try AtomicFile.createExclusively(contents, at: op.file) else {
                        report.skipped += 1
                        continue
                    }
                    state.created.append(SyncState.Created(file: op.file.path, cliSessionId: op.cliSessionId, createdAt: Date()))
                    report.created += 1
                case .update, .remove:
                    // Asked right before each edit: a profile may start while a long plan runs.
                    let stopped = !op.requiresStopped || claude.runningByPath().map { $0[op.dataDir.standardizedFileURL.path] == nil } ?? false
                    guard stopped, FS.noLinks(below: op.dataDir, to: folder), FS.isRegularFile(op.file),
                          let expected = op.expected, (try? Data(contentsOf: op.file)) == expected else {
                        report.skipped += 1
                        continue
                    }
                    if op.kind == .update, let contents = op.contents {
                        if op.backup { try backups.copy(op.file) }
                        try AtomicFile.write(contents, to: op.file)
                        report.updated += 1
                    } else {
                        try backups.move(op.file)
                        state.created.removeAll { $0.file == op.file.path }
                        report.removed += 1
                    }
                }
                if let settles = op.settles { state.seen[folder.standardizedFileURL.path, default: [:]][op.cliSessionId] = settles }
            } catch {
                report.failures.append("\(op.file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        state.tombstones = Set(state.tombstones).union(plan.tombstones).sorted()
        if state != before { try state.save(to: paths.syncStateFile) }
        return report
    }

    /// Sessions a running profile has not loaded: missing from it, or created by OpenAccs after it launched.
    /// 0 for a profile that is not running (it loads everything at launch).
    public func pendingCount(for profile: ClaudeProfile, among profiles: [ClaudeProfile]) -> Int {
        let path = profile.dataDir.standardizedFileURL.path
        // Over the same folders as `plan`, so sessions replaced in an older folder aren't counted as missing.
        guard let process = claude.processes().first(where: {
            guard let args = $0.arguments, !ClaudeProfiles.isHelper(args) else { return false }
            return claude.dataDir(fromArguments: args).standardizedFileURL.path == path
        }), let cardsDir = profile.cardsDir?.standardizedFileURL.path,
            let scan = try? Scan(profiles: (profiles + [profile]).flatMap(claude.folders(of:)), paths: paths),
            let folder = scan.folders.first(where: { $0.dir.path == cardsDir }) else { return 0 }
        let launch = process.launchDate ?? .distantFuture
        let createdAt = Dictionary(scan.state.created.map { ($0.file, $0.createdAt) }, uniquingKeysWith: max)
        return scan.universe.keys.filter { id in
            let mine = folder.cards.filter { $0.claims.contains(id) }
            return mine.allSatisfy { card in createdAt[card.file.path].map { $0 > launch } ?? false }
        }.count
    }

    // MARK: Cards

    /// A copy of `source` through the allow-list with the agreed chat settings, named after its sessionId
    /// unless that name is taken.
    static func newCard(from source: Card, settings wanted: [String: String], companions: [String: Any]?,
                        avoiding names: inout Set<String>) -> (String, Data, [String: String])? {
        var card: [String: Any] = [:]
        for key in copiedFields {
            if let value = source.object[key], !(value is NSNull) { card[key] = value }
        }
        apply(wanted, companions: companions, to: &card)
        var sessionId = source.sessionId
        if !(sessionId.hasPrefix("local_") && FS.isSafeName(sessionId)) || names.contains(sessionId + ".json") {
            repeat { sessionId = "local_" + UUID().uuidString.lowercased() } while names.contains(sessionId + ".json")
        }
        card["sessionId"] = sessionId
        guard let data = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        names.insert(sessionId + ".json")
        return (sessionId + ".json", data, values(of: card))
    }

    /// `card` with lastActivityAt from `fresh` (and its title and titleSource too unless someone chose the
    /// card's title) and the agreed chat settings, plus whether only the activity time changed. nil when
    /// nothing changes.
    static func updated(_ card: Card, from fresh: Card, settings wanted: [String: String], companions: [String: Any]?) -> (Data, [String: String], Bool)? {
        var object = card.object
        if fresh.lastActivityAt > card.lastActivityAt {
            let titleIsChosen = (card.object["titleSource"] as? String).map(chosenTitleSources.contains) ?? false
            for key in titleIsChosen ? ["lastActivityAt"] : refreshedFields {
                if let value = fresh.object[key], !(value is NSNull) { object[key] = value }
            }
        }
        apply(wanted, companions: companions, to: &object)
        guard !(object as NSDictionary).isEqual(to: card.object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        var activityOnly = object
        activityOnly["lastActivityAt"] = card.object["lastActivityAt"]
        return (data, values(of: object), (activityOnly as NSDictionary).isEqual(to: card.object))
    }

    /// Sets each agreed setting the card lacks, with the fields that go with it (from the card that holds
    /// the agreed value, also when this card has the value already: Auto means more with its flag).
    static func apply(_ wanted: [String: String], companions: [String: Any]?, to object: inout [String: Any]) {
        for setting in settings {
            guard let target = wanted[setting.key] else { continue }
            if setting.value(in: object) != target { object[setting.key] = setting.typed(target) }
            if let companions, !setting.companions.isEmpty, setting.value(in: companions) == target {
                for key in setting.companions { object[key] = companions[key] }
            }
        }
    }

    static func differs(_ object: [String: Any], from wanted: [String: String]) -> Bool {
        settings.contains { setting in wanted[setting.key].map { $0 != setting.value(in: object) } ?? false }
    }

    /// The card's chat settings (choices it has no value for are left out).
    static func values(of object: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for setting in settings { result[setting.key] = setting.value(in: object) }
        return result
    }
}

/// The chat settings every folder should hold. What changed since the last sync wins (the newest change
/// if several), else what was agreed before. A chat never synced before keeps every pin a window shows
/// and takes the rest from where it ran last; folders of accounts signed in before don't vote.
struct Agreement {
    /// Chat → setting → value.
    var settings: [String: [String: String]] = [:]
    /// Chat → the card holding the agreed permission mode, for the fields that go with it.
    var companions: [String: [String: Any]] = [:]
    /// What each folder holds now: folder path → chat → setting → value.
    var seen: [String: [String: [String: String]]] = [:]

    init(scan: Scan, current: Set<String>, madeByUs: Set<String>) {
        var holders: [String: [(dir: String, card: Card)]] = [:]
        for folder in scan.folders {
            for card in folder.cards {
                guard let id = card.cliSessionId, scan.universe[id] != nil else { continue }
                holders[id, default: []].append((folder.dir.path, card))
                seen[folder.dir.path, default: [:]][id] = CardSync.values(of: card.object)
            }
        }
        for (id, list) in holders {
            var agreed: [String: String] = [:]
            for setting in CardSync.settings {
                let values = list.map { (holder: $0, value: setting.value(in: $0.card.object)) }
                let changes = values.filter { item in
                    guard let value = item.value, let last = scan.state.seen[item.holder.dir]?[id]?[setting.key] else { return false }
                    return value != last
                }
                if let newest = changes.max(by: { $0.holder.card.modified < $1.holder.card.modified }) {
                    agreed[setting.key] = newest.value
                } else if let before = scan.state.settings[id]?[setting.key] {
                    agreed[setting.key] = before
                } else {
                    let shown = values.filter { current.contains($0.holder.dir) }
                    let pool = shown.isEmpty ? values : shown
                    switch setting.firstTime {
                    case .any: agreed[setting.key] = pool.contains { $0.value == "true" } ? "true" : "false"
                    case .all: agreed[setting.key] = pool.allSatisfy { $0.value == "true" } ? "true" : "false"
                    case .freshest:
                        // A value from an old folder still beats none (no mode opens a chat in Manual). Among
                        // copies used at the same time, the one last opened, then one Claude wrote (OpenAccs's
                        // older copies kept the settings they were made with), then the newest file.
                        let known = pool.contains { $0.value != nil } ? pool : values
                        agreed[setting.key] = known.filter { $0.value != nil }.max { a, b in
                            let (x, y) = (a.holder.card, b.holder.card)
                            return (x.lastActivityAt, x.lastFocusedAt, madeByUs.contains(x.file.path) ? 0 : 1, x.modified)
                                < (y.lastActivityAt, y.lastFocusedAt, madeByUs.contains(y.file.path) ? 0 : 1, y.modified)
                        }?.value
                    }
                }
            }
            settings[id] = agreed
            // The flags come from a card where someone chose that mode in the app (it has them), preferably
            // one Claude wrote, then the one opened last, then the newest.
            if let mode = agreed["permissionMode"], let flags = CardSync.settings.first(where: { $0.key == "permissionMode" })?.companions {
                func rank(_ card: Card) -> (Int, Int, Double, Date) {
                    (flags.contains { card.object[$0] != nil } ? 1 : 0, madeByUs.contains(card.file.path) ? 0 : 1, card.lastFocusedAt, card.modified)
                }
                companions[id] = list.filter { $0.card.object["permissionMode"] as? String == mode }
                    .max { rank($0.card) < rank($1.card) }?.card.object
            }
        }
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
    /// When the chat was last opened in this profile; 0 if never.
    var lastFocusedAt: Double
    /// When the file last changed (which copy changed a setting last).
    var modified: Date = .distantPast
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
        lastFocusedAt = JSON.double(object["lastFocusedAt"]) ?? 0
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
            guard FS.isRegularFile(file), let raw = try? Data(contentsOf: file), var card = Card(file: file, raw: raw) else { continue }
            card.modified = FS.modificationDate(file) ?? .distantPast
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
        file(for: id) != nil
    }

    /// The regular file (not a link) holding that transcript; the newest when a chat has copies in several
    /// project folders (it moved to another folder or worktree).
    func file(for id: String) -> URL? {
        locations[id]?.filter(FS.isRegularFile).max { (FS.modificationDate($0) ?? .distantPast) < (FS.modificationDate($1) ?? .distantPast) }
    }
}

/// `claude-sync.json`: cards OpenAccs created (for deletion detection and undo), deleted sessions, and
/// the chat settings of the last sync.
struct SyncState: Codable, Equatable {
    struct Created: Codable, Hashable {
        var file: String
        var cliSessionId: String
        var createdAt: Date
    }

    var created: [Created] = []
    var tombstones: [String] = []
    /// Chat settings agreed at the last sync: chat → setting → value.
    var settings: [String: [String: String]] = [:]
    /// What each card folder held then (or got from OpenAccs): folder path → chat → setting → value.
    var seen: [String: [String: [String: String]]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = try c.decodeIfPresent([Created].self, forKey: .created) ?? []
        tombstones = try c.decodeIfPresent([String].self, forKey: .tombstones) ?? []
        settings = try c.decodeIfPresent([String: [String: String]].self, forKey: .settings) ?? [:]
        seen = try c.decodeIfPresent([String: [String: [String: String]]].self, forKey: .seen) ?? [:]
    }

    static func load(_ url: URL) throws -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        return try JSON.decoder.decode(SyncState.self, from: data)
    }

    func save(to url: URL) throws {
        try AtomicFile.write(JSON.encoder.encode(self), to: url, permissions: 0o600)
    }
}
