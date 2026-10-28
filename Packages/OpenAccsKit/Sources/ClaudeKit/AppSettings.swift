import CryptoKit
import Foundation
import OpenAccsCore

/// The Claude app's own settings, the same in every window: some preferences, the folder permission modes, the
/// Code tab's new-session defaults (model, effort, fast mode) and the desktop chat MCP servers. A window keeps them
/// in `<dataDir>/claude_desktop_config.json` and `ccd-session-presets.json`, next to what belongs to it alone
/// (consents, pins, window state). The Code tab keeps its own in localStorage and copies them into those files:
/// `preferences.epitaxyPrefs.<key>` is a copy of `LSS-persisted.<key>`, the new-session defaults come from
/// `persisted.ccd-session-presets.<account>`. At launch it reads localStorage, and a copy only while that has
/// none, so a change goes into both. Not here: the composer's fast mode and permission mode (the app sets them
/// from the new-session defaults at launch), and the sidebar's layout (`dframe-store`), which Claude syncs per
/// account through its own servers and puts back at every launch.
///
/// Agreed setting by setting, and entry by entry for a map (a folder's mode, an MCP server), against the last
/// sync: a window holding something else than it held then changed it, and the newest change wins (by its file's
/// date); otherwise the agreed value stays. The first sync takes the default window's values, plus every entry only
/// others have: windows OpenAccs adds start with the app's defaults. A window new to the sync never overrides
/// anything and adds only entries nobody had. A setting a window lacks is no opinion; a map entry it dropped is a
/// removal. A running app saves its settings from memory, so a window is written only while its app is closed;
/// until then what differs waits for its restart.
public enum AppSettings {
    struct Setting: Sendable {
        enum File: Sendable { case config, presets }
        enum Kind: Sendable, Equatable {
            case whole
            /// A map merged entry by entry.
            case map
        }

        /// A localStorage store that holds it (the file has its copy), and its place in the store's JSON.
        struct Store: Sendable {
            var key: String
            var place: [String]
        }

        var name: String
        var file: File = .config
        /// Its place in the file; `{account}` and `{org}` stand for the window's own.
        var place: [String]
        var kind: Kind = .whole
        /// Leading parts of the place that must be there already: the app makes an account's presets itself, with
        /// flags of their own, so OpenAccs never starts them.
        var made = 0
        var store: Store?

        /// Where it is in this window; nil while the window's account (or org) isn't known.
        func place(in window: ClaudeProfile) -> [String]? { Self.resolve(place, window) }

        /// Its store in this window: the key and the place in it.
        func store(in window: ClaudeProfile) -> Store? {
            guard let store, let key = Self.resolve([store.key], window)?.first, let place = Self.resolve(store.place, window) else { return nil }
            return Store(key: key, place: place)
        }

        static func resolve(_ parts: [String], _ window: ClaudeProfile) -> [String]? {
            var result: [String] = []
            for part in parts {
                if part.contains("{account}") || part.contains("{org}") {
                    guard let account = window.accountUuid, !part.contains("{org}") || window.orgUuid != nil else { return nil }
                    result.append(part.replacingOccurrences(of: "{account}", with: account).replacingOccurrences(of: "{org}", with: window.orgUuid ?? ""))
                } else {
                    result.append(part)
                }
            }
            return result
        }

        /// The localStorage key the app reads it from at launch, if it is one of the Code tab's.
        func storageKey(at place: [String]) -> String? {
            place.count > 2 && place[0] == "preferences" && place[1] == "epitaxyPrefs" ? "LSS-persisted.\(place[2])" : nil
        }
    }

