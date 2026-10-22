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

@Suite struct ClaudeAppUsageTests {
    let orgA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let orgB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test func latestSampleOfTheProfilesOrg() throws {
        let history = """
            {"version":2,"samples":[
              {"t":1760950000000,"org":"\(orgA)","u":{"fh":10,"sd":20,"so":30,"sn":40}},
              {"t":1760960000000,"org":"\(orgA)","u":{"fh":12.5,"sd":22,"so":33,"sn":44,"oa":1,"cw":2,"om":3,"op":4,"xu":5}},
              {"t":1760955000000,"org":"\(orgA)","u":{"fh":11}},
              {"t":1760990000000,"org":"\(orgB)","u":{"fh":90,"sd":91}}
            ]}
            """
        let usage = try #require(ClaudeAppUsage.parse(Data(history.utf8), org: orgA))

        #expect(usage.asOf == Date(timeIntervalSince1970: 1_760_960_000))
        #expect(usage.source == "Claude app")
        #expect(usage.windows == [
            UsageWindow(kind: .fiveHour, usedPercent: 12.5),
            UsageWindow(kind: .weekly, usedPercent: 22),
            UsageWindow(kind: .weekly, label: "Opus", usedPercent: 33),
            UsageWindow(kind: .weekly, label: "Sonnet", usedPercent: 44),
        ])
        #expect(usage.window(.fiveHour)?.resetsAt == nil)

        let other = try #require(ClaudeAppUsage.parse(Data(history.utf8), org: orgB))
        #expect(other.windows == [UsageWindow(kind: .fiveHour, usedPercent: 90), UsageWindow(kind: .weekly, usedPercent: 91)])
        #expect(other.asOf == Date(timeIntervalSince1970: 1_760_990_000))
    }

    @Test func readsTheProfilesHistoryFile() throws {
        let home = try TempHome()
        let profile = ClaudeProfile(dataDir: home.url.appending(path: "Data", directoryHint: .isDirectory), isDefault: false, accountUuid: "a", orgUuid: orgA)
        #expect(ClaudeAppUsage.read(profile: profile) == nil)
        try home.write("Data/plan-usage-history.json", #"{"version":2,"samples":[{"t":1760960000000,"org":"\#(orgA)","u":{"fh":7,"sd":8}}]}"#)
        #expect(ClaudeAppUsage.read(profile: profile)?.window(.weekly)?.usedPercent == 8)
    }

    @Test func emptyOrGarbledIsNil() {
        for text in ["", "garbled{", "[]", "{}", #"{"version":2}"#, #"{"version":2,"samples":[]}"#,
                     #"{"samples":[{"t":1760960000000,"org":"x"}]}"#, #"{"samples":[{"t":1760960000000,"u":{"oa":1}}]}"#,
                     #"{"samples":[{"u":{"fh":1}}]}"#, #"{"samples":"no"}"#] {
            #expect(ClaudeAppUsage.parse(Data(text.utf8), org: orgA) == nil, "\(text)")
        }
    }
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

    @Test func signInPassesOnTheLinkItOpens() async throws {
        let home = try TempHome()
        // A stand-in for Anthropic's CLI: opens its sign-in link through $BROWSER, then finishes.
        let fake = try home.write(".local/bin/claude", """
        #!/bin/sh
        "$BROWSER" 'https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&login_hint=a%40b.c'
        sleep 1
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var cli = ClaudeCodeCLI(paths: home.paths)
        cli.opener = "/usr/bin/true"   // never a real browser in tests
        let link = Flag()
        let seen = LinkHolder()
        try await cli.login(configDir: cli.configDir(for: UUID()), email: "a@b.c") { url in
            seen.url = url
            link.set()
        }
        #expect(link.isSet)
        #expect(seen.url?.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost") == true)
    }

    @Test func configDirAndIdentity() throws {
        let home = try TempHome()
        let cli = ClaudeCodeCLI(paths: home.paths)
        let id = UUID()
        let dir = cli.configDir(for: id)
        #expect(dir.path == home.paths.appSupport.path + "/Claude/\(id.uuidString)/Code")
        #expect(cli.environment(dir)["CLAUDE_CONFIG_DIR"] == dir.path)
        #expect(cli.identity(configDir: dir) == nil)
        try home.writeJSON("Library/Application Support/OpenAccs/Claude/\(id.uuidString)/Code/.claude.json", [
            "oauthAccount": [
                "emailAddress": "work@example.com", "organizationName": "Example",
                "accountUuid": "11111111-1111-4111-8111-111111111111", "organizationUuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ],
            "userID": "x",
        ])
        #expect(cli.identity(configDir: dir) == ClaudeCLIIdentity(
            email: "work@example.com", organization: "Example", accountUuid: "11111111-1111-4111-8111-111111111111"
        ))
    }
}

private final class LinkHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    var url: URL? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
