import Foundation
import OpenAccsCore

/// Kimi Code membership limits for a Kimi Code API key: `GET <base>/usages`, plan from `GET <base>/me`.
public struct KimiUsage: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetch(apiKey: String, region: Region) async throws -> UsageSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw UsageError.notConnected }
        let base = Self.baseURL(region)
        let (data, status) = try await http.get(base.appending(path: "usages"), authorization: "Bearer " + key)
        if status == 401 { throw UsageError.needsSignIn }
        guard (200..<300).contains(status), let usage = JSON.object(data) else {
            throw UsageError.unexpected("Kimi HTTP \(status)")
        }
        // The plan name is optional; a failed /me never fails the usage.
        let me = try? await http.get(base.appending(path: "me"), authorization: "Bearer " + key)
        let profile = me.flatMap { (200..<300).contains($0.1) ? JSON.object($0.0) : nil }
        return Self.parse(usage, profile: profile, now: Date())
    }

    static func baseURL(_ region: Region) -> URL {
        switch region {
        case .china: URL(string: "https://api.kimi.com/coding/v1")!
        case .global: URL(string: "https://api.kimi.ai/coding/v1")!
        }
    }

    static func parse(_ usage: [String: Any], profile: [String: Any]?, now: Date) -> UsageSnapshot {
        var windows = pools(usage["usages"] as? [String: Any] ?? [:])
        if windows.isEmpty { windows = legacy(usage) }
        let plan = nonEmpty(profile?["user_level_name"]) ?? membershipPlan(usage)
        return UsageSnapshot(plan: plan, windows: windows, credits: wallet(usage["boosterWallet"]), asOf: now, source: "API key")
    }

    /// Current shape: `usages.limit_*` = `{used_ratio 0–1, reset_time ISO}`.
    static func pools(_ usages: [String: Any]) -> [UsageWindow] {
        let keys: [(String, UsageWindow.Kind, String?)] = [
            ("limit_5h", .fiveHour, nil), ("limit_7d", .weekly, nil),
            ("limit_month_total", .monthly, nil), ("limit_month_code", .monthly, "Code"),
        ]
        return keys.compactMap { key, kind, label in
            guard let pool = usages[key] as? [String: Any], let ratio = JSON.double(pool["used_ratio"]) else { return nil }
            return UsageWindow(kind: kind, label: label, usedPercent: ratio * 100, resetsAt: JSON.date(pool["reset_time"]))
        }
    }

    /// Legacy shape: `limits[{window{duration, timeUnit}, detail}]` (300 minutes = 5h) plus the weekly `usage` block,
    /// each `{limit, used | remaining, resetTime}`.
    static func legacy(_ json: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        for item in json["limits"] as? [[String: Any]] ?? [] {
            let detail = item["detail"] as? [String: Any] ?? item
            guard let percent = usedPercent(detail), let minutes = minutes(item["window"] as? [String: Any]) else { continue }
            let kind: UsageWindow.Kind = minutes == 300 ? .fiveHour : minutes == 10080 ? .weekly : .other
            let label = kind == .other ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m") : nil
            windows.append(UsageWindow(kind: kind, label: label, usedPercent: percent, resetsAt: resetTime(detail)))
        }
        if let usage = json["usage"] as? [String: Any], let percent = usedPercent(usage) {
            windows.append(UsageWindow(kind: .weekly, usedPercent: percent, resetsAt: resetTime(usage)))
        }
        return windows
    }

    static func usedPercent(_ detail: [String: Any]) -> Double? {
        guard let limit = JSON.double(detail["limit"]), limit > 0,
              let used = JSON.double(detail["used"]) ?? JSON.double(detail["remaining"]).map({ limit - $0 })
        else { return nil }
        return used / limit * 100
    }

    static func resetTime(_ detail: [String: Any]) -> Date? {
        ["resetTime", "reset_time", "resetAt", "reset_at"].lazy.compactMap { JSON.date(detail[$0]) }.first
    }

    static func minutes(_ window: [String: Any]?) -> Int? {
        guard let duration = JSON.double(window?["duration"]), duration > 0 else { return nil }
        switch window?["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return Int(duration)
        case "TIME_UNIT_HOUR": return Int(duration) * 60
        case "TIME_UNIT_DAY": return Int(duration) * 1440
        default: return nil
        }
    }

    /// Fallback plan from `user.membership.level` (V1 membership names).
    static func membershipPlan(_ json: [String: Any]) -> String? {
        let membership = (json["user"] as? [String: Any])?["membership"] as? [String: Any]
        guard let level = nonEmpty(membership?["level"]), level != "LEVEL_UNSPECIFIED" else { return nil }
        let names = ["LEVEL_FREE": "Adagio", "LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato",
                     "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro"]
        return names[level] ?? level
    }

    /// Extra-usage wallet. Amounts are fixed-point: ÷ 1e6 = cents.
    static func wallet(_ raw: Any?) -> Credits? {
        guard let wallet = raw as? [String: Any], let balance = wallet["balance"] as? [String: Any],
              balance["type"] as? String == "BOOSTER", let total = JSON.double(balance["amount"]), total > 0
        else { return nil }
        let cents = (JSON.double(balance["amountLeft"]) ?? 0) / 1_000_000
        let currency = ["monthlyChargeLimit", "monthlyUsed"].lazy
            .compactMap { nonEmpty((wallet[$0] as? [String: Any])?["currency"]) }.first ?? "USD"
        return Credits(amount: cents / 100, currency: currency, label: "wallet")
    }
}
