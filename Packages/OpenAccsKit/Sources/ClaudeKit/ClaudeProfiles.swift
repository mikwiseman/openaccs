import AppKit
import Foundation
import OpenAccsCore

/// A Claude desktop data folder resolved to the account and org it shows now.
public struct ClaudeProfile: Sendable, Hashable {
    public var dataDir: URL
    /// The default `~/Library/Application Support/Claude`, launched without arguments.
    public var isDefault: Bool
    public var accountUuid: String?
    public var orgUuid: String?
    /// `dataDir/claude-code-sessions/<acct>/<org>`: the Code-tab cards the app loads. nil when unknown.
    public var cardsDir: URL?

    public init(dataDir: URL, isDefault: Bool, accountUuid: String? = nil, orgUuid: String? = nil) {
        self.dataDir = dataDir
        self.isDefault = isDefault
        self.accountUuid = accountUuid
        self.orgUuid = orgUuid
        if let accountUuid, let orgUuid {
            cardsDir = dataDir.appending(path: "claude-code-sessions/\(accountUuid)/\(orgUuid)", directoryHint: .isDirectory)
        }
    }
}

/// A running Claude main process and the data folder it uses.
public struct RunningClaude: Sendable, Hashable {
    public var pid: pid_t
    public var dataDir: URL
}

/// A Claude profile found on disk that the user may want to add.
public struct DiscoveredClaudeProfile: Sendable, Hashable {
    /// nil = the default data folder.
    public var dataDir: String?
    public var label: String
    /// The CLAUDE_CONFIG_DIR the profile used before OpenAccs (context-switcher `cli_config_dir`).
    public var legacyConfigDir: String?
}

public enum ClaudeLaunchError: Error, Equatable, Sendable, LocalizedError {
    /// The profile's data folder may be in use by a Claude process OpenAccs cannot bring forward.
    /// Launching again would put two processes on one folder, so OpenAccs refuses.
    case alreadyRunning
    /// No Claude process for the profile appeared in time.
    case didNotStart

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Claude is already running on this profile"
        case .didNotStart: "Claude didn't start. Try again."
        }
    }
}

/// A Claude.app main process as the system reports it. Injectable so tests never look at real apps.
struct ClaudeProcess: Sendable {
    var pid: pid_t
    /// argv; nil when it could not be read.
    var arguments: [String]?
    var launchDate: Date?

    static func live() -> [ClaudeProcess] {
        NSRunningApplication.runningApplications(withBundleIdentifier: BundleIDs.claude).map { app in
            ClaudeProcess(pid: app.processIdentifier, arguments: ProcessList.arguments(of: app.processIdentifier), launchDate: app.launchDate)
        }
    }
}

/// Starts Claude.app with these arguments; `done` gets the launch error, if any. It may never be called:
/// for a second Claude instance the system can keep the launch pending long after the window is up.
typealias ClaudeLaunch = @Sendable (_ app: URL, _ arguments: [String], _ done: @escaping @Sendable (Error?) -> Void) -> Void

/// Finds, resolves, launches and quits Claude desktop profiles. Never touches a login.
public struct ClaudeProfiles: Sendable {
    public let paths: Paths
    let processes: @Sendable () -> [ClaudeProcess]
    let launch: ClaudeLaunch

    public init(paths: Paths) {
        self.init(paths: paths, processes: ClaudeProcess.live, launch: Self.liveLaunch)
    }

    init(paths: Paths, processes: @escaping @Sendable () -> [ClaudeProcess], launch: @escaping ClaudeLaunch = { _, _, _ in }) {
        self.paths = paths
        self.processes = processes
        self.launch = launch
    }

