import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

private func object(_ json: String) throws -> [String: Any] {
    try #require(JSON.object(Data(json.utf8)))
}

private func iso(_ string: String) -> Date {
    ISO8601DateFormatter().date(from: string)!
}

@Suite struct ClaudeCodeUsageTests {
    let now = Date(timeIntervalSince1970: 1_760_970_000)

    /// The shape Claude Code 2.1.285 answers `get_usage` with (field names from its control schema).
    let success = """
        {"type":"control_response","response":{"subtype":"success","request_id":"u","response":{
          "session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":0,"total_lines_added":0,"total_lines_removed":0,"model_usage":{}},
          "subscription_type":"max","rate_limits_available":true,
          "rate_limits":{
            "five_hour":{"utilization":37.5,"resets_at":"2026-10-20T15:00:00.123456+00:00"},
            "seven_day":{"utilization":61,"resets_at":"2026-10-24T09:00:00.5Z"},
            "seven_day_oauth_apps":null,
            "seven_day_opus":{"utilization":12,"resets_at":null},
            "seven_day_sonnet":{"utilization":null,"resets_at":null},
            "cinder_cove":{"utilization":3,"resets_at":null},
            "model_scoped":[
              {"display_name":"Fable","utilization":44,"resets_at":"2026-10-24T09:00:00.000Z"},
              {"display_name":"opus","utilization":99,"resets_at":null}
            ],
            "extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":27140,"utilization":54,"currency":"usd"}
          },
          "behaviors":null}}}
        """

    @Test func mapsWindowsResetsPlanAndExtraUsage() throws {
        let usage = try ClaudeCodeCLI.parseUsage(object(success), now: now)

        #expect(usage.plan == "Max")
        #expect(usage.source == "Claude Code")
        #expect(usage.asOf == now)
        #expect(usage.windows.map(\.kind) == [.fiveHour, .weekly, .weekly, .weekly])
        #expect(usage.windows.map(\.label) == [nil, nil, "Opus", "Fable"])
        #expect(usage.windows.map(\.usedPercent) == [37.5, 61, 12, 44])

        let fiveHour = try #require(usage.window(.fiveHour)?.resetsAt)
        #expect(abs(fiveHour.timeIntervalSince(iso("2026-10-20T15:00:00Z"))) < 1)
        let weekly = try #require(usage.window(.weekly)?.resetsAt)
        #expect(abs(weekly.timeIntervalSince(iso("2026-10-24T09:00:00Z"))) < 1)
        #expect(usage.windows[2].resetsAt == nil)
        #expect(usage.windows[3].resetsAt == iso("2026-10-24T09:00:00Z"))

        #expect(usage.credits == Credits(amount: 271.40, currency: "USD", label: "extra usage"))
    }

    @Test func extraUsageOffOrInAnotherCurrency() throws {
        func credits(_ extra: String) throws -> Credits? {
            let json = #"{"response":{"subtype":"success","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":1,"resets_at":null},"extra_usage":\#(extra)}}}}"#
            return try ClaudeCodeCLI.parseUsage(object(json), now: now).credits
        }
        #expect(try credits(#"{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}"#) == nil)
        #expect(try credits("null") == nil)
        #expect(try credits(#"{"is_enabled":true,"monthly_limit":null,"used_credits":1250,"utilization":null}"#) == Credits(amount: 12.5, currency: "USD", label: "extra usage"))
        #expect(try credits(#"{"is_enabled":true,"monthly_limit":100000,"used_credits":1250,"utilization":1,"currency":"JPY"}"#) == Credits(amount: 1250, currency: "JPY", label: "extra usage"))
    }

    @Test func signedOutIsNotConnected() throws {
        let json = #"{"type":"control_response","response":{"subtype":"success","request_id":"u","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null,"behaviors":null}}}"#
        #expect(throws: UsageError.notConnected) { try ClaudeCodeCLI.parseUsage(object(json), now: now) }
    }

