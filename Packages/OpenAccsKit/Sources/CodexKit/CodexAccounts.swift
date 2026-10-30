import CryptoKit
import Darwin
import Foundation
import OpenAccsCore

/// Codex sign-ins. Each account has a Keychain vault slot and may own a desktop profile's auth.json.
/// The original app and terminal keep ~/.codex/auth.json. Only parked vault copies are refreshed by
/// OpenAccs; a native profile owns its token lifecycle. Opening another account never swaps logins.
public actor CodexAccounts {
    private let paths: Paths
    private let secrets: SecretStore
    private let http: HTTPClient
    private let app: any CodexAppControl
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var signingIn = false

    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// `app` defaults to the real Codex app; tests pass a fake.
    public init(paths: Paths, secrets: SecretStore, http: HTTPClient = URLSessionHTTPClient(), app: (any CodexAppControl)? = nil) {
        self.paths = paths
        self.secrets = secrets
        self.http = http
        self.app = app ?? CodexApp(paths: paths)
    }

    public func liveIdentity() -> CodexAccountInfo? {
        if case .login(let info, _) = live() { info } else { nil }
    }

    /// Saves the live auth.json into its vault slot when the bytes changed. nil when nobody is signed in.
    @discardableResult
    public func checkIn() throws -> CodexAccountInfo? {
        guard case .login(let info, let data) = live() else { return nil }
        if try secrets.read(info.vaultKey) != data { try secrets.write(data, for: info.vaultKey) }
        return info
    }

    /// Stable homes for account credentials and desktop preferences.
    public nonisolated func profileHome(_ info: CodexAccountInfo) -> URL {
        let key = SHA256.hash(data: Data("\(info.userId)\u{0}\(info.accountId)".utf8)).map { String(format: "%02x", $0) }.joined()
        // macOS Unix socket paths are limited to 104 bytes; Codex puts sockets below this home.
        return paths.home.appending(path: ".openaccs/codex/\(key.prefix(16))/Home", directoryHint: .isDirectory)
    }

    public func processID(_ info: CodexAccountInfo) -> Int32? {
        if liveIdentity()?.isSameLogin(as: info) == true, let pid = app.processID(home: nil) { return pid }
        let home = profileHome(info)
        guard identity(at: home)?.isSameLogin(as: info) == true else { return nil }
        return app.processID(home: home)
    }

    /// Opens a dedicated profile without changing or restarting any other Codex instance.
    public func open(_ info: CodexAccountInfo, activate: Bool = true) async throws -> Int32 {
        await lock()
        defer { unlock() }
        if liveIdentity()?.isSameLogin(as: info) == true {
            return try await app.open(home: nil, activate: activate)
        }
        let home = profileHome(info), file = home.appending(path: "auth.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            let found = identity(at: home)
            guard found?.isSameLogin(as: info) == true else { throw CodexError.verifyFailed(found: found?.email) }
            let data = try Data(contentsOf: file)
            if try secrets.read(info.vaultKey) != data { try secrets.write(data, for: info.vaultKey) }
        } else {
            guard app.processID(home: home) == nil else { throw CodexError.unsavedSignIn }
            guard let data = try secrets.read(info.vaultKey), CodexAuthFile.identity(of: data)?.isSameLogin(as: info) == true else {
                throw CodexError.noSavedSignIn
            }
            let sharedConfig = paths.codexHome.appending(path: "config.toml")
            let config = try? String(contentsOf: sharedConfig, encoding: .utf8)
            try preflight()
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AtomicFile.write(data, to: file, permissions: 0o600)
            // Share authored setup; credentials and browser data belong to this account.
            for name in ["AGENTS.md", "skills"] {
                let source = paths.codexHome.appending(path: name), destination = home.appending(path: name)
                if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) {
                    try fm.createSymbolicLink(at: destination, withDestinationURL: source)
                }
            }
            if config != nil {
                try fm.createSymbolicLink(at: home.appending(path: "config.toml"), withDestinationURL: sharedConfig)
            } else {
                try AtomicFile.write(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: home.appending(path: "config.toml"), permissions: 0o600)
            }
        }
        if app.processID(home: home) != nil { return try await app.open(home: home, activate: activate) }
        // Native SQLite state is shared through CODEX_SQLITE_HOME. Share its supporting files
        // and writer locks as directories, never symlink individual SQLite/WAL files.
        for name in ["sessions", "archived_sessions", "thread-writer-locks", "memories", "memories_v2", "attachments"] {
            let source = paths.codexHome.appending(path: name), destination = home.appending(path: name)
            try fm.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if destination.resolvingSymlinksInPath().standardizedFileURL == source.standardizedFileURL { continue }
            // Never replace a pre-existing private history directory.
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
        }
        try prepareProjectSidebar(in: home)
        return try await app.open(home: home, activate: activate)
    }

    /// The desktop still caches project folders outside SQLite. Seed a new sidebar once;
    /// never overwrite projects or preferences subsequently edited in that profile.
    private func prepareProjectSidebar(in home: URL) throws {
        let name = ".codex-global-state.json"
        guard let data = try? Data(contentsOf: paths.codexHome.appending(path: name)), let shared = JSON.object(data) else { return }
        let destination = home.appending(path: name)
        var state: [String: Any]
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let existing = JSON.object(try Data(contentsOf: destination)) else { throw CocoaError(.fileReadCorruptFile) }
            state = existing
        } else { state = [:] }
        guard state["openaccs-project-sidebar-imported"] as? Bool != true else { return }
        for key in ["local-projects", "project-order", "project-appearances", "pinned-project-ids", "thread-project-assignments", "sidebar-project-thread-orders", "thread-workspace-root-hints", "electron-saved-workspace-roots"] {
            if let incoming = shared[key] as? [String: Any] {
                state[key] = incoming.merging(state[key] as? [String: Any] ?? [:]) { _, existing in existing }
            } else if let incoming = shared[key] as? [String] {
                state[key] = incoming + (state[key] as? [String] ?? []).filter { !incoming.contains($0) }
            }
        }
        let sourceIdentity = "local:\(paths.codexHome.path)", destinationIdentity = "local:\(home.path)"
        for key in ["app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host"] {
            guard let value = (shared[key] as? [String: Any])?[sourceIdentity] else { continue }
            var values = state[key] as? [String: Any] ?? [:]
            values[destinationIdentity] = value
            state[key] = values
        }
        state["openaccs-project-sidebar-imported"] = true
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), to: destination, permissions: 0o600)
    }

    private func identity(at home: URL) -> CodexAccountInfo? {
        (try? Data(contentsOf: home.appending(path: "auth.json"))).flatMap(CodexAuthFile.identity)
    }

    /// A managed profile owns its refresh token even while closed. Never rotate a stale vault copy.
    private func profileLogin(_ info: CodexAccountInfo) throws -> Data? {
        let file = profileHome(info).appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file), CodexAuthFile.identity(of: data)?.isSameLogin(as: info) == true else {
            throw UsageError.needsSignIn
        }
        return data
    }

    public func hasVaultCopy(_ info: CodexAccountInfo) -> Bool {
        (try? secrets.read(info.vaultKey)) != nil
    }

    /// Quit Codex → check in the live login → swap in the target → restart the daemon → relaunch → verify.
    public func switchTo(_ target: CodexAccountInfo) async throws {
        await lock()
        defer { unlock() }
        try preflight()
        let current = live()
        if case .login(let info, _) = current, info.isSameLogin(as: target) { return try await app.launch() }
        guard hasVaultCopy(target) else { throw CodexError.noSavedSignIn }
        if case .unreadable = current { throw CodexError.unsavedSignIn }

        if app.isRunning(), await !app.quit(timeout: .seconds(30)) { throw CodexError.appStillRunning }
        if case .unreadable = live() { throw CodexError.unsavedSignIn }
        try checkIn()
        guard let bytes = try secrets.read(target.vaultKey),
              CodexAuthFile.identity(of: bytes)?.isSameLogin(as: target) == true
        else { throw CodexError.noSavedSignIn }
        try AtomicFile.write(bytes, to: paths.codexAuthFile, permissions: 0o600)

        var daemonError: Error?
        if daemonIsRunning() {
            do { try await app.restartDaemon() } catch { daemonError = error }
        }
        try await app.launch()
        let now = liveIdentity()
        guard now?.isSameLogin(as: target) == true else { throw CodexError.verifyFailed(found: now?.email) }
        if let daemonError { throw CodexError.daemonRestartFailed(daemonError.localizedDescription) }
    }

    /// Runs `codex login` in a private CODEX_HOME, so the live login is never touched, and vaults the result.
    public func addAccount() async throws -> CodexAccountInfo {
        guard !signingIn else { throw CodexError.signInInProgress }
        signingIn = true
        defer { signingIn = false }
        let fm = FileManager.default
        let home = paths.appSupport.appending(path: "CodexLogin", directoryHint: .isDirectory)
        try? fm.removeItem(at: home)
        try fm.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: home) }

        try await app.login(codexHome: home, timeout: .seconds(600))
        guard let data = try? Data(contentsOf: home.appending(path: "auth.json")),
              let info = CodexAuthFile.identity(of: data)
        else { throw CodexError.signInFailed }
        await lock()
        defer { unlock() }
        let profile = profileHome(info)
        if app.processID(home: profile) == nil, identity(at: profile)?.isSameLogin(as: info) == true {
            // An explicit new login renews a closed profile. A running app still owns its sign-in.
            try AtomicFile.write(data, to: profile.appending(path: "auth.json"), permissions: 0o600)
        }
        try secrets.write(data, for: info.vaultKey)
        return info
    }

    /// Limits from wham/usage. The live login is read from `~/.codex/auth.json` and never refreshed;
    /// a parked login is refreshed once when its access token is about to expire or is rejected.
    /// `refresh: false` never rotates tokens: such a parked login fails with "Not refreshed" instead.
    public func usage(_ info: CodexAccountInfo, refresh: Bool = true) async throws -> UsageSnapshot {
        if case .login(let liveInfo, let data) = live(), liveInfo.isSameLogin(as: info) {
            guard let token = CodexAuthFile.accessToken(of: data) else { throw UsageError.needsSignIn }
            if let exp = JWT.expiry(token), exp < Date() { throw UsageError.unexpected("Open Codex to renew its sign-in") }
            let (status, body) = try await fetchUsage(data, info)
            if status == 401 { throw UsageError.needsSignIn }
            return try Self.snapshot(status, body)
        }

        if let data = try profileLogin(info) {
            let (status, body) = try await fetchUsage(data, info)
            if status == 401 { throw UsageError.unexpected("Open this Codex account to renew its sign-in") }
            return try Self.snapshot(status, body)
        }
        guard var data = try secrets.read(info.vaultKey) else { throw UsageError.notConnected }
        let notRefreshed = UsageError.unexpected("Not refreshed")
        var refreshed = false
        if Self.expiresSoon(data) {
            guard refresh else { throw notRefreshed }
            data = try await refreshParked(info, from: data)
            refreshed = true
        }
        var (status, body) = try await fetchUsage(data, info)
        if status == 401, !refreshed {
            guard refresh else { throw notRefreshed }
            data = try await refreshParked(info, from: data)
            (status, body) = try await fetchUsage(data, info)
        }
        if status == 401 { throw UsageError.needsSignIn }
        return try Self.snapshot(status, body)
    }

    /// Deletes the vault copy only. Never logs out (that would revoke the login everywhere).
    public func forget(_ info: CodexAccountInfo) throws {
        try secrets.delete(info.vaultKey)
    }

    /// `codex` processes the Codex app didn't start (terminal, IDE, other tools, ChatGPT.app's bundled CLI run from
    /// a terminal). They keep their login in memory and don't follow a switch. The shared app-server daemon and its
    /// updater aren't holders: a switch restarts the daemon.
    public func otherHolders() -> [ProcessList.Entry] {
        otherHolders(among: ProcessList.all(), parent: { ProcessList.parent(of: $0) })
    }

    /// Tests pass a fake process table.
    func otherHolders(among processes: [ProcessList.Entry], parent: @Sendable (pid_t) -> pid_t?) -> [ProcessList.Entry] {
        let bundle = Self.bundlePrefix(paths.codexApp)
        let appMain = bundle + "Contents/MacOS/ChatGPT"
        let pathOf = Dictionary(processes.map { ($0.pid, $0.path) }, uniquingKeysWith: { first, _ in first })
        let daemons = Set(["daemon.pid", "daemon-updater.pid"].compactMap { daemonPid($0) })
        return processes.filter { process in
            guard Self.isCodex(process.path), !daemons.contains(process.pid) else { return false }
            guard process.path.hasPrefix(bundle) else { return true }
            var pid = process.pid
            for _ in 0..<12 {
                guard let up = parent(pid), up > 1 else { return true }
                if pathOf[up] == appMain { return false }
                pid = up
            }
            return true
        }
    }

    // MARK: - Live file

    private enum Live {
        case none
        case unreadable
        case login(CodexAccountInfo, Data)
    }

    /// The live auth.json. Codex rewrites it in place, so a read that doesn't parse is retried.
    private func live() -> Live {
        for attempt in 0...3 {
            guard let data = try? Data(contentsOf: paths.codexAuthFile) else {
                return FileManager.default.fileExists(atPath: paths.codexAuthFile.path) ? .unreadable : .none
            }
            if JSON.object(data) != nil {
                return CodexAuthFile.identity(of: data).map { .login($0, data) } ?? .unreadable
            }
            if attempt < 3 { usleep(150_000) }
        }
        return .unreadable
    }

    private func preflight() throws {
        let config = paths.codexHome.appending(path: "config.toml")
        if let toml = try? String(contentsOf: config, encoding: .utf8), Self.storesCredentialsInKeychain(toml) {
            throw CodexError.keychainCredentials
        }
        if FileManager.default.fileExists(atPath: paths.codexHome.appending(path: "secrets").path) {
            throw CodexError.encryptedCredentials
        }
    }

    private func daemonIsRunning() -> Bool { daemonPid("daemon.pid") != nil }

    /// The live pid recorded in `~/.codex/app-server-daemon/<file>`.
    private func daemonPid(_ file: String) -> pid_t? {
        (try? Data(contentsOf: paths.codexHome.appending(path: "app-server-daemon/\(file)"))).flatMap { Self.livePid(pidFile: $0) }
    }

    // MARK: - Network

    private func fetchUsage(_ data: Data, _ info: CodexAccountInfo) async throws -> (Int, Data) {
        guard let token = CodexAuthFile.accessToken(of: data) else { throw UsageError.needsSignIn }
        let (body, response) = try await http.send(CodexUsage.request(accessToken: token, accountId: info.accountId))
        return (response.statusCode, body)
    }

    /// Refreshes a parked login and stores the merged auth.json back in its slot before it is used.
    /// Serialized with switches, so a login is never refreshed while it is being checked out.
    private func refreshParked(_ info: CodexAccountInfo, from used: Data) async throws -> Data {
        await lock()
        defer { unlock() }
        if let data = try profileLogin(info) { return data }
        switch live() {
        case .login(let liveInfo, _) where liveInfo.isSameLogin(as: info):
            throw UsageError.unexpected("Codex is using this account now")
        case .unreadable:
            throw UsageError.unexpected("Codex sign-in file is busy; try again")
        default:
            break
        }
        guard let current = try secrets.read(info.vaultKey) else { throw UsageError.notConnected }
        if current != used { return current }  // someone refreshed or checked in while we waited
        guard let refreshToken = CodexAuthFile.refreshToken(of: current) else { throw UsageError.needsSignIn }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refreshToken,
        ])
        let (body, response) = try await http.send(request)
        guard response.statusCode == 200, let answer = JSON.object(body) else {
            if Self.isPermanentRefreshFailure(status: response.statusCode, body: body) { throw UsageError.needsSignIn }
            throw UsageError.unexpected("Token refresh failed (HTTP \(response.statusCode))")
        }
        guard let merged = CodexAuthFile.merging(current, refreshed: answer, at: Date()),
              CodexAuthFile.identity(of: merged)?.isSameLogin(as: info) == true
        else { throw UsageError.unexpected("Unexpected token refresh answer") }
        // Keep whatever replaced the slot meanwhile (a check-in or forget wins).
        if try secrets.read(info.vaultKey) == current { try secrets.write(merged, for: info.vaultKey) }
        return merged
    }

    // MARK: - Lock

    private func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Pure helpers

    static func snapshot(_ status: Int, _ body: Data) throws -> UsageSnapshot {
        guard status == 200 else { throw UsageError.unexpected("ChatGPT usage: HTTP \(status)") }
        return try CodexUsage.parse(body)
    }

    /// No access token, or one that expires within 5 minutes.
    static func expiresSoon(_ authJSON: Data, now: Date = Date()) -> Bool {
        guard let token = CodexAuthFile.accessToken(of: authJSON) else { return true }
        guard let exp = JWT.expiry(token) else { return false }
        return exp < now.addingTimeInterval(300)
    }

    /// refresh_token_expired/reused/invalidated, any 401, or 400 invalid_grant.
    static func isPermanentRefreshFailure(status: Int, body: Data) -> Bool {
        let root = JSON.object(body) ?? [:]
        let code = (text(root["error"]) ?? text((root["error"] as? [String: Any])?["code"]) ?? text(root["code"]))?.lowercased()
        if status == 401 { return true }
        if status == 400, code == "invalid_grant" { return true }
        return ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code ?? "")
    }

    /// True when config.toml moves Codex credentials to the keychain (`cli_auth_credentials_store` keyring/auto).
    static func storesCredentialsInKeychain(_ toml: String) -> Bool {
        toml.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store" else { return false }
            let value = parts[1].split(separator: "#").first?
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            return value == "keyring" || value == "auto"
        }
    }

    /// daemon.pid / daemon-updater.pid is `{"pid": N, "processIdentity": {"startSeconds": S}, …}` (or a bare pid).
    /// The pid when it runs and, when recorded, started at that second (so a reused pid doesn't count).
    static func livePid(pidFile: Data) -> pid_t? {
        let root = JSON.object(pidFile)
        let bare = String(decoding: pidFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = JSON.double(root?["pid"]) ?? Double(bare), value > 0, value < Double(Int32.max),
              case let pid = pid_t(value), ProcessList.isAlive(pid)
        else { return nil }
        guard let start = JSON.double((root?["processIdentity"] as? [String: Any])?["startSeconds"]) else { return pid }
        return startSeconds(of: pid) == Int(start) ? pid : nil
    }

    static func startSeconds(of pid: pid_t) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int(info.pbi_start_tvsec)
    }

    /// Path prefix of every process from the app bundle ("/Applications/ChatGPT.app/").
    static func bundlePrefix(_ app: URL) -> String {
        let path = app.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// A `codex` executable, or anything in a CodexCLI.app.
    static func isCodex(_ path: String) -> Bool {
        path.split(separator: "/").last == "codex" || path.contains("/CodexCLI.app/")
    }
}

