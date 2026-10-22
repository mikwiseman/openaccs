import AppKit
import ServiceManagement
import SwiftUI
import ClaudeKit
import CodexKit
import LimitsKit
import OpenAccsCore

/// The real model: accounts on disk, live usage, Claude profiles and history sync, Codex switching.
@MainActor @Observable
final class AppModel: PanelModel {
    private(set) var rows: [PanelRow] = []
    private(set) var menuBarUsage: UsageSnapshot?
    private(set) var isRefreshing = false
    private(set) var grokBotAccounts: [String] = []
    private(set) var notice: String?
    /// First load finished (snapshot mode waits for it).
    private(set) var isReady = false

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: Dependencies

    private let paths = Paths.current
    /// A test home (Debug, OPENACCS_HOME) keeps its own Keychain items and preferences.
    private let secrets: SecretStore = KeychainSecretStore(service: Paths.isOverridden ? "is.wai.openaccs.test" : "is.wai.openaccs")
    private let defaults = Paths.isOverridden ? UserDefaults(suiteName: "is.wai.openaccs.test") ?? .standard : .standard
    private let http: HTTPClient = URLSessionHTTPClient()
    private let store: AccountStore
    private let claude: ClaudeProfiles
    private let sync: CardSync
    private let claudeCLI: ClaudeCodeCLI
    private let codex: CodexAccounts
    private let codexApp: CodexApp
    private let zai: ZaiUsage
    private let kimi: KimiUsage
    private let grokBot: GrokBotUsage
    private let grokCLI: GrokCLI
    /// Snapshot mode: read everything, write nothing, start nothing.
    private let readOnly: Bool

    // MARK: State

