import Foundation
import OpenAccsCore
import Testing
@testable import LimitsKit

@Suite struct ZaiUsageTests {
    let url = "https://api.z.ai/api/monitor/usage/quota/limit"

    @Test func legacyPlanMapsFiveHourWeeklyAndMCP() async throws {
        let reset5h = msFromNow(2 * 3600), resetWeek = msFromNow(3 * 86400), resetMonth = msFromNow(20 * 86400)
        let http = StubHTTPClient()
        http.on(url, .init(json: """
        {"code":200,"msg":"操作成功","success":true,"data":{"level":"pro","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":14,"nextResetTime":\(reset5h)},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"usage":1000,"currentValue":250,"remaining":750,"percentage":25,"nextResetTime":\(resetWeek)},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":147,"remaining":853,"percentage":14,"nextResetTime":\(resetMonth),
           "usageDetails":[{"modelCode":"search-prime","usage":147}]}
        ]}}
        """))
        let s = try await ZaiUsage(http: http).fetch(apiKey: " key.secret \n", region: .global)
        #expect(s.plan == "Pro")
        #expect(s.source == "API key")
        #expect(s.window(.fiveHour)?.usedPercent == 14)
        #expect(s.window(.fiveHour)?.resetsAt == Date(timeIntervalSince1970: Double(reset5h) / 1000))
        #expect(s.window(.weekly)?.usedPercent == 25)
        let mcp = try #require(s.windows.first { $0.label == "MCP" })
        #expect(mcp.kind == .monthly)
        #expect(abs(mcp.usedPercent - 14.7) < 1e-9)
        #expect(s.windows.count == 3)
        // The raw key, trimmed, without "Bearer".
        #expect(http.requests.count == 1)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "key.secret")
    }

    @Test func creditPlanUsesExactCountsSkipsUnknownAndDropsImpossibleReset() async throws {
        let http = StubHTTPClient()
        http.on(url, .init(json: """
        {"code":200,"success":true,"data":{"level":"lite","limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":71,"remaining":1929,"percentage":3,"nextResetTime":\(msFromNow(10 * 3600))},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":100,"remaining":9900,"percentage":1},
          {"type":"CREDIT_LIMIT","unit":1,"number":1,"usage":5,"currentValue":5},
          {"type":"SOMETHING_NEW","unit":3,"number":5,"percentage":99},
          {"type":"TOKENS_LIMIT","unit":3,"number":5}
        ]}}
        """))
        let s = try await ZaiUsage(http: http).fetch(apiKey: "k", region: .global)
        #expect(s.plan == "Lite")
        #expect(s.windows.count == 2)
        #expect(abs((s.window(.fiveHour)?.usedPercent ?? 0) - 3.55) < 1e-9)
        #expect(s.window(.fiveHour)?.resetsAt == nil)   // 10 h away is impossible for a rolling 5h window
        #expect(s.window(.weekly)?.usedPercent == 1)
        #expect(s.window(.weekly)?.resetsAt == nil)
    }

    @Test func noCodingPlan() async throws {
        let http = StubHTTPClient()
        http.on(url, .init(json: #"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#))
        await #expect(throws: UsageError.noPlan) { try await ZaiUsage(http: http).fetch(apiKey: "k", region: .global) }

        let empty = StubHTTPClient()
        empty.on(url, .init(json: #"{"code":200,"msg":"No Coding Plan for this account","success":true,"data":{"limits":[]}}"#))
        await #expect(throws: UsageError.noPlan) { try await ZaiUsage(http: empty).fetch(apiKey: "k", region: .global) }
    }

    @Test func otherFailuresAreUnexpected() async throws {
        let http = StubHTTPClient()
        http.on(url, .init(json: #"{"code":500,"msg":"系统繁忙","success":false}"#))
        await #expect(throws: UsageError.unexpected("Z.ai: 系统繁忙")) { try await ZaiUsage(http: http).fetch(apiKey: "k", region: .global) }

        let flagged = StubHTTPClient()
        flagged.on(url, .init(json: #"{"code":200,"success":false,"data":{"limits":[]}}"#))
        await #expect(throws: UsageError.unexpected("Z.ai: code 200")) { try await ZaiUsage(http: flagged).fetch(apiKey: "k", region: .global) }

        let down = StubHTTPClient()
        down.on(url, .init(status: 503, json: "<html>"))
        await #expect(throws: UsageError.unexpected("Z.ai HTTP 503")) { try await ZaiUsage(http: down).fetch(apiKey: "k", region: .global) }
    }

    @Test func retriesOnceWithBearerOnJSONAuthFailure() async throws {
        let http = StubHTTPClient()
        http.on(url,
                .init(json: #"{"code":1000,"msg":"Authentication Failed","success":false}"#),
                .init(json: #"{"code":0,"success":true,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40}]}}"#))
        let s = try await ZaiUsage(http: http).fetch(apiKey: "k", region: .global)
        #expect(s.plan == "Max")
        #expect(s.window(.fiveHour)?.usedPercent == 40)
        #expect(http.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["k", "Bearer k"])
    }

    @Test func retriesOnHTTP401ThenGivesUp() async throws {
        let http = StubHTTPClient()
        http.on(url, .init(status: 401, json: "{}"), .init(json: #"{"code":1001,"success":false}"#))
        await #expect(throws: UsageError.needsSignIn) { try await ZaiUsage(http: http).fetch(apiKey: "k", region: .global) }
        #expect(http.requests.count == 2)
    }

    @Test func chinaHostAndEmptyKey() async throws {
        let http = StubHTTPClient()
        http.on("https://open.bigmodel.cn/api/monitor/usage/quota/limit",
                .init(json: #"{"code":200,"success":true,"data":{"level":"pro","limits":[]}}"#))
        let s = try await ZaiUsage(http: http).fetch(apiKey: "k", region: .china)
        #expect(s.plan == "Pro" && s.windows.isEmpty)
        await #expect(throws: UsageError.notConnected) { try await ZaiUsage(http: http).fetch(apiKey: "  ", region: .china) }
    }
}
