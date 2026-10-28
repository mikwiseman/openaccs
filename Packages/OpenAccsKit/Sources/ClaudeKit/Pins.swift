import Foundation
import OpenAccsCore

/// The chats pinned in a profile's sidebar. The app keeps them in its localStorage
/// (`LSS-persisted.starred-local-code-sessions`, card sessionIds) and copies every change into
/// `preferences.epitaxyPrefs` of its `claude_desktop_config.json`, which it reads back only when localStorage
/// has no pins. So the config tells what a profile pins, and a change goes into both. The sidebar orders pins
/// by their place in `dframe-local-slice.pinnedOrder` (`code:<sessionId>`), another store. A card's own
/// `isStarred` is a copy the app makes from the list.
struct PinList {
    static let starredKey = "starred-local-code-sessions"
    static let sliceKey = "dframe-local-slice"
    static let orderKey = "pinnedOrder"
    static let origin = "https://claude.ai"
    static let storageKey = "LSS-persisted.starred-local-code-sessions"

    /// A Code-tab setting's localStorage value (these pins, or another), as the app writes it.
    static func storageValue(_ value: Any, now: Date = Date()) -> String? {
        let object: [String: Any] = ["value": value, "tabId": "", "timestamp": Int64(now.timeIntervalSince1970 * 1000)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    var file: URL
    var raw: Data
    var object: [String: Any]
    var modified: Date
    /// Pinned sessionIds in sidebar order.
    var ids: [String]

    static func file(in dataDir: URL) -> URL { dataDir.appending(path: "claude_desktop_config.json") }

    /// nil when the profile has no config yet (Claude makes it at first launch) or it isn't a JSON object.
    init?(dataDir: URL) {
        let file = Self.file(in: dataDir)
        guard let version = FS.version(file), let raw = try? Data(contentsOf: file), let object = JSON.object(raw) else { return nil }
        self.file = file
        self.raw = raw
        self.object = object
        modified = version.modificationDate
        let prefs = Self.prefs(of: object)
        let starred = (prefs[Self.starredKey] as? [Any] ?? []).compactMap { $0 as? String }
        var place: [String: Int] = [:]
        for (i, entry) in ((prefs[Self.sliceKey] as? [String: Any])?[Self.orderKey] as? [Any] ?? []).enumerated() {
            if let entry = entry as? String, entry.hasPrefix("code:") { place[String(entry.dropFirst(5))] = i }
        }
        var seen = Set<String>()
        ids = starred.enumerated()
            .sorted { (place[$0.element] ?? .max, $0.offset) < (place[$1.element] ?? .max, $1.offset) }
            .map(\.element)
            .filter { seen.insert($0).inserted }
    }

    /// The file with `ids` pinned in this order; everything else in it stays as it is.
    func with(_ ids: [String]) -> Data? {
        let entries = Set(ids.map { "code:" + $0 })
        var prefs = Self.prefs(of: object)
        var slice = prefs[Self.sliceKey] as? [String: Any] ?? [:]
        let order = (slice[Self.orderKey] as? [Any] ?? []).filter { !(($0 as? String).map(entries.contains) ?? false) }
        slice[Self.orderKey] = order + ids.map { "code:" + $0 }
        prefs[Self.sliceKey] = slice
        prefs[Self.starredKey] = ids
        var preferences = object["preferences"] as? [String: Any] ?? [:]
        preferences["epitaxyPrefs"] = prefs
        var object = self.object
        object["preferences"] = preferences
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// The pin lists alone, shaped like the config, for Backups (the config also holds MCP server settings,
    /// keys among them, which are never copied).
    func backup() -> Data? {
        var prefs: [String: Any] = [:]
        let all = Self.prefs(of: object)
        prefs[Self.starredKey] = all[Self.starredKey]
        if let order = (all[Self.sliceKey] as? [String: Any])?[Self.orderKey] { prefs[Self.sliceKey] = [Self.orderKey: order] }
        return try? JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": prefs]], options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    private static func prefs(of object: [String: Any]) -> [String: Any] {
        (object["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] ?? [:]
    }
}

/// The chats every sidebar should pin (by cliSessionId). Merged per chat like the chat settings: what a
/// profile pinned or unpinned since the last sync is a change (the newest config wins when two disagree),
/// anything else keeps the last agreement. A first sync, or a profile seen for the first time, keeps every
/// pin. Only which chats are pinned counts, not their order (the app keeps that elsewhere).
enum PinAgreement {
    struct Holder {
        /// What its sidebar pins now, and what it pinned at the last sync (nil: never seen).
        var now: [String]
        var seen: [String]?
        var modified: Date
    }

    static func merge(_ agreed: [String]?, holders: [Holder], deleted: Set<String>) -> [String] {
        var result = agreed ?? []
        func add(_ chats: [String]) { result += chats.filter { !result.contains($0) } }
        let newest = holders.sorted { $0.modified > $1.modified }
        for holder in newest where agreed == nil || holder.seen == nil { add(holder.now) }
        let changed = holders.filter { holder in holder.seen.map { Set($0) != Set(holder.now) } ?? false }
            .sorted { $0.modified < $1.modified }
        for holder in changed {
            let seen = Set(holder.seen ?? [])
            result.removeAll { seen.contains($0) && !holder.now.contains($0) }
            add(holder.now.filter { !seen.contains($0) })
        }
        return result.filter { !deleted.contains($0) }
    }
}