    private var accounts: [Account] = []
    private var usage: [UUID: UsageSnapshot] = [:]
    private var problems: [UUID: UsageError] = [:]
    private var runningClaude: [String: pid_t] = [:]
    private var pending: [UUID: Pending] = [:]
    /// The account each Claude profile's app loaded last, as Claude's log says.
    private var shownAccount: [UUID: String] = [:]
    private var liveCodex: CodexAccountInfo?
    private var lastFetch: [UUID: Date] = [:]
    private var codexAuthDate: Date?
    private var syncTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var observers: [NSObjectProtocol] = []
    /// accounts.json exists but couldn't be read: never save over it this run.
    private var storeBroken = false
    /// Profiles (data folder paths) with an open/restart/add in flight: one at a time, never two launches.
    private var claudeBusy: Set<String> = []
    private var syncRun: Task<Void, Never>?
    /// Profiles `openClaude` is preparing; their sync may migrate them although they are "busy".
    private var openingNow: Set<UUID> = []
    /// The live Codex login the user removed from OpenAccs; not re-added until Codex signs in elsewhere.
    private var dismissedCodex: String? {
        get { defaults.string(forKey: "dismissedCodex") }
        set { defaults.set(newValue, forKey: "dismissedCodex") }
    }
    private var lastClaude: UUID? {
        didSet { defaults.set(lastClaude?.uuidString, forKey: "lastClaude") }
    }

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        store = AccountStore(file: paths.accountsFile)
        claude = ClaudeProfiles(paths: paths)
        sync = CardSync(paths: paths)
        claudeCLI = ClaudeCodeCLI(paths: paths)
        codexApp = CodexApp(paths: paths)
        codex = CodexAccounts(paths: paths, secrets: secrets, http: http, app: codexApp)
        zai = ZaiUsage(http: http)
        kimi = KimiUsage(http: http)
        grokBot = GrokBotUsage(paths: paths)
        grokCLI = GrokCLI(paths: paths)
        lastClaude = defaults.string(forKey: "lastClaude").flatMap(UUID.init)
        Task { await start() }
    }

    // MARK: Lifecycle

    private func start() async {
        let firstRun = !FileManager.default.fileExists(atPath: paths.accountsFile.path)
        do {
            accounts = try store.load()
        } catch {
            storeBroken = true
            let copy = readOnly ? nil : backupBrokenStore()
            notice = "accounts.json couldn't be read, so OpenAccs won't change it. " + (copy.map { "A copy is in \($0)." } ?? "")
        }
        if firstRun { await discover() }
        await adoptLiveCodex()
        refreshRunning()
        rebuild()
        if !readOnly {
            observeApps()
            watchCards()
            await syncClaude()
        }
        await refreshUsage(force: true)
        isReady = true
        guard !readOnly else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.tick()
            }
        }
    }

    /// First launch: add what is already on this Mac (Claude profiles, the Codex login, Grok Bot).
    private func discover() async {
        for (i, found) in claude.discover().enumerated() {
            accounts.append(Account(provider: .claude, label: found.label, color: i % AccountColor.all.count,
                                    claude: ClaudeAccountInfo(dataDir: found.dataDir, legacyConfigDir: found.legacyConfigDir)))
        }
        for bot in grokBot.accounts() {
            accounts.append(Account(provider: .grok, label: "Grok Bot", color: nextColor(),
                                    grok: GrokAccountInfo(source: .grokBot, botAccount: bot)))
        }
        save()
    }

    /// Snapshots the live Codex login into the vault and adds it when OpenAccs hasn't seen it yet
    /// (also catches sign-ins done inside Codex itself).
    private func adoptLiveCodex() async {
        let info = readOnly ? await codex.liveIdentity() : ((try? await codex.checkIn()) ?? nil)
        liveCodex = info
        codexAuthDate = modificationDate(paths.codexAuthFile)
        guard let info else { return }
        if let dismissed = dismissedCodex {
            if dismissed == Self.key(info) { return }
            if !readOnly { dismissedCodex = nil }
        }
        if let i = accounts.firstIndex(where: { $0.codex.map { Self.same($0, info) } ?? false }) {
            if accounts[i].codex?.plan != info.plan || accounts[i].codex?.email != info.email {
                accounts[i].codex = info
                save()
            }
        } else {
            accounts.append(Account(provider: .codex, label: info.email ?? "ChatGPT", color: nextColor(), codex: info))
            save()
        }
    }

    private func tick() async {
        refreshRunning()
        if modificationDate(paths.codexAuthFile) != codexAuthDate { await adoptLiveCodex() }
        await refreshUsage(force: false)
    }

    private func observeApps() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, id == BundleIDs.claude || id == BundleIDs.codex else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshRunning()
                    self.rebuild()
                    if id == BundleIDs.claude { self.scheduleSync() }
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == BundleIDs.claude, let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.claudeActivated(pid: pid) }
        })
    }

    /// Card folders of every profile: a change anywhere means a session to share.
    private func watchCards() {
        watcher?.stop()
        let dirs = claudeAccounts.map { claude.resolve($0.claude!).dataDir.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
        guard !dirs.isEmpty else { return }
        let watcher = FileWatcher(paths: dirs, latency: 2)
        self.watcher = watcher
        Task { [weak self] in
            for await _ in watcher.changes { self?.scheduleSync() }
        }
    }

    // MARK: Claude

    private var claudeAccounts: [Account] { accounts.filter { $0.provider == .claude && $0.claude != nil } }

    private func profile(_ account: Account) -> ClaudeProfile? {
        account.claude.map(claude.resolve)
    }

    private func isRunning(_ profile: ClaudeProfile) -> Bool {
        runningClaude[profile.dataDir.standardizedFileURL.path] != nil
    }

    private func refreshRunning() {
        runningClaude = Dictionary(claude.running().map { ($0.dataDir.standardizedFileURL.path, $0.pid) }, uniquingKeysWith: { a, _ in a })
    }

    private func claudeActivated(pid: pid_t) {
        guard let path = runningClaude.first(where: { $0.value == pid })?.key ?? claude.running().first(where: { $0.pid == pid })?.dataDir.standardizedFileURL.path,
              let account = claudeAccounts.first(where: { profile($0)?.dataDir.standardizedFileURL.path == path }) else { return }
        lastClaude = account.id
        rebuild()
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncClaude()
        }
    }

    /// Shares sessions between profiles that run on the shared `~/.claude` (not yet migrated ones are left out).
    /// One run at a time; a caller that arrives during a run waits for it, then runs again with fresh state.
    private func syncClaude() async {
        guard !readOnly else { return }
        while let current = syncRun { await current.value }
        let run = Task { await self.syncOnce(); self.syncRun = nil }
        syncRun = run
        await run.value
    }

    private func syncOnce() async {
        refreshRunning()
        // A profile on (or formerly on) its own config folder brings that folder's history into ~/.claude
        // whenever it is fully stopped (copy-only; the old folder is never changed).
        for account in claudeAccounts {
            guard let info = account.claude, info.legacyConfigDir != nil || info.migratedFrom != nil, let p = profile(account),
                  !claudeBusy.contains(p.dataDir.standardizedFileURL.path) || openingNow.contains(account.id) else { continue }
            guard !claude.mayBeRunning(p) else { continue }
            if claude.hasProcesses(p) {   // its Claude Code CLIs are still finishing: look again shortly
                scheduleSync()
                continue
            }
            do {
                try await migrateIfNeeded(account.id)
            } catch {
                notice = "\(account.label): couldn't move its history into ~/.claude (\(error.localizedDescription)). Nothing was changed in its old folder."
            }
        }
        refreshRunning()
        let shared = claudeAccounts.filter { $0.claude?.legacyConfigDir == nil }
        let profiles = shared.compactMap(profile)
        let running = Set(runningClaude.keys.map { URL(filePath: $0, directoryHint: .isDirectory) })
        // Profiles still on their old config folder join history only after a restart (migration);
        // until then they only get a preview count, never writes.
        let legacy = claudeAccounts.filter { $0.claude?.legacyConfigDir != nil }.compactMap { a in profile(a).map { (a.id, $0) } }
        let sync = self.sync
        pending = await Task.detached {
            let plan = try? sync.plan(profiles: profiles, running: running)
            if let plan, !plan.isEmpty { _ = try? sync.apply(plan) }
            var counts: [UUID: Pending] = [:]
            for (account, profile) in zip(shared, profiles) {
                counts[account.id] = Pending(new: sync.pendingCount(for: profile, among: profiles),
                                             changed: profile.cardsDir.flatMap { plan?.waiting(in: $0) } ?? 0)
            }
            let runningPaths = Set(running.map(\.standardizedFileURL.path))
            for (id, profile) in legacy where runningPaths.contains(profile.dataDir.standardizedFileURL.path) {
                let preview = try? sync.plan(profiles: profiles + [profile], running: running)
                counts[id] = Pending(new: max(1, preview?.count(.create, for: profile.dataDir) ?? 1))
            }
            return counts
        }.value
        noteShownAccounts()
        rebuild()
    }

    /// Which account each profile's app shows. A profile remembers the first one it is seen with, so a
    /// window signed in to another account later says so instead of passing for the old one.
    private func noteShownAccounts() {
        var learned = false
        for account in claudeAccounts {
            guard let info = account.claude, let shown = claude.loggedAccount(info) else { continue }
            shownAccount[account.id] = shown
            if info.accountUuid == nil, let i = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[i].claude?.accountUuid = shown
                learned = true
            }
        }
        if learned { save() }
    }

    /// "Signed in as ai42@…" when a profile's app shows another account than the one it was added with.
    private func accountNote(_ account: Account) -> String? {
        guard let expected = account.claude?.accountUuid, let shown = shownAccount[account.id], shown != expected else { return nil }
        let other = claudeAccounts.first { $0.id != account.id && $0.claude?.accountUuid == shown }
        return other.map { "Signed in as \($0.label)" } ?? "Signed in as another account"
    }

    /// Imports an adopted profile's old history into `~/.claude` (profile must be stopped), then forgets the old folder.
    private func migrateIfNeeded(_ id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }),
              let legacy = account.claude?.legacyConfigDir ?? account.claude?.migratedFrom else { return }
        let firstTime = account.claude?.legacyConfigDir != nil
        let paths = self.paths
        let report = try await Task.detached {
            try TranscriptMigration.run(from: URL(filePath: legacy, directoryHint: .isDirectory),
                                        to: paths.claudeSharedConfigDir, backups: paths.backupsDir)
        }.value
        // The list may have changed during the copy: look the account up again. If the profile started
        // meanwhile (it would be on its old folder), keep it as is; the next stop copies again.
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let p = profile(accounts[i]), claude.mayBeRunning(p) || claude.hasProcesses(p) { return }
        guard firstTime else { return }
        accounts[i].claude?.migratedFrom = legacy
        accounts[i].claude?.legacyConfigDir = nil
        save()
        if !report.conflicts.isEmpty {
            let list = paths.backupsDir.appending(path: "migration-conflicts-\(Int(Date().timeIntervalSince1970)).txt")
            try? AtomicFile.write(Data((["Kept in \(legacy)/projects, differs from ~/.claude/projects:"] + report.conflicts).joined(separator: "\n").utf8), to: list)
            notice = "\(account.label): \(report.conflicts.count) file(s) differ from the shared copy and stayed in the old folder. List: \(list.path)"
        }
    }

    /// Runs `body` unless the profile already has an open/restart in flight (a double click does nothing).
    private func exclusively(_ account: Account, _ body: () async throws -> Void) async throws {
        guard let path = profile(account)?.dataDir.standardizedFileURL.path, claudeBusy.insert(path).inserted else { return }
        defer { claudeBusy.remove(path) }
        try await body()
    }

    private func openClaude(_ account: Account) async throws {
        guard var p = profile(account) else { return }
        refreshRunning()
        if isRunning(p) {
            // Claude reads its chat list only at launch. When other windows added or changed chats and nothing
            // works here, a quick restart shows them; otherwise it just comes forward (Restart stays offered).
            // A profile not moved onto ~/.claude yet keeps its transcripts elsewhere: never restarted unasked.
            await syncClaude()
            let claude = self.claude, window = p
            if account.claude?.legacyConfigDir == nil, (pending[account.id]?.total ?? 0) > 0,
               await !Task.detached(operation: { claude.isBusy(window) }).value {
                try await quitClaude(p)
            }
        }
        if !isRunning(p) {
            // The sync migrates this profile first if it still uses its old config folder.
            openingNow.insert(account.id)
            defer { openingNow.remove(account.id) }
            await syncClaude()
            if accounts.first(where: { $0.id == account.id })?.claude?.legacyConfigDir != nil { throw AppError.migrationFailed }
            p = profile(accounts.first { $0.id == account.id } ?? account) ?? p
        }
        _ = try await claude.open(p)
        lastClaude = account.id
        refreshRunning()
        rebuild()
    }

    // MARK: Usage

    func refresh() {
        Task { await refreshUsage(force: true) }
    }

    /// `openaccs refresh`: returns when every account has been asked.
    func refreshNow() async {
        await refreshUsage(force: true)
    }

    /// In a task of its own: a caller that goes away (Ctrl-C on `openaccs`) never cuts the fetches short and
    /// leaves them recorded as failures.
    private func refreshUsage(force: Bool) async {
        await Task { await self.askProviders(force: force) }.value
    }

    private func askProviders(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        grokBotAccounts = grokBot.accounts().filter { bot in !accounts.contains { $0.grok?.botAccount == bot } }
        await withTaskGroup(of: (UUID, Result<UsageSnapshot, UsageError>?).self) { group in
            for account in accounts {
                guard force || isDue(account) else { continue }
                group.addTask { [self] in (account.id, await self.fetchUsage(account)) }
            }
            for await (id, result) in group {
                guard let result else { continue }
                lastFetch[id] = Date()
                switch result {
                case .success(let snapshot):
                    usage[id] = snapshot
                    problems[id] = nil
                case .failure(let error):
                    problems[id] = error
                }
            }
        }
        rebuild()
    }

    /// How often each source is worth asking (local files often, network and CLIs rarely).
    private func isDue(_ account: Account) -> Bool {
        let interval: TimeInterval = switch account.provider {
        case .claude: account.claude?.cliConfigDir == nil ? 60 : 300
        case .grok: account.grok?.source == .grokBot ? 60 : 900
        case .codex, .kimi, .zai: 300
        }
        return Date().timeIntervalSince(lastFetch[account.id] ?? .distantPast) >= interval
    }

    nonisolated private func fetchUsage(_ account: Account) async -> Result<UsageSnapshot, UsageError>? {
        do {
            return .success(try await fetchUsageThrowing(account))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    nonisolated private func fetchUsageThrowing(_ account: Account) async throws -> UsageSnapshot {
        switch account.provider {
        case .claude:
            guard let info = account.claude else { throw UsageError.notConnected }
            if let dir = info.cliConfigDir, !readOnly {
                do {
                    return try await claudeCLI.usage(configDir: URL(filePath: dir, directoryHint: .isDirectory))
                } catch UsageError.notConnected {
                    throw UsageError.needsSignIn
                } catch {
                    if let local = ClaudeAppUsage.read(profile: claude.resolve(info)) { return local }
                    throw error
                }
            }
            guard let local = ClaudeAppUsage.read(profile: claude.resolve(info)) else { throw UsageError.notConnected }
            return local
        case .codex:
            guard let info = account.codex else { throw UsageError.notConnected }
            return try await codex.usage(info, refresh: !readOnly)
        case .zai:
            return try await zai.fetch(apiKey: try apiKey(account), region: region(account))
        case .kimi:
            return try await kimi.fetch(apiKey: try apiKey(account), region: region(account))
        case .grok:
            guard let info = account.grok else { throw UsageError.notConnected }
            switch info.source {
            case .grokBot:
                guard let bot = info.botAccount, let snapshot = grokBot.read(account: bot) else { throw UsageError.notConnected }
                return snapshot
            case .cli:
                guard let home = info.home, !readOnly else { throw UsageError.notConnected }
                return try await grokCLI.usage(home: URL(filePath: home, directoryHint: .isDirectory))
            }
        }
    }

    nonisolated private func apiKey(_ account: Account) throws -> String {
        guard let data = try secrets.read(Self.keyName(account.id)), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw UsageError.notConnected
        }
        return key
    }

    nonisolated private func region(_ account: Account) -> Region {
        Region(rawValue: account.apiKey?.region ?? "") ?? .global
    }

    nonisolated private static func keyName(_ id: UUID) -> String { "apikey:\(id.uuidString)" }

    // MARK: Rows

    private func rebuild() {
        var rows: [PanelRow] = []
        let now = Date()
        for account in accounts {
            let snapshot = usage[account.id]?.at(now)
            let problem = problems[account.id]
            var row = PanelRow(
                id: account.id, provider: account.provider, label: account.label, color: account.color,
                plan: Self.plan(snapshot?.plan ?? account.codex?.plan?.capitalized, label: account.label), state: state(of: account, usage: snapshot),
                usage: snapshot, error: errorText(problem, account: account, hasUsage: snapshot != nil),
                needsSignIn: problem == .needsSignIn
            )
            if account.provider == .claude {
                let waiting = (profile(account).map(isRunning) ?? false) ? pending[account.id] ?? Pending() : Pending()
                row.pendingSessions = waiting.new
                row.pendingChanges = waiting.changed
                row.canConnectLimits = account.claude?.cliConfigDir == nil
                row.hasFolder = true
                if let snapshot, snapshot.source == ClaudeAppUsage.source, now.timeIntervalSince(snapshot.asOf) > ClaudeAppUsage.freshFor {
                    row.usage = nil
                    row.error = "Claude app numbers are old"
                }
                if let note = accountNote(account) { row.error = note }
            }
            rows.append(row)
        }
        markBest(&rows)
        self.rows = rows
        let claudeRows = rows.filter { $0.provider == .claude }
        menuBarUsage = (claudeRows.first { $0.id == lastClaude } ?? claudeRows.first { $0.state == .running } ?? claudeRows.first)?.usage
    }

    private func state(of account: Account, usage: UsageSnapshot?) -> PanelRow.State {
        switch account.provider {
        case .claude: (profile(account).map(isRunning) ?? false) ? .running : .idle
        case .codex: (account.codex.map { info in liveCodex.map { Self.same($0, info) } ?? false } ?? false) ? .active : .idle
        case .grok, .kimi, .zai: usage != nil ? .active : .idle
        }
    }

    private func errorText(_ problem: UsageError?, account: Account, hasUsage: Bool) -> String? {
        switch problem {
        case nil: nil
        case .needsSignIn:
            account.provider == .kimi || account.provider == .zai ? "Key no longer works" : "Sign in again"
        case .notConnected:
            account.provider == .claude ? (hasUsage ? nil : "Open this profile once to see limits") : "Not connected"
        case .noPlan: "No plan with limits"
        case .network: hasUsage ? nil : "Offline"
        case .unexpected(let message): message
        }
    }

    /// ✦ = most room left among a provider's signed-in accounts (in their tightest main window), or with none
    /// left anywhere, the one back soonest. Same rule as `openaccs best` (`ControlAccount.best`).
    private func markBest(_ rows: inout [PanelRow]) {
        for provider in Provider.allCases {
            let scored = rows.indices.filter { rows[$0].provider == provider && !rows[$0].needsSignIn }
                .compactMap { i in rows[i].usage?.room.map { (i, $0) } }
            guard scored.count > 1, let best = Room.best(scored) else { continue }
            rows[best].isBest = true
        }
    }

    // MARK: Actions

    func open(_ id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switch account.provider {
        case .claude:
            try await exclusively(account) { try await openClaude(account) }
        case .codex:
            guard let info = account.codex else { return }
            // A test home's Codex sign-ins are fake; switching would still quit the real ChatGPT app.
            guard !Paths.isOverridden else { throw AppError.testHome }
            let others = await codex.otherHolders()
            guard others.isEmpty else { throw AppError.codexBusy(others.count) }
            try await codex.switchTo(info)
            liveCodex = await codex.liveIdentity()
            codexAuthDate = modificationDate(paths.codexAuthFile)
            rebuild()
            lastFetch[id] = nil
            await refreshUsage(force: false)
        case .grok, .kimi, .zai:
            if let url = usagePage(account) { NSWorkspace.shared.open(url) }
        }
    }

    func restart(_ id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }), let p = profile(account) else { return }
        try await exclusively(account) {
            try await quitClaude(p)
            try await openClaude(account)
        }
    }

    private func quitClaude(_ p: ClaudeProfile) async throws {
        guard await claude.quit(p, timeout: .seconds(30)) else { throw AppError.claudeWontQuit }
        // Its bundled Claude Code processes may still be writing transcripts for a moment.
        for _ in 0..<100 where claude.hasProcesses(p) { try? await Task.sleep(for: .milliseconds(100)) }
        refreshRunning()
    }

    func connectExactLimits(_ id: UUID) async throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts[i]
        let dir = claudeCLI.configDir(for: id)
        let email = account.label.contains("@") ? account.label : nil
        try await claudeCLI.login(configDir: dir, email: email)
        guard let who = claudeCLI.identity(configDir: dir) else { throw AppError.signInIncomplete }
        // The browser may have signed the CLI into another account: never show its limits under this one.
        let expected = profile(account)?.accountUuid
        let mismatch = if let expected, let uuid = who.accountUuid {
            expected.lowercased() != uuid.lowercased()
        } else if let email, let address = who.email {
            address.lowercased() != email.lowercased()
        } else {
            false
        }
        if mismatch {
            // Reconnecting: that folder now holds the other account, so stop reading limits from it.
            if let j = accounts.firstIndex(where: { $0.id == id }), accounts[j].claude?.cliConfigDir != nil {
                accounts[j].claude?.cliConfigDir = nil
                lastFetch[id] = nil
                save()
                rebuild()
            }
            throw AppError.wrongAccount(who.email, account.label)
        }
        guard let j = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[j].claude?.cliConfigDir = dir.path
        save()
        lastFetch[id] = nil
        await refreshUsage(force: false)
    }

    func rename(_ id: UUID, to label: String) {
        update(id) { $0.label = label }
    }

    func setColor(_ id: UUID, to color: Int) {
        update(id) { $0.color = color }
    }

    /// Removes the account from OpenAccs only. Never deletes a Claude profile, a login or history.
    func remove(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if let info = account.codex {
            if let live = liveCodex, Self.same(live, info) {
                dismissedCodex = Self.key(info)   // Codex stays signed in; just stop showing it
            } else {
                Task { try? await codex.forget(info) }
            }
        }
        if account.apiKey != nil { try? secrets.delete(Self.keyName(id)) }
        accounts.removeAll { $0.id == id }
        usage[id] = nil
        problems[id] = nil
        save()
        rebuild()
        if account.provider == .claude { watchCards() }
    }

    func revealFolder(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }), let p = profile(account) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([p.dataDir])
    }

    func quit() { NSApplication.shared.terminate(nil) }

    // MARK: Adding

    func addClaude(label: String) async throws {
        let id = UUID()
        let dir = try claude.makeProfileDirectory(id: id)
        let account = Account(id: id, provider: .claude, label: label.isEmpty ? "Claude" : label, color: nextColor(),
                              claude: ClaudeAccountInfo(dataDir: dir.path))
        accounts.insert(account, at: (accounts.lastIndex { $0.provider == .claude }).map { $0 + 1 } ?? 0)
        save()
        watchCards()
        try await exclusively(account) { try await openClaude(account) }
    }

    func addCodex() async throws {
        let info = try await codex.addAccount()
        if let i = accounts.firstIndex(where: { $0.codex.map { Self.same($0, info) } ?? false }) {
            accounts[i].codex = info
        } else {
            accounts.append(Account(provider: .codex, label: info.email ?? "ChatGPT", color: nextColor(), codex: info))
        }
        save()
        await refreshUsage(force: true)
    }

    func addGrokCLI() async throws {
        let id = UUID()
        let home = grokCLI.home(for: id)
        try await grokCLI.login(home: home)
        accounts.append(Account(id: id, provider: .grok, label: grokCLI.identity(home: home) ?? "Grok", color: nextColor(),
                                grok: GrokAccountInfo(source: .cli, home: home.path)))
        save()
        await refreshUsage(force: true)
    }

    func addGrokBot(account bot: String) async throws {
        accounts.append(Account(provider: .grok, label: "Grok Bot", color: nextColor(), grok: GrokAccountInfo(source: .grokBot, botAccount: bot)))
        save()
        await refreshUsage(force: true)
    }

    func addKimi(key: String, region: String) async throws {
        try await addKeyAccount(.kimi, key: key, region: region) { try await self.kimi.fetch(apiKey: $0, region: $1) }
    }

    func addZai(key: String, region: String) async throws {
        try await addKeyAccount(.zai, key: key, region: region) { try await self.zai.fetch(apiKey: $0, region: $1) }
    }

    /// Checks the key against the provider before saving it, so a typo never becomes an account.
    private func addKeyAccount(
        _ provider: Provider, key: String, region: String,
        check: (String, Region) async throws -> UsageSnapshot
    ) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = Region(rawValue: region) ?? .global
        let snapshot: UsageSnapshot
        do {
            snapshot = try await check(key, region)
        } catch UsageError.needsSignIn {
            throw AppError.keyRejected(provider.displayName)
        }
        let account = Account(provider: provider, label: provider.displayName, color: nextColor(),
                              apiKey: APIKeyAccountInfo(region: region.rawValue))
        try secrets.write(Data(key.utf8), for: Self.keyName(account.id))
        accounts.append(account)
        usage[account.id] = snapshot
        lastFetch[account.id] = Date()
        save()
        rebuild()
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
        save()
        rebuild()
    }

    private func save() {
        guard !readOnly, !storeBroken else { return }
        try? store.save(accounts)
    }

    private func nextColor() -> Int {
        let used = Set(accounts.map(\.color))
        return (0..<AccountColor.all.count).first { !used.contains($0) } ?? accounts.count % AccountColor.all.count
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func usagePage(_ account: Account) -> URL? {
        switch account.provider {
        case .grok: URL(string: "https://grok.com")
        case .kimi: URL(string: account.apiKey?.region == "china" ? "https://www.kimi.com/code/console" : "https://www.kimi.ai/code/console")
        case .zai: URL(string: account.apiKey?.region == "china" ? "https://open.bigmodel.cn" : "https://z.ai/manage-apikey/subscription")
        case .claude, .codex: nil
        }
    }

    /// The plan chip, unless it only repeats the label ("Grok Bot" + "Grok Bot Plan").
    static func plan(_ plan: String?, label: String) -> String? {
        guard let plan, !plan.isEmpty, !plan.lowercased().hasPrefix(label.lowercased()) else { return nil }
        let names = ["promax": "Pro Max", "pro": "Pro", "plus": "Plus", "max": "Max", "team": "Team", "free": "Free",
                     "self_serve_business_prolite": "Business", "business": "Business", "enterprise": "Enterprise"]
        return names[plan.lowercased()] ?? plan.replacingOccurrences(of: "_", with: " ").capitalized
    }

    nonisolated static func key(_ info: CodexAccountInfo) -> String { "\(info.userId):\(info.accountId)" }

    /// Copies an unreadable accounts.json into Backups before anything else happens. Returns the copy's folder.
    private func backupBrokenStore() -> String? {
        let copy = paths.backupsDir.appending(path: "accounts-\(Int(Date().timeIntervalSince1970)).json")
        guard (try? FileManager.default.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: paths.accountsFile, to: copy)) != nil else { return nil }
        return paths.backupsDir.path
    }

    nonisolated static func same(_ a: CodexAccountInfo, _ b: CodexAccountInfo) -> Bool {
        a.userId == b.userId && a.accountId == b.accountId
    }
}