    /// The shared settings. None is a consent, opt-in, gate, seen, nudge, ack, intro, onboarding or count flag:
    /// OpenAccs never agrees to anything on the user's behalf. Pins have a sync of their own.
    static let settings: [Setting] = [
        "bypassPermissionsModeEnabled", "allowAllBrowserActions", "chicagoEnabled", "ccRemoteControlDefaultEnabled",
        "dispatchCodeTasksPermissionMode", "menuBarEnabled", "dockBounceEnabled", "ccdScheduledTasksEnabled", "sidebarMode",
        "coworkBrowserToolsEnabled", "coworkPreferredBrowser", "coworkWebSearchEnabled", "coworkScheduledTasksEnabled",
    ].map { Setting(name: $0, place: ["preferences", $0]) } + [
        Setting(name: "folderModes", place: ["preferences", "epitaxyPrefs", "epitaxy-folder-permission-mode-v2.{account}"], kind: .map),
        Setting(name: "mcpServers", place: ["mcpServers"], kind: .map),
        Setting(name: "newSession", file: .presets, place: ["byAccount", "{account}", "builtIns", "local", "settings"], made: 2,
                store: Setting.Store(key: "persisted.ccd-session-presets.{account}", place: ["state", "builtIns", "local", "settings"])),
    ]

    static func setting(of atom: String) -> Setting? {
        let name = atom.split(separator: ":", maxSplits: 1).first.map(String.init) ?? atom
        return settings.first { $0.name == name }
    }

    // MARK: Reading

    struct Document {
        var file: URL
        var raw: Data
        var object: [String: Any]
        var modified: Date
    }

    /// One window's shared settings as atoms: a setting's whole value, or one per entry (`name:entry`).
    struct Window {
        var profile: ClaudeProfile
        var key: String
        var config: Document
        var presets: Document?
        /// Setting → its place here, for each setting this window can hold.
        var places: [String: [String]] = [:]
        var values: [String: Any] = [:]
        var digests: [String: String] = [:]

        func document(_ setting: Setting) -> Document? { setting.file == .config ? config : presets }
        func modified(_ setting: Setting) -> Date { document(setting)?.modified ?? .distantPast }
    }

    /// nil when the window has no config yet (Claude makes it at first launch) or it isn't a JSON object.
    static func read(_ profile: ClaudeProfile) -> Window? {
        guard let config = document(profile.dataDir.appending(path: "claude_desktop_config.json")) else { return nil }
        var window = Window(profile: profile, key: profile.dataDir.standardizedFileURL.path, config: config,
                            presets: document(profile.dataDir.appending(path: "ccd-session-presets.json")))
        for setting in settings {
            guard let document = window.document(setting), let place = setting.place(in: profile),
                  setting.made == 0 || value(at: Array(place.prefix(setting.made)), in: document.object) is [String: Any] else { continue }
            window.places[setting.name] = place
            for (atom, value) in atoms(of: setting, value(at: place, in: document.object)) {
                window.values[atom] = value
                window.digests[atom] = digest(value)
            }
        }
        return window
    }

    static func document(_ file: URL) -> Document? {
        guard let version = FS.version(file), let raw = try? Data(contentsOf: file), let object = JSON.object(raw) else { return nil }
        return Document(file: file, raw: raw, object: object, modified: version.modificationDate)
    }

    static func atoms(of setting: Setting, _ value: Any?) -> [(String, Any)] {
        guard let value, !(value is NSNull) else { return [] }
        switch setting.kind {
        case .whole:
            return [(setting.name, value)]
        case .map:
            return (value as? [String: Any] ?? [:]).map { ("\(setting.name):\($0.key)", $0.value) }
        }
    }

    // MARK: Agreeing