public enum CodexError: Error, Equatable, Sendable, LocalizedError {
    /// config.toml sets `cli_auth_credentials_store` to keyring/auto.
    case keychainCredentials
    /// `~/.codex/secrets` exists (encrypted credential store).
    case encryptedCredentials
    case noSavedSignIn
    case appStillRunning
    /// The live auth.json can't be identified, so it can't be saved before a swap.
    case unsavedSignIn
    case verifyFailed(found: String?)
    case daemonRestartFailed(String)
    case signInInProgress
    case signInFailed

    public var errorDescription: String? {
        switch self {
        case .keychainCredentials:
            "Codex keeps its sign-in in the keychain (cli_auth_credentials_store in ~/.codex/config.toml). OpenAccs only switches file sign-ins."
        case .encryptedCredentials:
            "Codex keeps its sign-in encrypted in ~/.codex/secrets. OpenAccs only switches file sign-ins."
        case .noSavedSignIn:
            "OpenAccs has no saved sign-in for this account. Add it again."
        case .appStillRunning:
            "Codex didn't quit within 30 seconds (an open window, a running task, or a codex from ChatGPT.app in Terminal). Nothing was changed."
        case .unsavedSignIn:
            "OpenAccs can't read the current Codex sign-in to save it, so it didn't switch. Nothing was changed."
        case .verifyFailed(let found):
            "Codex came back signed in as \(found ?? "someone else"), not the chosen account."
        case .daemonRestartFailed(let message):
            "Switched, but the Codex background server didn't restart: \(message)"
        case .signInInProgress:
            "A Codex sign-in is already open."
        case .signInFailed:
            "Codex sign-in didn't finish."
        }
    }
}
