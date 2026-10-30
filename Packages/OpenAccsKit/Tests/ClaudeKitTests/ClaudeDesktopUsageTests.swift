import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

@Suite struct ClaudeDesktopUsageTests {
    @Test func decryptsChromium24AndChecksTheHostBinding() throws {
        let hex = "763130719ccd9854a7487b8063751d04ae0be4810df9dde52e88fe5c50f1f6a52042d89b03d144e43f02a2e2584debb858313993c6ec1a47e86f3688cfc7eda9fff4b2"
        let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { i in UInt8(hex.dropFirst(i).prefix(2), radix: 16)! })
        #expect(try ClaudeDesktopUsage.decrypt(bytes, password: Data("fixture-pass".utf8), host: ".claude.ai", version: 24) == "sk-ant-fixture-only")
        #expect(throws: (any Error).self) { try ClaudeDesktopUsage.decrypt(bytes, password: Data("fixture-pass".utf8), host: "claude.ai", version: 24) }
        #expect(throws: (any Error).self) { try ClaudeDesktopUsage.decrypt(bytes, password: Data("wrong".utf8), host: ".claude.ai", version: 24) }
    }

    @Test func verifiesTheAccountBeforeFetchingItsExactOrganization() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-a"}"#))
        http.on("https://claude.ai/api/organizations/org-a/usage", .init(json: #"{"five_hour":{"utilization":12,"resets_at":"2026-11-01T12:00:00Z"},"seven_day":{"utilization":37}}"#))
        let reader = ClaudeDesktopUsage(http: http)
        let key = ClaudeAccountKey(account: "account-a", org: "org-a")!
        let result = try await reader.fetch(session: "sk-ant-test", account: key)
        #expect(result.window(.fiveHour)?.usedPercent == 12)
        #expect(result.window(.weekly)?.usedPercent == 37)
        #expect(result.window(.fiveHour)?.resetsAt != nil)
        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy { $0.url?.host == "claude.ai" })
    }

    @Test func aDifferentLoginNeverSuppliesNumbersForTheOldAccount() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-b"}"#))
        let reader = ClaudeDesktopUsage(http: http)
        await #expect(throws: UsageError.needsSignIn) {
            try await reader.fetch(session: "sk-ant-test", account: ClaudeAccountKey(account: "account-a", org: "org-a")!)
        }
        #expect(http.requests.count == 1)
    }
}