    /// What every window should hold: atom → value. `agreed` (nil before the first sync) and `seen` (window →
    /// what it held then) are digests from the last sync.
    static func agree(_ windows: [Window], agreed: [String: String]?, seen: [String: [String: String]]) -> [String: Any] {
        let golden = windows.first { $0.profile.isDefault }?.key ?? windows.first?.key
        var all = Set(agreed.map { Array($0.keys) } ?? [])
        for window in windows {
            all.formUnion(window.digests.keys)
            all.formUnion(seen[window.key].map { Array($0.keys) } ?? [])
        }
        var result: [String: Any] = [:]
        for atom in all {
            guard let setting = setting(of: atom) else { continue }
            let holders = windows.filter { $0.places[setting.name] != nil }
            let changed = holders.filter { window in
                guard let before = seen[window.key] else { return false }   // new to the sync: nothing of its own changed
                let now = window.digests[atom]
                if now == nil, setting.kind == .whole || before[atom] == nil { return false }   // lacking a setting is no opinion
                return now != before[atom] && now != agreed?[atom]
            }
            if let newest = changed.max(by: { $0.modified(setting) < $1.modified(setting) }) {
                result[atom] = newest.values[atom]   // nil: an entry removed there
                continue
            }
            if let digest = agreed?[atom], let holder = holders.first(where: { $0.digests[atom] == digest }) {
                result[atom] = holder.values[atom]
                continue
            }
            // Never agreed: the first sync, or something only a window new to the sync has. The default window's
            // value first, then the newest file's.
            let candidates = holders.filter { $0.values[atom] != nil && (agreed?[atom] != nil || agreed == nil || seen[$0.key] == nil) }
            if let pick = candidates.first(where: { $0.key == golden }) ?? candidates.max(by: { $0.modified(setting) < $1.modified(setting) }) {
                result[atom] = pick.values[atom]
            }
        }
        return result
    }

    /// Settings of this window that differ from `result`.
    static func differences(_ window: Window, _ result: [String: Any]) -> Int {
        var count = 0
        for setting in settings where window.places[setting.name] != nil {
            let atoms = Set(window.digests.keys.filter { Self.setting(of: $0)?.name == setting.name })
                .union(result.keys.filter { Self.setting(of: $0)?.name == setting.name })
            for atom in atoms {
                let wanted = result[atom].flatMap(digest)
                if wanted == nil && setting.kind == .whole { continue }   // nobody has it: it keeps its own
                if window.digests[atom] != wanted { count += 1 }
            }
        }
        return count
    }

    // MARK: Writing

    struct FileWrite: Sendable, Hashable {
        var file: URL
        var contents: Data
        /// The file as planned; nothing is written if it changed since.
        var expected: Data
        /// The old values of what changes, shaped like the file, for Backups (nil: none was there).
        var backup: Data?
    }

    /// One localStorage change: a whole value in the app's `{"value": …}` wrapper (`place` nil), or one place inside
    /// the JSON of a store, the rest of it as it is.
    struct StorageEdit: Sendable, Hashable {
        var key: String
        var place: [String]?
        var json: String
    }

    struct Write: Sendable, Hashable {
        /// Made first: the app reads these at launch.
        var storage: [StorageEdit] = []
        var config: FileWrite?
        var presets: FileWrite?
        /// What the window holds once written, for the next sync.
        var seen: [String: String] = [:]
    }

    /// What a stopped window needs to hold `result`; nil when it holds it already. `base` is its config as
    /// another change in this sync leaves it (its pins), if any.
    static func write(_ window: Window, _ result: [String: Any], base: Data?, now: Date = Date()) -> Write? {
        var config = window.config
        if let base, let object = JSON.object(base) {
            config.raw = base
            config.object = object
        }
        var documents: [Setting.File: (document: Document, object: [String: Any], backup: [String: Any])] = [.config: (config, config.object, [:])]
        if let presets = window.presets { documents[.presets] = (presets, presets.object, [:]) }
        var storage: [StorageEdit] = []
        for setting in settings {
            guard let place = window.places[setting.name], var entry = documents[setting.file] else { continue }
            let old = value(at: place, in: entry.object)
            guard let new = merged(setting, old, result), digest(new) != old.flatMap(digest) else { continue }
            if let old { entry.backup = Self.setting(place[...], to: old, in: entry.backup) }
            entry.object = Self.setting(place[...], to: new, in: entry.object)
            documents[setting.file] = entry
            if let key = setting.storageKey(at: place), let value = value(at: Array(place.prefix(3)), in: entry.object),
               let text = PinList.storageValue(value, now: now) {
                storage.append(StorageEdit(key: key, json: text))
            }
            if let store = setting.store(in: window.profile), let text = json(new) {
                storage.append(StorageEdit(key: store.key, place: store.place, json: text))
            }
        }
        var write = Write(storage: storage)
        for (file, entry) in documents {
            guard digest(entry.object) != digest(entry.document.object), let contents = serialize(entry.object) else { continue }
            let part = FileWrite(file: entry.document.file, contents: contents, expected: entry.document.raw,
                                 backup: entry.backup.isEmpty ? nil : serialize(entry.backup))
            if file == .config { write.config = part } else { write.presets = part }
        }
        guard write.config != nil || write.presets != nil else { return nil }
        // Read back as the app will, for the next sync to compare against.
        var after = window
        after.config.object = documents[.config]?.object ?? window.config.object
        after.presets?.object = documents[.presets]?.object ?? [:]
        for setting in settings {
            guard let place = window.places[setting.name], let document = after.document(setting) else { continue }
            for (atom, value) in atoms(of: setting, value(at: place, in: document.object)) { write.seen[atom] = digest(value) }
        }
        return write
    }

