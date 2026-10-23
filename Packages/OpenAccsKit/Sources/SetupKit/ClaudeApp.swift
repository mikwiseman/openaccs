import Foundation
import OpenAccsCore

/// The Claude desktop app's own settings. Each profile keeps them in `<dataDir>/claude_desktop_config.json`, next
/// to things that belong to that profile alone (consents, pins, window state). An allowlist of them is made the
/// same in every profile: some preferences, the folder permission modes of each profile's own account, and the
/// desktop chat MCP servers (copied only between profiles on this Mac).
///
/// Merged three-way per setting against the last sync: a profile whose value differs from what it held then
/// changed it, and the newest change wins (by the file's date); otherwise the agreed value stays. Before any
/// sync, the profile used last wins and settings only others have are added. A setting a profile lacks never
/// counts as a change, so nothing is removed. A running app saves its copy from memory over the file, so a
/// profile is written only while its app is closed.
public enum ClaudeAppSetup {
    /// The shared settings, by their place in the file. None is a consent, opt-in, gate, seen, nudge, ack, intro,
    /// onboarding or count flag: OpenAccs never agrees to anything on the user's behalf. Pins
    /// (`starred-local-code-sessions`, `dframe-local-slice`) are not here either: ClaudeKit syncs them.
    static let shared: [[String]] = [
        "bypassPermissionsModeEnabled", "allowAllBrowserActions", "chicagoEnabled", "ccRemoteControlDefaultEnabled",
        "dispatchCodeTasksPermissionMode", "menuBarEnabled", "dockBounceEnabled", "ccdScheduledTasksEnabled", "sidebarMode",
        "coworkBrowserToolsEnabled", "coworkPreferredBrowser", "coworkWebSearchEnabled", "coworkScheduledTasksEnabled",
    ].map { ["preferences", $0] }
        + ["fastMode", "cc-landing-draft-permission-mode"].map { ["preferences", "epitaxyPrefs", $0] }
        + [["mcpServers"]]
    /// Folder permission modes (folder → mode). The app keeps them per account as `…-v2.<accountUuid>`, so each
    /// profile gets them under its own account, and a profile whose account is unknown is left out.
    static let folderModes = ["preferences", "epitaxyPrefs", "epitaxy-folder-permission-mode-v2"]
    static let all = shared + [folderModes]