    @Test func errorsAreReported() throws {
        let error = #"{"type":"control_response","response":{"subtype":"error","request_id":"u","error":"get_usage is not supported in this context"}}"#
        #expect(throws: UsageError.unexpected("get_usage is not supported in this context")) { try ClaudeCodeCLI.parseUsage(object(error), now: now) }
        let noLimits = #"{"type":"control_response","response":{"subtype":"success","request_id":"u","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":null}}}"#
        #expect(throws: UsageError.unexpected("Claude Code returned no limits")) { try ClaudeCodeCLI.parseUsage(object(noLimits), now: now) }
        #expect(throws: UsageError.self) { try ClaudeCodeCLI.parseUsage(object(#"{"type":"control_response"}"#), now: now) }
    }
}

@Suite struct ClaudeCodeCLITests {
    @Test func existingDefaultSignInUsesItsNativeIdentityAndEnvironment() throws {
        let home = try TempHome()
        try home.writeJSON(".claude.json", ["oauthAccount": ["accountUuid": "account", "organizationUuid": "org"]])
        let cli = ClaudeCodeCLI(paths: home.paths)
        let dir = home.paths.claudeSharedConfigDir
        #expect(cli.identity(configDir: dir)?.accountUuid == "account")
        #expect(cli.environment(dir)["CLAUDE_CONFIG_DIR"] == nil)
        let key = try #require(ClaudeAccountKey(account: "account", org: "org"))
        #expect(cli.signIns([], for: [key])[key] == dir.path)
        let other = try #require(ClaudeAccountKey(account: "another-account", org: "org"))
        #expect(cli.signIns([], for: [other]).isEmpty)
    }