    /// The value a setting gets: the agreed one, or, for a map, the agreed entries.
    static func merged(_ setting: Setting, _ old: Any?, _ result: [String: Any]) -> Any? {
        let prefix = "\(setting.name):"
        switch setting.kind {
        case .whole:
            return result[setting.name] ?? old
        case .map:
            let map = Dictionary(uniqueKeysWithValues: result.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            return old == nil && map.isEmpty ? nil : map
        }
    }

    /// Makes one localStorage change in a closed window. A store the app hasn't made yet, or one without the
    /// setting's place, is left alone; false only when the database can't be used.
    static func apply(_ edit: StorageEdit, in dataDir: URL) -> Bool {
        guard let place = edit.place else { return ChromiumLocalStorage.set(edit.json, for: edit.key, origin: PinList.origin, in: dataDir) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(edit.json.utf8), options: .fragmentsAllowed) else { return false }
        var missing = false
        let written = ChromiumLocalStorage.update(edit.key, origin: PinList.origin, in: dataDir) { current in
            guard let current, let object = JSON.object(Data(current.utf8)),
                  Self.value(at: Array(place.dropLast()), in: object) is [String: Any] else {
                missing = true
                return nil
            }
            return json(setting(place[...], to: value, in: object))
        }
        return written || missing
    }

    // MARK: New windows

    /// Writes a brand-new window's config before its first launch, with the shared settings of `source` (a
    /// window's data folder) that belong to no account, and its pins when they are shared. Never replaces a file.
    public static func seed(_ dataDir: URL, from source: URL, pins: Bool = true) throws {
        guard let object = document(source.appending(path: "claude_desktop_config.json"))?.object else { return }
        var seeded: [String: Any] = [:]
        // With pin sync, a new window also starts with the source's pins: the app reads them from here while its
        // own storage is still empty. (Afterwards pin sync keeps them the same.)
        let places = settings.filter { $0.file == .config && !$0.place.contains { $0.contains("{") } }.map(\.place)
            + (pins ? [["preferences", "epitaxyPrefs", PinList.starredKey]] : [])
        for place in places {
            if let value = value(at: place, in: object) { seeded = setting(place[...], to: value, in: seeded) }
        }
        guard !seeded.isEmpty, let data = serialize(seeded) else { return }
        try AtomicFile.createExclusively(data, at: dataDir.appending(path: "claude_desktop_config.json"))
    }

    // MARK: JSON

    static func value(at place: [String], in object: [String: Any]) -> Any? {
        var current: Any? = object
        for key in place { current = (current as? [String: Any])?[key] }
        return current
    }

    static func setting(_ place: ArraySlice<String>, to value: Any, in object: [String: Any]) -> [String: Any] {
        guard let key = place.first else { return object }
        var object = object
        object[key] = place.count == 1 ? value : setting(place.dropFirst(), to: value, in: object[key] as? [String: Any] ?? [:])
        return object
    }

    static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// Compact, as the app keeps JSON in localStorage.
    static func json(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Of a value's canonical JSON: values compare by it, and the sync remembers it instead of any key a value holds.
    static func digest(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]))
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}
