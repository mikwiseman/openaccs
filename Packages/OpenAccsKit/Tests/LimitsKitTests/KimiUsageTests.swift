import Foundation
import OpenAccsCore
import Testing
@testable import LimitsKit

@Suite struct KimiUsageTests {
    @Test func currentShapeWithPlanAndWallet() async throws {
        let base = "https://api.kimi.com/coding/v1"
        let http = StubHTTPClient()
        http.on(base + "/usages", .init(json: """
        {"usages":{
           "limit_5h":{"used_ratio":0.25,"reset_time":"2026-10-20T13:00:00.443553353Z"},
           "limit_7d":{"used_ratio":"0.5","reset_time":"2026-10-24T00:00:00Z"},
           "limit_month_total":{"used_ratio":0.1},
           "limit_month_code":{"used_ratio":1.4},
           "limit_unknown":{"used_ratio":0.9}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amount":"10000000000","amountLeft":2500000000},
                          "monthlyChargeLimit":{"priceInCents":1000,"currency":"USD"}}}
        """))
        http.on(base + "/me", .init(json: #"{"user_id":"u_1","user_level":30,"user_level_name":"Vivace","email":"a@b.c"}"#))
        let s = try await KimiUsage(http: http).fetch(apiKey: "sk-kimi", region: .china)
        #expect(s.plan == "Vivace")
        #expect(s.source == "API key")
        #expect(s.window(.fiveHour)?.usedPercent == 25)
        let reset = try #require(s.window(.fiveHour)?.resetsAt?.timeIntervalSince1970)
        #expect(abs(reset - 1_792_501_200.443) < 0.001)   // nanosecond ISO string
        #expect(s.window(.weekly)?.usedPercent == 50)
        #expect(s.window(.weekly)?.resetsAt == JSON.date("2026-10-24T00:00:00Z"))
        #expect(s.window(.monthly)?.usedPercent == 10)
        #expect(s.windows.first { $0.label == "Code" }?.usedPercent == 100)   // clamped
        #expect(s.windows.count == 4)
        #expect(s.credits == Credits(amount: 25, currency: "USD", label: "wallet"))
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-kimi" })
    }

    @Test func legacyShapeWithMembershipPlan() async throws {
        let http = StubHTTPClient()
        http.on("https://api.kimi.ai/coding/v1/usages", .init(json: """
        {"usage":{"limit":"100","used":"40","remaining":"60","resetTime":"2026-10-25T00:00:00Z"},
         "limits":[
           {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"20","remaining":"15","resetTime":"2026-10-20T15:00:00Z"}},
           {"window":{"duration":2,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":10,"used":5}},
           {"window":{"duration":1,"timeUnit":"TIME_UNIT_FORTNIGHT"},"detail":{"limit":10,"used":5}}],
         "user":{"membership":{"level":"LEVEL_INTERMEDIATE"}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amount":0,"amountLeft":0}}}
        """))
        // No /me stub: the request fails and the plan falls back to the membership level.
        let s = try await KimiUsage(http: http).fetch(apiKey: "k", region: .global)
        #expect(s.plan == "Allegretto")
        #expect(s.window(.fiveHour)?.usedPercent == 25)
        #expect(s.window(.fiveHour)?.resetsAt == JSON.date("2026-10-20T15:00:00Z"))
        #expect(s.window(.weekly)?.usedPercent == 40)
        #expect(s.window(.weekly)?.resetsAt == JSON.date("2026-10-25T00:00:00Z"))
        let other = try #require(s.windows.first { $0.kind == .other })
        #expect(other.label == "2h" && other.usedPercent == 50)
        #expect(s.windows.count == 3)
        #expect(s.credits == nil)
    }

    @Test func rejectedKeyNeedsSignIn() async throws {
        let http = StubHTTPClient()
        http.on("https://api.kimi.com/coding/v1/usages", .init(status: 401, json: #"{"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}"#))
        await #expect(throws: UsageError.needsSignIn) { try await KimiUsage(http: http).fetch(apiKey: "k", region: .china) }
        #expect(http.requests.count == 1)
    }

    @Test func otherStatusIsUnexpected() async throws {
        let http = StubHTTPClient()
        http.on("https://api.kimi.com/coding/v1/usages", .init(status: 404, json: #"{"error":{"message":"The requested resource was not found"}}"#))
        await #expect(throws: UsageError.unexpected("Kimi HTTP 404")) { try await KimiUsage(http: http).fetch(apiKey: "k", region: .china) }
        await #expect(throws: UsageError.notConnected) { try await KimiUsage(http: http).fetch(apiKey: "", region: .china) }
    }
}
