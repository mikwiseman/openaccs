import Foundation
import OpenAccsCore

/// GLM Coding Plan limits for a Z.ai (global) or BigModel (China) API key:
/// `GET /api/monitor/usage/quota/limit`.
public struct ZaiUsage: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetch(apiKey: String, region: Region) async throws -> UsageSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw UsageError.notConnected }
        let url = Self.url(region)
        // Z.ai's own client sends the raw key; retry once with "Bearer " in case a host wants it.
        // A rejected key usually comes back as HTTP 200 with JSON code 1000/1001, not 401.
        var (data, status) = try await http.get(url, authorization: key)
        if Self.isAuthFailure(status, data) {
            (data, status) = try await http.get(url, authorization: "Bearer " + key)
        }
        if Self.isAuthFailure(status, data) { throw UsageError.needsSignIn }
        guard (200..<300).contains(status), let json = JSON.object(data) else {
            throw UsageError.unexpected("Z.ai HTTP \(status)")
        }
        return try Self.parse(json, now: Date())
    }

    static func url(_ region: Region) -> URL {
        switch region {
        case .global: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        case .china: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
        }
    }

    static func isAuthFailure(_ status: Int, _ data: Data) -> Bool {
        let code = JSON.double(JSON.object(data)?["code"])
        return status == 401 || code == 1000 || code == 1001
    }

    static func parse(_ json: [String: Any], now: Date) throws -> UsageSnapshot {
        let code = JSON.double(json["code"])
        let message = nonEmpty(json["msg"]) ?? ""
        guard code == 200 || code == 0, json["success"] as? Bool != false else {
            if isNoPlan(message) { throw UsageError.noPlan }
            throw UsageError.unexpected("Z.ai: " + (message.isEmpty ? "code \(code.map { Int($0) } ?? -1)" : String(message.prefix(200))))
        }
        let data = json["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []
        if limits.isEmpty, isNoPlan(message) { throw UsageError.noPlan }
        let plan = nonEmpty(data["level"]).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return UsageSnapshot(plan: plan, windows: limits.compactMap { window($0, now: now) }, asOf: now, source: "API key")
    }

    /// "当前用户不存在coding plan" (this user has no coding plan), "没有资格" (not eligible), or English equivalents.
    static func isNoPlan(_ message: String) -> Bool {
        let m = message.lowercased().replacingOccurrences(of: " ", with: "")
        return m.contains("codingplan") || m.contains("没有资格")
    }

    /// Windows are identified by type + unit + number, never by position. Unknown entries are skipped.
    static func window(_ limit: [String: Any], now: Date) -> UsageWindow? {
        guard case let (kind, label)? = classify(limit["type"] as? String, unit: JSON.double(limit["unit"]), number: JSON.double(limit["number"]))
        else { return nil }
        let percent: Double
        if let cap = JSON.double(limit["usage"]), let used = JSON.double(limit["currentValue"]), cap > 0 {
            percent = used / cap * 100   // `percentage` is a rounded integer
        } else if let p = JSON.double(limit["percentage"]) {
            percent = p
        } else {
            return nil
        }
        var resetsAt = JSON.date(limit["nextResetTime"])
        // The 5h window is rolling; a reset further out than that is bogus.
        if kind == .fiveHour, let r = resetsAt, r.timeIntervalSince(now) > 6 * 3600 { resetsAt = nil }
        return UsageWindow(kind: kind, label: label, usedPercent: percent, resetsAt: resetsAt)
    }

    /// Units: 3 = hours, 5 = months, 6 = weeks. CREDIT_LIMIT (credit plans) works like TOKENS_LIMIT.
    static func classify(_ type: String?, unit: Double?, number: Double?) -> (UsageWindow.Kind, String?)? {
        switch type {
        case "TOKENS_LIMIT", "CREDIT_LIMIT":
            if unit == 3 && number == 5 { return (.fiveHour, nil) }
            if unit == 6 { return (.weekly, nil) }
            return nil
        case "TIME_LIMIT":
            return unit == 5 ? (.monthly, "MCP") : nil
        default:
            return nil
        }
    }
}
