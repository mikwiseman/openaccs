import Foundation
import OpenAccsCore
import Testing
@testable import LimitsKit

@Suite struct GrokCLITests {
    let now = Date(timeIntervalSince1970: 1_792_480_000)

    func json(_ text: String) throws -> [String: Any] {
        try #require(JSON.object(Data(text.utf8)))
    }

    @Test func mapsWeeklyCreditsConfig() throws {
        let s = GrokCLI.snapshot(billing: try json("""
        {"config":{"creditUsagePercent":42.5,
           "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-16T21:53:15Z","end":"2026-10-23T21:53:15Z"},
           "billingPeriodEnd":"2026-11-01T00:00:00Z","onDemandCap":{"val":5000},"prepaidBalance":{"val":-1250},
           "isUnifiedBillingUser":true},
         "on_demand_enabled":true,"subscription_tier":"SuperGrok Heavy"}
        """), now: now)
        #expect(s.plan == "SuperGrok Heavy")
        #expect(s.source == "Grok CLI")
        #expect(s.asOf == now)
        #expect(s.windows == [UsageWindow(kind: .weekly, usedPercent: 42.5, resetsAt: JSON.date("2026-10-23T21:53:15Z"))])
        #expect(s.credits == Credits(amount: 12.5, currency: "USD", label: "balance"))
    }

    @Test func mapsMonthlyAndProto3Zeros() throws {
        // proto3 omits zero values: no percent with a period = 0 %, `{}` balance = $0 (no credits shown).
        let s = GrokCLI.snapshot(billing: try json("""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-10-01T00:00:00Z","end":"2026-11-01T00:00:00Z"},
                   "prepaidBalance":{}},
         "subscriptionTier":"SuperGrok"}
        """), now: now)
        #expect(s.plan == "SuperGrok")
        #expect(s.windows == [UsageWindow(kind: .monthly, usedPercent: 0, resetsAt: JSON.date("2026-11-01T00:00:00Z"))])
        #expect(s.credits == nil)
    }

    @Test func periodKindFallsBackToLength() {
        #expect(GrokCLI.kind(["start": "2026-10-16T00:00:00Z", "end": "2026-10-23T00:00:00Z"]) == .weekly)
        #expect(GrokCLI.kind(["start": "2026-10-01T00:00:00Z", "end": "2026-10-31T00:00:00Z"]) == .monthly)
        #expect(GrokCLI.kind(["type": "USAGE_PERIOD_TYPE_UNSPECIFIED"]) == .other)
        #expect(GrokCLI.kind(nil) == .other)
    }

