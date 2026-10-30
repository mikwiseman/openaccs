import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

@Suite struct ClaudeAppUsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sameOrganizationDoesNotMixDifferentAccounts() throws {
        let home = try TempHome()
        let first = ClaudeProfile(dataDir: home.url.appending(path: "first"), isDefault: false, accountUuid: "one", orgUuid: "org")
        let duplicate = ClaudeProfile(dataDir: home.url.appending(path: "duplicate"), isDefault: false, accountUuid: "one", orgUuid: "org")
        let other = ClaudeProfile(dataDir: home.url.appending(path: "other"), isDefault: false, accountUuid: "two", orgUuid: "org")
        for (folder, time, used) in [("first", 1_800_000_000_000, 10), ("duplicate", 1_800_000_060_000, 20), ("other", 1_800_000_120_000, 90)] {
            try home.writeJSON("\(folder)/plan-usage-history.json", ["version": 2, "samples": [["t": time, "org": "org", "u": ["fh": used]]]])
        }
        let key = try #require(ClaudeAccountKey(account: "one", org: "org"))
        #expect(ClaudeAppUsage.read(profiles: [first, duplicate, other], account: key)?.window(.fiveHour)?.usedPercent == 20)
    }

    @Test func ignoresUnknownOrganizationsFutureSamplesAndInvalidPercentages() throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "samples": [
            ["t": now.timeIntervalSince1970 * 1000, "org": "ours", "u": ["fh": 12, "sd": 63]],
            ["t": (now + 3600).timeIntervalSince1970 * 1000, "org": "ours", "u": ["fh": 0, "sd": 0]],
        ]])
        #expect(ClaudeAppUsage.parse(data, org: nil) == nil)
        #expect(ClaudeAppUsage.parse(data, org: "other") == nil)
        // Parse preserves the measured timestamp; read/current rejects future and expired readings.
        let future = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 0)], asOf: now + 3600, source: ClaudeAppUsage.source)
        #expect(ClaudeAppUsage.current(future, now: now) == nil)
        let invalid = Data(#"{"version":2,"samples":[{"t":1800000000000,"org":"ours","u":{"fh":-1,"sd":101}}]}"#.utf8)
        #expect(ClaudeAppUsage.parse(invalid, org: "ours") == nil)
    }

    @Test func savedReadingsNeverInventResetsAndAgeOutByWindow() throws {
        let data = Data(#"{"version":2,"samples":[{"t":1800000000000,"org":"ours","u":{"fh":25,"sd":61}}]}"#.utf8)
        let usage = try #require(ClaudeAppUsage.parse(data, org: "ours"))
        #expect(usage.windows.map(\.usedPercent) == [25, 61])
        #expect(usage.windows.allSatisfy { $0.resetsAt == nil })
        #expect(usage.asOf == now)
        #expect(ClaudeAppUsage.current(usage, now: now + 5 * 3600)?.windows.map(\.kind) == [.weekly])
        #expect(ClaudeAppUsage.current(usage, now: now + 7 * 86400) == nil)
        #expect(!usage.isCurrent(now: now + 1801))
    }
}