    @discardableResult
    func executable(_ home: TempHome, _ relative: String) throws -> URL {
        let file = try home.write(relative, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func picksTheInstalledCLIElseTheNewestBundledOneButNeverCodexsGuard() throws {
        let home = try TempHome()
        let cli = ClaudeCodeCLI(paths: home.paths)
        #expect(cli.executable() == nil)

        let guardScript = try executable(home, ".codex/bin/claude")
        try FileManager.default.createDirectory(at: home.url.appending(path: ".local/bin"), withIntermediateDirectories: true)
        let link = home.url.appending(path: ".local/bin/claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: guardScript)
        #expect(cli.executable() == nil)

        let bundled = "Library/Application Support/Claude/claude-code"
        try executable(home, "\(bundled)/2.1.99/abc/claude.app/Contents/MacOS/claude")
        let newest = try executable(home, "\(bundled)/2.1.285/def/claude.app/Contents/MacOS/claude")
        #expect(cli.executable()?.path == newest.path)

        try FileManager.default.removeItem(at: link)
        let installed = try executable(home, ".local/share/claude/versions/2.1.300")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
        #expect(cli.executable()?.path == installed.resolvingSymlinksInPath().path)
    }

    @Test func signInHandsOverItsLinkOnce() async throws {
        let home = try TempHome()
        // A stand-in for Anthropic's CLI: hands its sign-in link to $BROWSER, waits for the browser, then finishes.
        let fake = try home.write(".local/bin/claude", """
        #!/bin/sh
        "$BROWSER" 'https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&login_hint=a%40b.c'
        sleep 1
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let cli = ClaudeCodeCLI(paths: home.paths)
        let seen = LinkHolder()
        try await cli.login(configDir: cli.configDir(for: UUID()), email: "a@b.c") { url in seen.add(url) }
        // The helper only writes the link down; OpenAccs opens it, so it must arrive exactly once.
        #expect(seen.urls.count == 1)
        #expect(seen.urls.first?.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost") == true)
    }

    @Test func configDirAndIdentity() throws {
        let home = try TempHome()
        let cli = ClaudeCodeCLI(paths: home.paths)
        let id = UUID()
        let dir = cli.configDir(for: id)
        // One folder per sign-in, apart from the windows' folders. The CLI names its Keychain item after
        // this exact string, so a stored path must come back byte for byte.
        #expect(dir.path == home.paths.appSupport.path + "/Claude Code/\(id.uuidString)")
        #expect(cli.environment(dir)["CLAUDE_CONFIG_DIR"] == dir.path)
        #expect(cli.environment(URL(filePath: dir.path, directoryHint: .isDirectory))["CLAUDE_CONFIG_DIR"] == dir.path)
        #expect(cli.identity(configDir: dir) == nil)
        try home.writeJSON("Library/Application Support/OpenAccs/Claude Code/\(id.uuidString)/.claude.json", [
            "oauthAccount": [
                "emailAddress": "work@example.com", "organizationName": "Example",
                "accountUuid": "11111111-1111-4111-8111-111111111111", "organizationUuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ],
            "userID": "x",
        ])
        #expect(cli.identity(configDir: dir) == ClaudeCLIIdentity(
            email: "work@example.com", organization: "Example", accountUuid: "11111111-1111-4111-8111-111111111111",
            organizationUuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ))
    }

    let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222"
    let c = "33333333-3333-4333-8333-333333333333"
    let o = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", p = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    /// A Claude Code folder under the test home, signed in as `account` (nil: a sign-in that never finished).
    func signedIn(_ home: TempHome, _ name: String, _ account: [String: String]?) throws -> String {
        var json: [String: Any] = ["userID": "x"]
        if let account { json["oauthAccount"] = account }
        try home.writeJSON("Library/Application Support/OpenAccs/Claude Code/\(name)/.claude.json", json)
        return home.paths.appSupport.appending(path: "Claude Code/\(name)", directoryHint: .notDirectory).path
    }

    func key(_ account: String, _ org: String) throws -> ClaudeAccountKey {
        try #require(ClaudeAccountKey(account: account, org: org))
    }

    @Test func eachAccountUsesTheFirstFolderSignedInToIt() throws {
        let home = try TempHome()
        let cli = ClaudeCodeCLI(paths: home.paths)
        let d1 = try signedIn(home, "D1", ["accountUuid": a, "organizationUuid": o.uppercased(), "emailAddress": "a@example.com"])
        let d2 = try signedIn(home, "D2", nil)
        let d3 = try signedIn(home, "D3", ["accountUuid": b, "organizationUuid": o])
        let d4 = try signedIn(home, "D4", ["accountUuid": a, "organizationUuid": o])
        let d5 = try signedIn(home, "D5", ["accountUuid": a])
        let missing = home.paths.appSupport.appending(path: "Claude Code/gone", directoryHint: .notDirectory).path
        let (ao, bo, co, ap) = (try key(a, o), try key(b, o), try key(c, o), try key(a, p))

        // The first folder signed in to an account serves it, whichever window stored it; an unfinished
        // sign-in or a folder that's gone serves nobody.
        #expect(cli.signIns([missing, d2, d1, d3, d4], for: [ao, bo, co]) == [ao: d1, bo: d3])
        // A CLI that names no organization counts for its account in any of them.
        #expect(cli.signIns([d5], for: [ao, ap]) == [ao: d5, ap: d5])
        #expect(cli.signIns([], for: [ao]).isEmpty)
        // A folder Claude Code says is signed out gives way to another folder of its account, and serves only alone.
        #expect(cli.signIns([d1, d4], for: [ao], signedOut: [d1]) == [ao: d4])
        #expect(cli.signIns([d1], for: [ao], signedOut: [d1]) == [ao: d1])
    }

    @Test func aNewSignInReplacesEveryEarlierOneOfItsAccount() throws {
        let home = try TempHome()
        let cli = ClaudeCodeCLI(paths: home.paths)
        let oldA = try signedIn(home, "oldA", ["accountUuid": a, "organizationUuid": o])
        let oldB = try signedIn(home, "oldB", ["accountUuid": b, "organizationUuid": o])
        let who = ClaudeCLIIdentity(email: "a@example.com", organization: "Example", accountUuid: a.uppercased(), organizationUuid: o)
        let w = (0..<7).map { _ in UUID() }
        let (ao, bo, ap) = (try key(a, o), try key(b, o), try key(a, p))
        let windows: [(id: UUID, key: ClaudeAccountKey?, dir: String?)] = [
            (w[0], ao, nil), (w[1], ao, oldA), (w[2], bo, oldA), (w[3], bo, nil), (w[4], ap, nil), (w[5], nil, nil), (w[6], bo, oldB),
        ]
        // Every window showing that account and org, plus a window that moved on but still holds the
        // account's old folder; never another account's windows, another org, or a window of unknown account.
        #expect(cli.sharing(who, among: windows) == [w[0], w[1], w[2]])
        #expect(who.matches(ao) && !who.matches(ap) && !who.matches(bo))
    }

    @Test func privateWindowsOfTheDefaultBrowser() {
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.brave.browser",
                   "com.brave.Browser.origin", "org.chromium.Chromium"] {
            #expect(ClaudeCodeCLI.privateWindowFlag(browser: id) == "--incognito", "\(id)")
        }
        for id in ["com.microsoft.edgemac", "com.microsoft.edgemac.Dev"] {
            #expect(ClaudeCodeCLI.privateWindowFlag(browser: id) == "--inprivate", "\(id)")
        }
        for id in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] {
            #expect(ClaudeCodeCLI.privateWindowFlag(browser: id) == "--private-window", "\(id)")
        }
        for id in ["com.apple.Safari", "company.thebrowser.Browser", "com.google.chromeremotedesktop", ""] {
            #expect(ClaudeCodeCLI.privateWindowFlag(browser: id) == nil, "\(id)")
        }
    }
}

private final class LinkHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    func add(_ url: URL) { lock.withLock { seen.append(url) } }
    var urls: [URL] { lock.withLock { seen } }
}

@Suite struct ClaudeLimitsTests {
    let now = Date(timeIntervalSince1970: 1_760_970_000)

    func answer(_ age: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(plan: "Max", windows: [UsageWindow(kind: .fiveHour, usedPercent: 40, resetsAt: now.addingTimeInterval(3600))],
                      asOf: now.addingTimeInterval(-age), source: "Claude Code")
    }

    func row(account: Bool = true, signIn: Bool = true, answer: UsageSnapshot? = nil, problem: UsageError? = nil) -> ClaudeLimits.Row {
        ClaudeLimits.row(account: account, signIn: signIn, answer: answer, problem: problem, now: now)
    }

    @Test func liveForHalfAnHourElseOneLineWhy() {
        let fresh = answer(10 * 60)
        #expect(row(account: false, answer: fresh) == ClaudeLimits.Row(usage: nil, note: "Open this window once to connect live limits", connect: false))
        #expect(row(signIn: false, answer: fresh) == ClaudeLimits.Row(usage: nil, note: "No live limits", connect: true))
        #expect(row(answer: fresh) == ClaudeLimits.Row(usage: fresh, note: nil, connect: false))
        // One failed ask doesn't end numbers that are still young.
        #expect(row(answer: fresh, problem: .unexpected("Claude Code did not answer")) == ClaudeLimits.Row(usage: fresh, note: nil, connect: false))
        // Signed out ends them at once.
        #expect(row(answer: answer(2 * 60), problem: .needsSignIn) == ClaudeLimits.Row(usage: nil, note: "Limits signed out", connect: true))
        // Live for 30 minutes, not a second longer.
        #expect(row(answer: answer(30 * 60 - 1)).usage != nil)
        #expect(row(answer: answer(30 * 60)).usage == nil)
        #expect(row(answer: answer(31 * 60), problem: .unexpected("Claude Code did not answer"))
                == ClaudeLimits.Row(usage: nil, note: "Claude Code did not answer", connect: true))
        #expect(row(problem: .unexpected("Claude Code is not installed")) == ClaudeLimits.Row(usage: nil, note: "Claude Code is not installed", connect: true))
        // Connected and about to be asked (just launched, or awake after a sleep): nothing to say yet.
        #expect(row(answer: answer(8 * 3600)) == ClaudeLimits.Row(usage: nil, note: nil, connect: false))
        #expect(row() == ClaudeLimits.Row(usage: nil, note: nil, connect: false))
    }
}