    @Test func noConfigOrNoPeriodMeansUnknownNotZero() throws {
        let free = GrokCLI.snapshot(billing: try json(#"{"config":null,"subscription_tier":"Free"}"#), now: now)
        #expect(free.plan == "Free" && free.windows.isEmpty && free.credits == nil)
        let legacy = GrokCLI.snapshot(billing: try json(#"{"config":{"monthlyLimit":{"val":2000},"used":{"val":1234}}}"#), now: now)
        #expect(legacy.plan == nil && legacy.windows.isEmpty)
    }

    @Test func billingErrors() throws {
        func map(_ error: String?) throws -> (UsageError, Bool) {
            let reply = try error.map { try json(#"{"jsonrpc":"2.0","id":2,"error":"# + $0 + "}") }
            let r = GrokCLI.billingError(reply)
            return (r.0, r.retry)
        }
        // Exactly what grok 1.0.52 answers in an empty GROK_HOME.
        let auth = try map(#"{"code":-32000,"message":"Authentication required","data":"Authentication required to fetch billing data"}"#)
        #expect(auth.0 == .notConnected && !auth.1)
        let expired = try map(#"{"code":-32603,"message":"Internal error","data":"Billing service error: HTTP 401"}"#)
        #expect(expired.0 == .needsSignIn && expired.1)
        let upstream = try map(#"{"code":-32603,"message":"Internal error","data":"Billing service error: upstream unavailable"}"#)
        #expect(upstream.0 == .unexpected("Grok: Billing service error: upstream unavailable") && upstream.1)
        let other = try map(#"{"code":-32603,"message":"Internal error","data":"Failed to parse billing data: eof"}"#)
        #expect(other.0 == .unexpected("Grok: Failed to parse billing data: eof") && !other.1)
        let silent = try map(nil)
        #expect(silent.0 == .unexpected("Grok CLI did not answer") && !silent.1)
    }

    @Test func homeExecutableAndIdentity() throws {
        let root = try makeTempDir("grokcli")
        let cli = GrokCLI(paths: Paths(home: root))
        let id = UUID()
        #expect(cli.home(for: id).path == root.path + "/Library/Application Support/OpenAccs/Grok/" + id.uuidString)

        let bin = root.appending(path: ".grok/bin/grok")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        #expect(cli.executable()?.path == bin.path)

        let home = cli.home(for: id)
        #expect(cli.identity(home: home) == nil)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("""
        {"xai-api-key":{"key":"not-a-real-key","email":"api@example.com"},
         "https://auth.x.ai::b1a00492":{"key":"not-a-real-token","refresh_token":"not-a-real-refresh","expires_at":"2026-09-29T01:09:46Z",
           "user_id":"u1","team_id":"t1","principal_type":"User","email":"me@example.com","auth_mode":"oidc"}}
        """.utf8).write(to: home.appending(path: "auth.json"))
        #expect(cli.identity(home: home) == "me@example.com")
    }

    // MARK: - usage() against a fake `grok agent stdio`

    /// A stand-in CLI that answers `initialize` and `_x.ai/billing` from `$GROK_HOME/billing-<n>.json`
    /// (falling back to `billing.json`), and leaves `$GROK_HOME/stdin-closed` once stdin hits EOF.
    func fakeGrok(root: URL) throws -> (GrokCLI, URL) {
        let script = """
        #!/bin/sh
        n=0
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) printf '{"jsonrpc":"2.0","method":"note","params":{}}\\n{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\\n' "$id" ;;
            *'"_x.ai/billing"'*)
              n=$((n+1)); f="$GROK_HOME/billing-$n.json"; [ -f "$f" ] || f="$GROK_HOME/billing.json"
              printf '{"jsonrpc":"2.0","id":%s,%s}\\n' "$id" "$(cat "$f")" ;;
          esac
        done
        touch "$GROK_HOME/stdin-closed"
        """
        let bin = root.appending(path: ".grok/bin/grok")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let cli = GrokCLI(paths: Paths(home: root))
        let home = cli.home(for: UUID())
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: "auth.json"))
        return (cli, home)
    }

    @Test func usageThroughFakeAgent() async throws {
        let (cli, home) = try fakeGrok(root: try makeTempDir("grok-ok"))
        try Data("""
        "result":{"config":{"creditUsagePercent":61.2,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-16T21:53:15Z","end":"2026-10-23T21:53:15Z"},"prepaidBalance":{"val":500}},"subscription_tier":"SuperGrok"}
        """.utf8).write(to: home.appending(path: "billing.json"))
        let s = try await cli.usage(home: home)
        #expect(s.plan == "SuperGrok")
        #expect(s.window(.weekly)?.usedPercent == 61.2)
        #expect(s.window(.weekly)?.resetsAt == JSON.date("2026-10-23T21:53:15Z"))
        #expect(s.credits?.amount == 5)
        // The agent is shut down by closing stdin (it exits on its own), not killed.
        var closed = false
        for _ in 0..<40 where !closed {
            try await Task.sleep(for: .milliseconds(50))
            closed = FileManager.default.fileExists(atPath: home.appending(path: "stdin-closed").path)
        }
        #expect(closed)
    }

    @Test func usageRetriesWhileTokenRefreshes() async throws {
        let (cli, home) = try fakeGrok(root: try makeTempDir("grok-retry"))
        try Data(#""error":{"code":-32603,"message":"Internal error","data":"Billing service error: HTTP 401"}"#.utf8)
            .write(to: home.appending(path: "billing-1.json"))
        try Data(#""result":{"config":{"creditUsagePercent":5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}"#.utf8)
            .write(to: home.appending(path: "billing.json"))
        let s = try await cli.usage(home: home)
        #expect(s.window(.weekly)?.usedPercent == 5)
    }

    @Test func usageWhenSignedOut() async throws {
        let (cli, home) = try fakeGrok(root: try makeTempDir("grok-auth"))
        try Data(#""error":{"code":-32000,"message":"Authentication required","data":"Authentication required to fetch billing data"}"#.utf8)
            .write(to: home.appending(path: "billing.json"))
        await #expect(throws: UsageError.notConnected) { try await cli.usage(home: home) }
        // No auth.json at all: no process is started.
        try FileManager.default.removeItem(at: home.appending(path: "auth.json"))
        await #expect(throws: UsageError.notConnected) { try await cli.usage(home: home) }
    }
}