    static let liveLaunch: ClaudeLaunch = { app, arguments, done in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in done(error) }
    }

    // MARK: Resolve

    /// The folder plus the account and org it shows: the `<acct>/<org>` card folder the app loaded last
    /// (main.log), else the one holding the newest card, else the stored account. Never reads
    /// `config.json`: it holds Claude's login caches.
    public func resolve(_ info: ClaudeAccountInfo) -> ClaudeProfile {
        let dataDir = info.dataDir.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL } ?? paths.claudeDefaultDataDir
        let isDefault = Self.samePath(dataDir, paths.claudeDefaultDataDir)
        if let logged = loggedFolder(dataDir: dataDir) {
            return ClaudeProfile(dataDir: dataDir, isDefault: isDefault, accountUuid: logged.account, orgUuid: logged.org)
        }
        let folders = cardFolders(dataDir: dataDir)
        if let newest = folders.max(by: { ($0.newestCard ?? .distantPast) < ($1.newestCard ?? .distantPast) }), newest.newestCard != nil {
            return ClaudeProfile(dataDir: dataDir, isDefault: isDefault, accountUuid: newest.account, orgUuid: newest.org)
        }
        let account = info.accountUuid.flatMap { FS.isSafeName($0) ? $0 : nil }
        let org = folders.first { $0.account == account }?.org
        return ClaudeProfile(dataDir: dataDir, isDefault: isDefault, accountUuid: account, orgUuid: org)
    }

    /// `<acct>/<org>` of the latest `Loaded N persisted sessions from <dataDir>/claude-code-sessions/<acct>/<org>`
    /// line, newest log first, reading only the last 4 MB of each.
    func loggedFolder(dataDir: URL) -> (account: String, org: String)? {
        let marker = Data("persisted sessions from \(dataDir.path)/claude-code-sessions/".utf8)
        let ends: Set<UInt8> = [0x2F, 0x20, 0x0A, 0x0D, 0x09]  // / space \n \r \t
        for name in ["main.log", "main1.log", "main2.log"] {
            guard let text = Self.tail(of: paths.claudeLogsDir.appending(path: name), bytes: 4 << 20),
                  let hit = text.range(of: marker, options: .backwards) else { continue }
            let account = text[hit.upperBound...].prefix { !ends.contains($0) }
            guard text[account.endIndex...].first == 0x2F else { continue }
            let org = text[(account.endIndex + 1)...].prefix { !ends.contains($0) }
            let (a, o) = (String(decoding: account, as: UTF8.self), String(decoding: org, as: UTF8.self))
            if FS.isSafeName(a) && FS.isSafeName(o) { return (a, o) }
        }
        return nil
    }

    /// Every `<acct>/<org>` folder under `dataDir/claude-code-sessions` in name order, with the
    /// modification date of its newest card.
    func cardFolders(dataDir: URL) -> [(account: String, org: String, newestCard: Date?)] {
        let root = dataDir.appending(path: "claude-code-sessions", directoryHint: .isDirectory)
        var folders: [(account: String, org: String, newestCard: Date?)] = []
        for account in (FS.names(in: root) ?? []).sorted() where FS.isSafeName(account) {
            let accountDir = root.appending(path: account, directoryHint: .isDirectory)
            for org in (FS.names(in: accountDir) ?? []).sorted() where FS.isSafeName(org) {
                let dir = accountDir.appending(path: org, directoryHint: .isDirectory)
                guard let names = FS.names(in: dir) else { continue }
                let newest = names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
                    .compactMap { FS.modificationDate(dir.appending(path: $0)) }.max()
                folders.append((account, org, newest))
            }
        }
        return folders
    }

    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return try? handle.readToEnd()
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: Running

    /// Running Claude main processes mapped to their data folders (no `--user-data-dir` = the default).
    public func running() -> [RunningClaude] {
        processes().compactMap { process in
            guard let args = process.arguments, !Self.isHelper(args) else { return nil }
            return RunningClaude(pid: process.pid, dataDir: dataDir(fromArguments: args))
        }
    }

    /// Main processes keyed by data folder path, or nil when some Claude process could not be mapped
    /// (unreadable argv). Callers that must never touch a running profile treat nil as "maybe running".
    func runningByPath() -> [String: ClaudeProcess]? {
        var result: [String: ClaudeProcess] = [:]
        for process in processes() {
            guard let args = process.arguments else { return nil }
            guard !Self.isHelper(args) else { continue }
            result[dataDir(fromArguments: args).standardizedFileURL.path] = process
        }
        return result
    }

    /// True unless every Claude process could be identified and none uses this profile.
    /// (An unreadable process counts as "maybe this one".)
    public func mayBeRunning(_ profile: ClaudeProfile) -> Bool {
        guard let running = runningByPath() else { return true }
        return running[profile.dataDir.standardizedFileURL.path] != nil
    }

    /// Any process still running from inside the profile's folder, such as its bundled Claude Code CLIs,
    /// which can keep writing transcripts for a moment after the app itself has quit.
    public func hasProcesses(_ profile: ClaudeProfile) -> Bool {
        let root = profile.dataDir.standardizedFileURL.path + "/"
        return ProcessList.all().contains { $0.path.hasPrefix(root) }
    }

    func dataDir(fromArguments args: [String]) -> URL {
        let prefix = "--user-data-dir="
        guard let arg = args.dropFirst().last(where: { $0.hasPrefix(prefix) }) else { return paths.claudeDefaultDataDir }
        var value = String(arg.dropFirst(prefix.count))
        if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
        if value.hasPrefix("~/") { value = paths.home.path + value.dropFirst() }
        guard !value.isEmpty else { return paths.claudeDefaultDataDir }
        return URL(filePath: value, directoryHint: .isDirectory).standardizedFileURL
    }

    static func isHelper(_ args: [String]) -> Bool {
        args.contains { $0.hasPrefix("--type=") }
    }

    // MARK: Discover

    /// The default profile (when its folder exists) plus `~/.context-switcher-claude/profiles/*/desktop-data`.
    public func discover() -> [DiscoveredClaudeProfile] {
        let labels = launcherLabels()
        var result: [DiscoveredClaudeProfile] = []
        if Self.directoryExists(paths.claudeDefaultDataDir) {
            result.append(DiscoveredClaudeProfile(dataDir: nil, label: labels["default"] ?? "Claude", legacyConfigDir: nil))
        }
        let root = paths.contextSwitcherProfilesDir
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            let data = folder.appending(path: "desktop-data", directoryHint: .isDirectory)
            guard Self.directoryExists(data) else { continue }
            let legacy = Self.tomlString(at: folder.appending(path: "profile.toml"), section: "isolation", key: "cli_config_dir")
            result.append(DiscoveredClaudeProfile(dataDir: data.path, label: labels[name] ?? name, legacyConfigDir: legacy))
        }
        return result
    }

    /// Profile folder name → label, from `~/Applications/Claude Profiles/*.app` launchers
    /// (`ClaudeSyncProfile` key, `CFBundleDisplayName` "Claude — <email>").
    func launcherLabels() -> [String: String] {
        let root = paths.claudeProfileLaunchersDir
        var labels: [String: String] = [:]
        for app in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where app.hasSuffix(".app") {
            guard let data = try? Data(contentsOf: root.appending(path: "\(app)/Contents/Info.plist")),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let profile = plist["ClaudeSyncProfile"] as? String else { continue }
            let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? String(app.dropLast(4))
            labels[profile] = Self.label(fromDisplayName: display)
        }
        return labels
    }

    static func label(fromDisplayName name: String) -> String {
        for prefix in ["Claude — ", "Claude – ", "Claude - "] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return name
    }

    /// Reads one string value from a simple TOML file (`[section]` then `key = "value"`).
    static func tomlString(at url: URL, section: String, key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard current == section, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            let string = String(value[value.index(after: value.startIndex)..<end])
            return string.isEmpty ? nil : string
        }
        return nil
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Create, open, quit

    /// A new, empty data folder for a profile: `<appSupport>/Claude/<id>/Data`.
    public func makeProfileDirectory(id: UUID) throws -> URL {
        let dir = paths.claudeProfilesDir.appending(path: "\(id.uuidString)/Data", directoryHint: .isDirectory)
        try FS.makeDirectory(dir)
        return dir
    }

    /// Brings the profile's Claude forward if it runs, otherwise launches a new instance on its folder.
    /// Never launches a second process on a folder that is in use. Returns the pid.
    @MainActor
    public func open(_ profile: ClaudeProfile, timeout: Duration = .seconds(60)) async throws -> pid_t {
        let path = profile.dataDir.standardizedFileURL.path
        guard let running = runningByPath() else { throw ClaudeLaunchError.alreadyRunning }
        if let process = running[path] {
            guard let app = NSRunningApplication(processIdentifier: process.pid) else { throw ClaudeLaunchError.alreadyRunning }
            app.activate()
            return process.pid
        }
        let failure = LaunchFailure()
        launch(paths.claudeApp, launchArguments(for: profile)) { failure.error = $0 }
        // Opened = its process is there, not when the launch reports back (that can stay pending).
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let error = failure.error { throw error }
            if let pid = runningByPath()?[path]?.pid { return pid }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ClaudeLaunchError.didNotStart
    }

    /// No arguments for the default profile; `--user-data-dir=<path>` for every other one.
    /// CLAUDE_CONFIG_DIR is never set, so every profile shares `~/.claude`.
    func launchArguments(for profile: ClaudeProfile) -> [String] {
        profile.isDefault ? [] : ["--user-data-dir=\(profile.dataDir.standardizedFileURL.path)"]
    }

    /// Asks the profile's Claude to quit and waits until it is gone. True when it is not running.
    @MainActor
    public func quit(_ profile: ClaudeProfile, timeout: Duration) async -> Bool {
        guard let running = runningByPath() else { return false }
        guard let pid = running[profile.dataDir.standardizedFileURL.path]?.pid else { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return !ProcessList.isAlive(pid) }
        app.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if app.isTerminated || !ProcessList.isAlive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return app.isTerminated || !ProcessList.isAlive(pid)
    }
}

/// The launch error, set from whatever thread the system calls back on.
private final class LaunchFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    var error: Error? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
