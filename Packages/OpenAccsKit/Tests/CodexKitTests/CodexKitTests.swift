import Foundation
import OpenAccsCore
import Testing
@testable import CodexKit

@Suite struct ProfileTests {
    @Test func profilePathsLeaveRoomForMacOSUnixSockets() {
        let accounts = CodexAccounts(paths: Paths(home: URL(filePath: "/Users/mikwiseman")), secrets: MemorySecretStore())
        let socket = accounts.profileHome(Fake.info("bob")).appending(path: "app-server-daemon/daemon.sock")
        #expect(socket.path.utf8.count < 104)
    }

    @Test func opensAnotherAccountWithoutQuittingOrReplacingTheDefault() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        try box.park(Fake.auth("bob"), as: "bob")
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        #expect(try box.live() == Fake.auth("ana"))
        let home = box.accounts.profileHome(Fake.info("bob"))
        #expect(CodexAuthFile.identity(of: try Data(contentsOf: home.appending(path: "auth.json"))) == Fake.info("bob"))
        #expect(box.app.log.isEmpty) // no quit, daemon restart, or legacy launch
        #expect(box.app.profileLaunches == [home.path])
    }

    @Test func anExistingProfileOwnsItsRotatedLogin() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        try box.park(Fake.auth("bob"), as: "bob")
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        let home = box.accounts.profileHome(Fake.info("bob"))
        let rotated = Fake.auth("bob", refresh: "rt.new")
        try rotated.write(to: home.appending(path: "auth.json"))
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        #expect(try Data(contentsOf: home.appending(path: "auth.json")) == rotated)
        #expect(try box.vault("bob") == rotated)
    }

    @Test func profilesShareSetupButKeepTheirOwnAuth() async throws {
        let box = try Sandbox()
        let config = box.paths.codexHome.appending(path: "config.toml")
        try Data("model = \"test-model\"\n".utf8).write(to: config)
        try box.park(Fake.auth("bob"), as: "bob")
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        let home = box.accounts.profileHome(Fake.info("bob"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appending(path: "config.toml").path) == config.path)
        #expect(CodexAuthFile.identity(of: try Data(contentsOf: home.appending(path: "auth.json"))) == Fake.info("bob"))
    }

    @Test func profilesShareHistoryAndWriterLocksWithoutSharingTheLogin() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        try box.park(Fake.auth("bob"), as: "bob")
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        let home = box.accounts.profileHome(Fake.info("bob"))
        for name in ["sessions", "archived_sessions", "thread-writer-locks", "memories", "memories_v2", "attachments"] {
            let shared = box.paths.codexHome.appending(path: name)
            let linked = home.appending(path: name)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == shared.path)
            try Data("new content".utf8).write(to: linked.appending(path: "probe"))
            #expect(try String(contentsOf: shared.appending(path: "probe"), encoding: .utf8) == "new content")
        }
        #expect(try box.live() == Fake.auth("ana"))
    }

    @Test func launchSharesTheNativeDatabaseDirectoryAndKeepsAuthPrivate() throws {
        let box = try Sandbox()
        let home = box.accounts.profileHome(Fake.info("bob"))
        let environment = CodexApp(paths: box.paths).environment(home: home)
        #expect(environment["CODEX_HOME"] == home.path)
        #expect(environment["CODEX_SQLITE_HOME"] == box.paths.codexHome.path)
        #expect(environment["CODEX_ELECTRON_USER_DATA_PATH"] == home.deletingLastPathComponent().appending(path: "Electron").path)
    }

    @Test func newProfilesKeepTheExistingProjectSidebarAndTheirOwnWindowPreferences() async throws {
        let box = try Sandbox()
        try box.park(Fake.auth("bob"), as: "bob")
        let home = box.accounts.profileHome(Fake.info("bob"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let filename = ".codex-global-state.json"
        let source: [String: Any] = [
            "local-projects": ["project-1": ["id": "project-1", "name": "Example", "rootPaths": ["/code/example"]]],
            "project-order": ["project-1"],
            "app-server-project-id-by-legacy-project-id-by-host": ["local:\(box.paths.codexHome.path)": ["project-1": "server-1"]],
            "electron-main-window-bounds": ["width": 900],
        ]
        try JSONSerialization.data(withJSONObject: source).write(to: box.paths.codexHome.appending(path: filename))
        try JSONSerialization.data(withJSONObject: ["electron-main-window-bounds": ["width": 700]]).write(to: home.appending(path: filename))
        _ = try await box.accounts.open(Fake.info("bob"), activate: false)
        let state = try #require(JSON.object(Data(contentsOf: home.appending(path: filename))))
        #expect((state["local-projects"] as? [String: Any])?["project-1"] != nil)
        #expect((state["electron-main-window-bounds"] as? [String: Int])?["width"] == 700)
        #expect((state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]])?["local:\(home.path)"]?["project-1"] == "server-1")
    }

    @Test func neverOverwritesAProfileSignedInAsSomeoneElse() async throws {
        let box = try Sandbox()
        try box.park(Fake.auth("bob"), as: "bob")
        let home = box.accounts.profileHome(Fake.info("bob"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Fake.auth("ana").write(to: home.appending(path: "auth.json"))
        await #expect(throws: CodexError.verifyFailed(found: "ana@example.com")) {
            try await box.accounts.open(Fake.info("bob"), activate: false)
        }
        #expect(box.app.profileLaunches.isEmpty)
    }
}

@Suite struct IdentityTests {
    @Test func readsAccountUserEmailAndPlan() {
        let info = CodexAuthFile.identity(of: Fake.auth("ana", plan: "plus"))
        #expect(info == CodexAccountInfo(userId: "user-ana", accountId: "acct-ana", email: "ana@example.com", plan: "plus"))
    }

    @Test func userIdFallsBackToUserIdThenSub() {
        func file(_ auth: [String: Any], sub: String?) -> Data {
            var claims: [String: Any] = ["https://api.openai.com/profile": ["email": "p@example.com"], "https://api.openai.com/auth": auth]
            claims["sub"] = sub
            let tokens: [String: Any] = ["id_token": Fake.jwt(claims), "access_token": "a", "refresh_token": "r", "account_id": "w1"]
            return try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
        }
        let viaUserId = CodexAuthFile.identity(of: file(["user_id": "u2"], sub: "s3"))
        #expect(viaUserId?.userId == "u2")
        #expect(viaUserId?.email == "p@example.com")
        #expect(CodexAuthFile.identity(of: file([:], sub: "s3"))?.userId == "s3")
        #expect(CodexAuthFile.identity(of: file([:], sub: nil)) == nil)
    }

    @Test func rejectsApiKeyAndBrokenFiles() {
        #expect(CodexAuthFile.identity(of: Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#.utf8)) == nil)
        #expect(CodexAuthFile.identity(of: Data(#"{"tokens":{"id_token":"nope"}}"#.utf8)) == nil)
        #expect(CodexAuthFile.identity(of: Data("{\"tokens\":".utf8)) == nil)
    }

    @Test func rejectsAFileWhoseWorkspaceDisagreesWithItsIdToken() throws {
        func file(accountId: String?) throws -> Data {
            var root = try #require(JSON.object(Fake.auth("ana")))
            var tokens = Fake.tokens(Fake.auth("ana"))
            tokens["account_id"] = accountId
            root["tokens"] = tokens
            return try JSONSerialization.data(withJSONObject: root)
        }
        #expect(CodexAuthFile.identity(of: try file(accountId: "acct-bob")) == nil)  // ana's id_token, bob's workspace
        #expect(CodexAuthFile.identity(of: try file(accountId: "acct-ana")) == Fake.info("ana"))
        #expect(CodexAuthFile.identity(of: try file(accountId: nil))?.accountId == "acct-ana")
    }

    @Test func mergeKeepsUnknownFieldsAndStampsRefresh() throws {
        let merged = try #require(CodexAuthFile.merging(
            Fake.auth("ana"), refreshed: ["access_token": "new-a", "refresh_token": "new-r"], at: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let root = try #require(JSON.object(merged))
        #expect(Fake.tokens(merged)["access_token"] as? String == "new-a")
        #expect(Fake.tokens(merged)["refresh_token"] as? String == "new-r")
        #expect(Fake.tokens(merged)["id_token"] as? String == Fake.tokens(Fake.auth("ana"))["id_token"] as? String)
        #expect(root["last_refresh"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(root["unknown_future_field"] != nil)
        #expect(root["OPENAI_API_KEY"] is NSNull)
    }
}

@Suite struct VaultTests {
    @Test func checkInStoresExactBytesOnlyWhenChanged() async throws {
        let box = try Sandbox()
        #expect(try await box.accounts.checkIn() == nil)

        let live = Fake.auth("ana")
        try box.setLive(live)
        #expect(try await box.accounts.checkIn() == Fake.info("ana"))
        #expect(try box.vault("ana") == live)
        #expect(await box.accounts.hasVaultCopy(Fake.info("ana")))
        try await box.accounts.checkIn()
        #expect(box.secrets.writes == 1)

        let rotated = Fake.auth("ana", refresh: "rt.2")
        try box.setLive(rotated)
        try await box.accounts.checkIn()
        #expect(box.secrets.writes == 2)
        #expect(try box.vault("ana") == rotated)
    }

    @Test func checkInWaitsOutAHalfWrittenFile() async throws {
        let box = try Sandbox()
        let full = Fake.auth("ana")
        try box.setLive(full.prefix(40))  // Codex truncates, then writes in place
        let file = box.paths.codexAuthFile
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? full.write(to: file) }
        #expect(try await box.accounts.checkIn() == Fake.info("ana"))
        #expect(try box.vault("ana") == full)
    }

    @Test func forgetDeletesOnlyTheVaultCopy() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        try await box.accounts.checkIn()
        try await box.accounts.forget(Fake.info("ana"))
        #expect(try box.vault("ana") == nil)
        #expect(try box.live() == Fake.auth("ana"))
        #expect(box.app.log.isEmpty)
    }

    @Test func addAccountLogsInPrivatelyAndVaults() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        box.app.loginWrites = Fake.auth("bob")
        #expect(try await box.accounts.addAccount() == Fake.info("bob"))
        #expect(try box.vault("bob") == Fake.auth("bob"))
        let loginHome = try #require(box.app.loginHome)
        #expect(loginHome.path.hasPrefix(box.paths.appSupport.path))
        #expect(box.app.loginHomeMode == 0o700)
        #expect(!FileManager.default.fileExists(atPath: loginHome.path))
        #expect(try box.live() == Fake.auth("ana"))  // the live login is untouched
    }

    @Test func addAccountCleansUpWhenLoginLeavesNothing() async throws {
        let box = try Sandbox()
        await #expect(throws: CodexError.signInFailed) { try await box.accounts.addAccount() }
        let loginHome = try #require(box.app.loginHome)
        #expect(!FileManager.default.fileExists(atPath: loginHome.path))
    }

    @Test func signingInAgainRenewsAClosedProfile() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        let home = box.accounts.profileHome(Fake.info("bob"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appending(path: "auth.json")
        try Fake.auth("bob", refresh: "expired").write(to: file)
        box.app.loginWrites = Fake.auth("bob", refresh: "new-login")
        _ = try await box.accounts.addAccount()
        _ = try await box.accounts.open(Fake.info("bob"))
        #expect(try Data(contentsOf: file) == box.app.loginWrites)
        #expect(try box.vault("bob") == box.app.loginWrites)
        #expect(try box.live() == Fake.auth("ana"))
    }

}