/// What an open Claude window would load on a restart.
struct Pending: Equatable, Sendable {
    /// Sessions it has no card for (or got one after it launched).
    var new = 0
    /// Chats whose pin, archive, permission mode, effort or model changed in another window.
    var changed = 0

    var total: Int { new + changed }
}

enum AppError: LocalizedError {
    case codexBusy(Int)
    case claudeWontQuit
    case signInIncomplete
    case keyRejected(String)
    case wrongAccount(String?, String)
    case migrationFailed
    case testHome

    var errorDescription: String? {
        switch self {
        case .codexBusy(let n): "Close \(n == 1 ? "the codex session" : "the \(n) codex sessions") in Terminal first; they would keep the old account."
        case .claudeWontQuit: "Claude didn't quit. Finish or stop its running tasks and try again."
        case .signInIncomplete: "Sign-in didn't finish. Try again."
        case .keyRejected(let name): "\(name) didn't accept this key."
        case .migrationFailed: "Couldn't move this profile's history into ~/.claude, so it wasn't opened on the shared folder."
        case .testHome: "Codex doesn't switch with a test home (OPENACCS_HOME)."
        case .wrongAccount(let actual, let wanted):
            "Claude Code signed in as \(actual ?? "another account"), not \(wanted). Switch accounts on claude.ai in your browser and try again."
        }
    }
}