    public static func scan(_ context: SetupContext) -> AreaReport {
        let accounts = (try? AccountStore(file: context.paths.accountsFile).load()) ?? []
        let profiles = context.claudeProfiles.compactMap { read($0, name: name(of: $0, in: accounts, context: context)) }
        let records = Self.records(context)
        let result = merge(profiles, records: records)
        let agreement = result.mapValues(\.value.digest)

        let now = Date()
        var changes: [SetupChange] = []
        var carried: [FileOperation] = []
        var differing: [String: Int] = [:]
        for profile in profiles {
            let path = profile.ref.dataDir.path
            let mine = all.filter { keyPath($0, profile.ref) != nil }.map(Self.key)
            let differ = mine.filter { key in result[key].map { $0.value.digest != profile.values[key]?.digest } ?? false }
            let waits = !differ.isEmpty && context.isRunning(.claude(path))
            // What it holds after this sync. One whose write waits for its app keeps what it holds now, so what the
            // user changes there meanwhile still counts as a change, and what the app saves on quit doesn't.
            let holds = waits ? profile.values.mapValues(\.digest) : agreement.filter { mine.contains($0.key) }
            let record = Record(dataDir: path, date: now, agreed: agreement, seen: holds)
            let recordFile = Self.recordFile(profile.ref.dataDir, context)
            guard let recordData = try? JSON.encoder.encode(record) else { continue }
            let writeRecord = FileOperation.write(path: recordFile.path, contents: recordData, expected: FileState.of(recordFile))
            let recordIsNew = records[path].map { $0.agreed != record.agreed || $0.seen != record.seen } ?? true
            if (differ.isEmpty || waits), recordIsNew { carried.append(writeRecord) }
            if differ.isEmpty { continue }

            var object = profile.object
            for key in differ {
                guard let setting = all.first(where: { Self.key($0) == key }), let place = keyPath(setting, profile.ref),
                      let value = result[key]?.value.value else { continue }
                object = Self.setting(place[...], to: value, in: object)
            }
            guard let contents = serialize(object) else { continue }
            let sources = profiles.filter { source in differ.contains { result[$0]?.from == source.ref } }.map(\.name)
            differing[path] = differ.count
            changes.append(SetupChange(
                id: "claudeApp.\(path)", area: .claudeApp,
                title: "\(profile.name) gets \(count(differ.count, "setting")) from \(sources.formatted(.list(type: .and).locale(Locale(identifier: "en"))))",
                detail: "Sets \(differ.joined(separator: ", ")). Everything else in its claude_desktop_config.json stays as it is.",
                operations: [.write(path: profile.file.path, contents: contents, expected: profile.state)] + (waits ? [] : [writeRecord]),
                waitsFor: .claude(path)))
        }
        // Records of profiles that aren't written now (one file each, so only one change may carry them), in a change
        // that need not wait for an app if there is one.
        if !carried.isEmpty, !changes.isEmpty {
            let carrier = changes.firstIndex { $0.waitsFor.map { !context.isRunning($0) } ?? true } ?? 0
            changes[carrier].operations += carried
        }

        let items = context.claudeProfiles.map { ref -> SetupItem in
            let name = Self.name(of: ref, in: accounts, context: context)
            guard profiles.contains(where: { $0.ref == ref }) else {
                let exists = FileManager.default.fileExists(atPath: configFile(ref.dataDir).path)
                return SetupItem(id: ref.dataDir.path, name: name, claude: .missing, codex: .notShared,
                                 note: exists ? "Its settings file can't be read" : "No settings file yet")
            }
            guard let n = differing[ref.dataDir.path] else { return SetupItem(id: ref.dataDir.path, name: name, claude: .same, codex: .notShared) }
            return SetupItem(id: ref.dataDir.path, name: name, claude: context.isRunning(.claude(ref.dataDir.path)) ? .waiting : .differs,
                             codex: .notShared, note: n == 1 ? "1 setting differs" : "\(n) settings differ")
        }
        let summary = switch (profiles.count, changes.count) {
        case (0, _): "No Claude app settings found"
        case (1, 0): "1 profile · \(count(result.count, "setting"))"
        case (let n, 0): "Same in \(n) profiles · \(count(result.count, "setting"))"
        case (let n, 1): "\(count(n, "profile")) · 1 differs"
        case (let n, let d): "\(count(n, "profile")) · \(d) differ"
        }
        return AreaReport(area: .claudeApp, summary: summary, changes: changes, items: items)
    }

    /// Writes a brand-new profile's settings file before its first launch, with the shared settings of `source`
    /// (a profile's data folder) that belong to no account, MCP servers included. Never replaces a file.
    public static func seed(_ dataDir: URL, from source: URL) throws {
        guard let raw = try? Data(contentsOf: configFile(source)), let object = JSON.object(raw) else { return }
        var seeded: [String: Any] = [:]
        for place in shared {
            if let value = Self.value(at: place, in: object) { seeded = Self.setting(place[...], to: value, in: seeded) }
        }
        guard !seeded.isEmpty, let data = serialize(seeded) else { return }
        try AtomicFile.createExclusively(data, at: configFile(dataDir))
    }

    // MARK: Merging