@Suite struct HolderTests {
    static let cli = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let daemon = "/Users/me/.codex/packages/app-server-daemon/releases/0.163.0/CodexCLI.app/Contents/MacOS/codex"

    /// Holders in a fake process table: pid → (parent pid, executable path).
    func holders(_ box: Sandbox, _ table: [pid_t: (parent: pid_t, path: String)]) async -> [pid_t] {
        let entries = table.map { ProcessList.Entry(pid: $0.key, path: $0.value.path) }
        let parents = table.mapValues(\.parent)
        return await box.accounts.otherHolders(among: entries, parent: { parents[$0] }).map(\.pid).sorted()
    }

    @Test func theSharedDaemonAndItsUpdaterAreNotHolders() async throws {
        let box = try Sandbox()
        let (me, up) = (getpid(), getppid())
        try box.setDaemonPid("daemon.pid", pid: me, startSeconds: try #require(CodexAccounts.startSeconds(of: me)))
        try box.setDaemonPid("daemon-updater.pid", pid: up, startSeconds: try #require(CodexAccounts.startSeconds(of: up)))
        let table: [pid_t: (parent: pid_t, path: String)] = [
            me: (1, Self.daemon),
            up: (1, Self.daemon),
            4242: (4241, "/opt/homebrew/bin/codex"),  // a TUI from a standalone install
            4241: (1, "/bin/zsh"),
        ]
        #expect(await holders(box, table) == [4242])

        // A pid file whose process is gone (pid reused) protects nothing.
        try box.setDaemonPid("daemon.pid", pid: me, startSeconds: 1_790_768_499)
        #expect(await holders(box, table) == [me, 4242].sorted())
    }

    @Test func chatGPTsBundledCLICountsOnlyWhenTheAppDidNotStartIt() async throws {
        let table: [pid_t: (parent: pid_t, path: String)] = [
            100: (1, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            101: (100, Self.cli),  // the app's own app-server
            102: (101, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"),
            103: (102, Self.cli),  // started by the app's agent, a few levels down
            104: (101, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host"),
            200: (1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            201: (200, "/bin/zsh"),
            202: (201, Self.cli),  // ChatGPT's CLI run from Terminal
            203: (201, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            204: (201, "/Users/me/.codex/packages/0.150/codex"),
            205: (1, "/opt/tools/CodexCLI.app/Contents/MacOS/codex-helper"),
            206: (1, "/usr/local/bin/codex-code-mode-host"),
        ]
        #expect(await holders(try Sandbox(), table) == [202, 203, 204, 205])
    }
}

@Suite struct SwitchTests {
    /// Ana is live (with rotated tokens the vault hasn't seen), Bob is parked.
    func anaLiveBobParked() throws -> Sandbox {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana", refresh: "rt.rotated"))
        try box.park(Fake.auth("ana"), as: "ana")
        try box.park(Fake.auth("bob"), as: "bob")
        return box
    }

    @Test func quitsChecksInSwapsRelaunchesAndVerifies() async throws {
        let box = try anaLiveBobParked()
        try await box.accounts.switchTo(Fake.info("bob"))
        #expect(box.app.log == ["quit ana@example.com", "launch bob@example.com"])
        #expect(try box.live() == Fake.auth("bob"))
        #expect(try box.vault("ana") == Fake.auth("ana", refresh: "rt.rotated"))  // checked in before the swap
        let mode = try FileManager.default.attributesOfItem(atPath: box.paths.codexAuthFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(await box.accounts.liveIdentity() == Fake.info("bob"))
    }

    @Test func restartsALiveDaemonAfterTheSwap() async throws {
        let box = try anaLiveBobParked()
        let me = getpid()
        let start = try #require(CodexAccounts.startSeconds(of: me))
        let pidFile = box.paths.codexHome.appending(path: "app-server-daemon/daemon.pid")
        try FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pid":\#(me),"processIdentity":{"startSeconds":\#(start)}}"#.utf8).write(to: pidFile)
        try await box.accounts.switchTo(Fake.info("bob"))
        #expect(box.app.log == ["quit ana@example.com", "restartDaemon bob@example.com", "launch bob@example.com"])
    }

    @Test func ignoresAStaleDaemonPidFile() async throws {
        let box = try anaLiveBobParked()
        let pidFile = box.paths.codexHome.appending(path: "app-server-daemon/daemon.pid")
        try FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Our own pid, but a different start time: the pid was reused.
        try Data(#"{"pid":\#(getpid()),"processIdentity":{"startSeconds":1790768499}}"#.utf8).write(to: pidFile)
        try await box.accounts.switchTo(Fake.info("bob"))
        #expect(box.app.log == ["quit ana@example.com", "launch bob@example.com"])

        #expect(CodexAccounts.livePid(pidFile: Data("\(getpid())\n".utf8)) == getpid())
        #expect(CodexAccounts.livePid(pidFile: Data("99999999".utf8)) == nil)
        #expect(CodexAccounts.livePid(pidFile: Data("garbage".utf8)) == nil)
    }

    @Test func abortsUntouchedWhenCodexWontQuit() async throws {
        let box = try anaLiveBobParked()
        box.app.quitSucceeds = false
        await #expect(throws: CodexError.appStillRunning) { try await box.accounts.switchTo(Fake.info("bob")) }
        #expect(box.app.log == ["quit ana@example.com"])
        #expect(try box.live() == Fake.auth("ana", refresh: "rt.rotated"))
        #expect(try box.vault("ana") == Fake.auth("ana"))
        #expect(box.secrets.writes == 0)
    }

    @Test func refusesKeychainOrEncryptedCredentialStores() async throws {
        for store in [#"cli_auth_credentials_store = "keyring""#, "cli_auth_credentials_store='auto' # note"] {
            let box = try anaLiveBobParked()
            try Data("model = \"gpt\"\n\(store)\n".utf8).write(to: box.paths.codexHome.appending(path: "config.toml"))
            await #expect(throws: CodexError.keychainCredentials) { try await box.accounts.switchTo(Fake.info("bob")) }
            #expect(box.app.log.isEmpty)
            #expect(try box.live() == Fake.auth("ana", refresh: "rt.rotated"))
        }
        let box = try anaLiveBobParked()
        try FileManager.default.createDirectory(at: box.paths.codexHome.appending(path: "secrets"), withIntermediateDirectories: true)
        await #expect(throws: CodexError.encryptedCredentials) { try await box.accounts.switchTo(Fake.info("bob")) }
        #expect(box.app.log.isEmpty)

        #expect(!CodexAccounts.storesCredentialsInKeychain("cli_auth_credentials_store = \"file\""))
        #expect(!CodexAccounts.storesCredentialsInKeychain("# cli_auth_credentials_store = \"keyring\""))
    }

    @Test func refusesWithoutAVaultCopy() async throws {
        let box = try anaLiveBobParked()
        await #expect(throws: CodexError.noSavedSignIn) { try await box.accounts.switchTo(Fake.info("cleo")) }
        #expect(box.app.log.isEmpty)
        #expect(try box.live() == Fake.auth("ana", refresh: "rt.rotated"))
    }

    @Test func refusesWhenTheLiveSignInCantBeSaved() async throws {
        let box = try anaLiveBobParked()
        try box.setLive(Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test"}"#.utf8))
        await #expect(throws: CodexError.unsavedSignIn) { try await box.accounts.switchTo(Fake.info("bob")) }
        #expect(box.app.log.isEmpty)
    }

    @Test func alreadyLiveJustOpensTheApp() async throws {
        let box = try anaLiveBobParked()
        try await box.accounts.switchTo(Fake.info("ana", plan: "plus"))  // plan changed; same login
        #expect(box.app.log == ["launch ana@example.com"])
        #expect(box.secrets.writes == 0)
    }

    @Test func launchesWithoutQuittingWhenCodexIsClosed() async throws {
        let box = try anaLiveBobParked()
        box.app.running = false
        try await box.accounts.switchTo(Fake.info("bob"))
        #expect(box.app.log == ["launch bob@example.com"])
    }

    @Test func verifyCatchesAnotherWriter() async throws {
        let box = try anaLiveBobParked()
        let file = box.paths.codexAuthFile
        box.app.onLaunch = { try? Fake.auth("ana").write(to: file) }  // a stale codex writes its login back
        await #expect(throws: CodexError.verifyFailed(found: "ana@example.com")) {
            try await box.accounts.switchTo(Fake.info("bob"))
        }
    }
}

@Suite struct UsageTests {
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let pro = #"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":88,"limit_window_seconds":604800,"reset_after_seconds":401341,"reset_at":1792874740},"secondary_window":null},"additional_rate_limits":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reset_credits":{"available_count":0,"applicable_available_count":0}}"#

    func refreshAnswer(_ name: String) -> String {
        let fresh = Fake.tokens(Fake.auth(name, accessExpires: Date().addingTimeInterval(10 * 86_400), refresh: "rt.new"))
        let body: [String: Any] = ["id_token": fresh["id_token"]!, "access_token": fresh["access_token"]!, "refresh_token": "rt.new.\(name)"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    @Test func refreshesAnExpiringParkedLoginAndStoresItFirst() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana"))
        try box.park(Fake.auth("bob", accessExpires: Date().addingTimeInterval(120)), as: "bob")
        box.http.on(Self.tokenURL, .init(json: refreshAnswer("bob")))
        box.http.on(Self.usageURL, .init(json: Self.pro))

        let usage = try await box.accounts.usage(Fake.info("bob"))
        #expect(usage.plan == "pro")

        let requests = box.http.requests
        #expect(requests.count == 2)
        let refresh = requests[0]
        #expect(refresh.httpMethod == "POST")
        #expect(refresh.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(refresh.httpBody.flatMap(JSON.object))
        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["client_id"] as? String == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(body["refresh_token"] as? String == "rt.1.bob")

        let stored = try #require(try box.vault("bob"))
        #expect(Fake.tokens(stored)["refresh_token"] as? String == "rt.new.bob")
        #expect(JSON.object(stored)?["unknown_future_field"] != nil)
        #expect(JSON.object(stored)?["last_refresh"] as? String != "2026-10-19T18:56:01.123456Z")
        let get = requests[1]
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fake.tokens(stored)["access_token"] as! String)")
        #expect(get.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-bob")
        #expect(get.value(forHTTPHeaderField: "User-Agent") == "codex_cli_rs/0.163.0")
        #expect(get.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(try box.live() == Fake.auth("ana"))
    }

    @Test func neverRefreshesTheLiveLogin() async throws {
        let box = try Sandbox()
        let live = Fake.auth("ana", accessExpires: Date().addingTimeInterval(120))
        try box.setLive(live)
        box.http.on(Self.usageURL, .init(json: Self.pro))
        _ = try await box.accounts.usage(Fake.info("ana"))
        #expect(box.http.requests.map { $0.url?.absoluteString } == [Self.usageURL])
        let token = Fake.tokens(live)["access_token"] as! String
        #expect(box.http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")

        let rejected = try Sandbox()
        try rejected.setLive(live)
        try rejected.park(Fake.auth("ana"), as: "ana")
        rejected.http.on(Self.usageURL, .init(status: 401, json: "{}"))
        rejected.http.on(Self.tokenURL, .init(json: refreshAnswer("ana")))
        await #expect(throws: UsageError.needsSignIn) { try await rejected.accounts.usage(Fake.info("ana")) }
        #expect(rejected.http.requests.count == 1)
        #expect(try rejected.live() == live)
        #expect(try rejected.vault("ana") == Fake.auth("ana"))
    }

    @Test func expiredLiveTokenAsksToOpenCodex() async throws {
        let box = try Sandbox()
        try box.setLive(Fake.auth("ana", accessExpires: Date().addingTimeInterval(-60)))
        await #expect(throws: UsageError.unexpected("Open Codex to renew its sign-in")) {
            try await box.accounts.usage(Fake.info("ana"))
        }
        #expect(box.http.requests.isEmpty)
    }

    @Test func parked401RefreshesOnceAndRetries() async throws {
        let box = try Sandbox()
        try box.park(Fake.auth("bob"), as: "bob")
        box.http.on(Self.usageURL, .init(status: 401, json: #"{"error":{"code":"token_expired"}}"#), .init(json: Self.pro))
        box.http.on(Self.tokenURL, .init(json: refreshAnswer("bob")))
        _ = try await box.accounts.usage(Fake.info("bob"))
        #expect(box.http.requests.map { $0.httpMethod ?? "" } == ["GET", "POST", "GET"])
        #expect(Fake.tokens(try #require(try box.vault("bob")))["refresh_token"] as? String == "rt.new.bob")
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_grant"}"#),
        (401, #"{}"#),
        (400, #"{"error":{"code":"refresh_token_reused","message":"used"}}"#),
        (403, #"{"code":"refresh_token_invalidated"}"#),
    ])
    func permanentRefreshFailuresNeedSignIn(status: Int, body: String) async throws {
        let box = try Sandbox()
        let parked = Fake.auth("bob", accessExpires: Date().addingTimeInterval(60))
        try box.park(parked, as: "bob")
        box.http.on(Self.tokenURL, .init(status: status, json: body))
        await #expect(throws: UsageError.needsSignIn) { try await box.accounts.usage(Fake.info("bob")) }
        #expect(try box.vault("bob") == parked)
    }

    @Test func transientRefreshFailureKeepsTheVault() async throws {
        let box = try Sandbox()
        let parked = Fake.auth("bob", accessExpires: Date().addingTimeInterval(60))
        try box.park(parked, as: "bob")
        box.http.on(Self.tokenURL, .init(status: 502, json: "<html>"))
        await #expect(throws: UsageError.unexpected("Token refresh failed (HTTP 502)")) {
            try await box.accounts.usage(Fake.info("bob"))
        }
        #expect(try box.vault("bob") == parked)
    }

    @Test func readOnlyNeverRefreshesAParkedLogin() async throws {
        let expiring = try Sandbox()
        let parked = Fake.auth("bob", accessExpires: Date().addingTimeInterval(120))
        try expiring.park(parked, as: "bob")
        expiring.http.on(Self.tokenURL, .init(json: refreshAnswer("bob")))
        expiring.http.on(Self.usageURL, .init(json: Self.pro))
        await #expect(throws: UsageError.unexpected("Not refreshed")) {
            try await expiring.accounts.usage(Fake.info("bob"), refresh: false)
        }
        #expect(expiring.http.requests.isEmpty)
        #expect(try expiring.vault("bob") == parked)
        #expect(expiring.secrets.writes == 0)

        let rejected = try Sandbox()
        try rejected.park(Fake.auth("bob"), as: "bob")
        rejected.http.on(Self.usageURL, .init(status: 401, json: "{}"), .init(json: Self.pro))
        rejected.http.on(Self.tokenURL, .init(json: refreshAnswer("bob")))
        await #expect(throws: UsageError.unexpected("Not refreshed")) {
            try await rejected.accounts.usage(Fake.info("bob"), refresh: false)
        }
        #expect(rejected.http.requests.map { $0.httpMethod ?? "" } == ["GET"])
        #expect(try rejected.vault("bob") == Fake.auth("bob"))
        #expect(rejected.secrets.writes == 0)
    }

    @Test func unknownAccountIsNotConnected() async throws {
        let box = try Sandbox()
        await #expect(throws: UsageError.notConnected) { try await box.accounts.usage(Fake.info("zed")) }
    }
}

@Suite struct UsageParsingTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func proHasOnlyAWeeklyWindow() throws {
        let s = try CodexUsage.parse(Data(UsageTests.pro.utf8), now: now)
        #expect(s.plan == "pro")
        #expect(s.windows == [UsageWindow(kind: .weekly, usedPercent: 88, resetsAt: Date(timeIntervalSince1970: 1_792_874_740))])
        #expect(s.credits == nil)
        #expect(s.resetsAvailable == 0)
        #expect(s.source == "ChatGPT")
    }

    @Test func plusHasFiveHourAndWeeklyByWindowLength() throws {
        // Positions swapped on purpose: classification is by limit_window_seconds.
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":604800,"reset_at":1792500000},"secondary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":3600}}}"#
        let s = try CodexUsage.parse(Data(json.utf8), now: now)
        #expect(s.window(.fiveHour) == UsageWindow(kind: .fiveHour, usedPercent: 40, resetsAt: now.addingTimeInterval(3600)))
        #expect(s.window(.weekly)?.usedPercent == 12.5)
        #expect(s.resetsAvailable == nil)
    }

    @Test func additionalLimitsBecomeLabeledWindows() throws {
        let json = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":1792500000}},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000,"reset_at":1792010000},"secondary_window":{"used_percent":70,"limit_window_seconds":604800,"reset_at":1792500000}}},{"limit_name":"","metered_feature":"codex_other","rate_limit":null}]}"#
        let s = try CodexUsage.parse(Data(json.utf8), now: now)
        #expect(s.windows.map(\.kind) == [.weekly, .fiveHour, .weekly])
        #expect(s.windows.map(\.label) == [nil, "GPT-5.3-Codex-Spark", "GPT-5.3-Codex-Spark"])
        #expect(s.window(.weekly)?.usedPercent == 5)
    }

    @Test func creditsAndBankedResets() throws {
        let json = #"{"plan_type":"plus","rate_limit":null,"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},"rate_limit_reset_credits":{"available_count":2,"applicable_available_count":1}}"#
        let s = try CodexUsage.parse(Data(json.utf8), now: now)
        #expect(s.credits == Credits(amount: 12.5, currency: "credits", label: "balance"))
        #expect(s.resetsAvailable == 2)
    }

    @Test func enterpriseSpendControlIsMonthly() throws {
        let json = #"{"plan_type":"enterprise_cbp_usage_based","rate_limit":null,"spend_control":{"reached":false,"individual_limit":{"limit":"25000","used":"8000","remaining":"17000","used_percent":32,"remaining_percent":68,"reset_after_seconds":3600,"reset_at":1794000000}}}"#
        let s = try CodexUsage.parse(Data(json.utf8), now: now)
        #expect(s.plan == "enterprise_cbp_usage_based")
        #expect(s.windows == [UsageWindow(kind: .monthly, usedPercent: 32, resetsAt: Date(timeIntervalSince1970: 1_794_000_000))])
    }

    @Test func garbageIsAnError() {
        #expect(throws: UsageError.self) { try CodexUsage.parse(Data("<html>".utf8), now: now) }
    }
}