    /// The value each setting should have in every profile, and the profile it comes from.
    static func merge(_ profiles: [Profile], records: [String: Record]) -> [String: (value: Value, from: ClaudeProfileRef)] {
        // Every record one sync writes carries its agreement, so the newest record has the last one.
        let agreed = records.values.max { $0.date < $1.date }?.agreed ?? [:]
        var result: [String: (value: Value, from: ClaudeProfileRef)] = [:]
        for key in all.map(Self.key) {
            let holders = profiles.filter { $0.values[key] != nil }
            // Changed since the last sync: it holds neither what it held then nor what was agreed.
            let changed = holders.filter { profile in
                guard let seen = records[profile.ref.dataDir.path]?.seen[key], let now = profile.values[key]?.digest else { return false }
                return now != seen && now != agreed[key]
            }
            let pick = changed.max { $0.modified < $1.modified }
                ?? holders.first { $0.values[key]?.digest == agreed[key] }
                ?? holders.first
            if let pick, let value = pick.values[key] { result[key] = (value, pick.ref) }
        }
        return result
    }

    // MARK: Reading

    struct Value {
        var value: Any
        /// Of its canonical JSON, to compare values and to remember them without keeping any key they hold.
        var digest: String
    }

    struct Profile {
        var ref: ClaudeProfileRef
        var name: String
        var file: URL
        var object: [String: Any]
        var state: FileState
        var modified: Date
        /// Setting (the last part of its place) → value, for the shared settings it has.
        var values: [String: Value]
    }

    /// One profile's part of the last sync (setting → digest): what all profiles agreed on and what this one held
    /// after it. One file per profile, written in the same change as its settings file, so the changes for
    /// several profiles apply on their own.
    struct Record: Codable {
        var dataDir: String
        var date: Date
        var agreed: [String: String]
        var seen: [String: String]
    }

    static func configFile(_ dataDir: URL) -> URL { dataDir.appending(path: "claude_desktop_config.json") }

    static func recordFile(_ dataDir: URL, _ context: SetupContext) -> URL {
        context.paths.appSupport.appending(path: "setup-claude-app/\(Digest.sha256(Data(dataDir.path.utf8)).prefix(16)).json")
    }

    static func records(_ context: SetupContext) -> [String: Record] {
        let dir = context.paths.appSupport.appending(path: "setup-claude-app", directoryHint: .isDirectory)
        var records: [String: Record] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? JSON.decoder.decode(Record.self, from: data) { records[record.dataDir] = record }
        }
        return records
    }

    /// nil when the profile has no settings file yet (Claude makes it at first launch) or it isn't a JSON object.
    static func read(_ ref: ClaudeProfileRef, name: String) -> Profile? {
        let file = configFile(ref.dataDir)
        guard let raw = try? Data(contentsOf: file), let object = JSON.object(raw) else { return nil }
        var values: [String: Value] = [:]
        for setting in all {
            guard let place = keyPath(setting, ref), let value = Self.value(at: place, in: object), let digest = Self.digest(value) else { continue }
            values[Self.key(setting)] = Value(value: value, digest: digest)
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Profile(ref: ref, name: name, file: file, object: object, state: .file(sha256: Digest.sha256(raw)), modified: modified, values: values)
    }

    /// The profile's name in OpenAccs, else its folder's name.
    static func name(of ref: ClaudeProfileRef, in accounts: [Account], context: SetupContext) -> String {
        let account = accounts.first { account in
            guard account.provider == .claude else { return false }
            let dir = account.claude?.dataDir.map { URL(filePath: $0) } ?? context.paths.claudeDefaultDataDir
            return dir.standardizedFileURL.path == ref.dataDir.path
        }
        return account?.label ?? ref.dataDir.lastPathComponent
    }

    /// A setting's name: the last part of its place, without any account.
    static func key(_ setting: [String]) -> String { setting.last ?? "" }

    /// Where a setting is in this profile's file; nil for folder modes while its account is unknown.
    static func keyPath(_ setting: [String], _ ref: ClaudeProfileRef) -> [String]? {
        guard setting == folderModes else { return setting }
        return ref.accountUuid.map { setting.dropLast() + ["\(Self.key(setting)).\($0)"] }
    }

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

    // MARK: Writing

    /// Sorted, two-space indented JSON. Every value the app wrote stays the same; only the layout changes.
    static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func digest(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])).map(Digest.sha256)
    }

    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}
