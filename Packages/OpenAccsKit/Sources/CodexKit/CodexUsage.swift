import Foundation
import OpenAccsCore

/// `GET https://chatgpt.com/backend-api/wham/usage`, the numbers the Codex app shows.
enum CodexUsage {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func request(accessToken: String, accountId: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs/0.163.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Windows are classified by `limit_window_seconds`, never by primary/secondary position.
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = JSON.object(data) else { throw UsageError.unexpected("Unreadable ChatGPT usage") }
        let rateLimit = root["rate_limit"] as? [String: Any]
        var windows = self.windows(of: rateLimit, label: nil, now: now)
        // Credit-metered workspaces have no rate limit, only a monthly spend limit.
        if rateLimit == nil,
           let limit = (root["spend_control"] as? [String: Any])?["individual_limit"] as? [String: Any],
           let used = JSON.double(limit["used_percent"]) {
            windows.append(UsageWindow(kind: .monthly, usedPercent: used, resetsAt: resetDate(limit, now: now)))
        }
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let label = text(extra["limit_name"]) ?? text(extra["metered_feature"]) ?? "Other"
            windows += self.windows(of: extra["rate_limit"] as? [String: Any], label: label, now: now)
        }

        var credits: Credits?
        if let c = root["credits"] as? [String: Any], c["has_credits"] as? Bool == true,
           let balance = JSON.double(c["balance"]), balance > 0 {
            credits = Credits(amount: balance, currency: "credits", label: "balance")
        }
        let resets = JSON.double((root["rate_limit_reset_credits"] as? [String: Any])?["available_count"]).map { Int($0) }
        return UsageSnapshot(
            plan: text(root["plan_type"]), windows: windows, credits: credits,
            resetsAvailable: resets, asOf: now, source: "ChatGPT"
        )
    }

    private static func windows(of rateLimit: [String: Any]?, label: String?, now: Date) -> [UsageWindow] {
        ["primary_window", "secondary_window"].compactMap { key in
            guard let w = rateLimit?[key] as? [String: Any], let used = JSON.double(w["used_percent"]) else { return nil }
            let seconds = JSON.double(w["limit_window_seconds"]).map { Int($0) }
            return UsageWindow(kind: kind(seconds: seconds), label: label, usedPercent: used, resetsAt: resetDate(w, now: now))
        }
    }

    private static func kind(seconds: Int?) -> UsageWindow.Kind {
        switch seconds {
        case 18_000?: .fiveHour
        case 604_800?: .weekly
        case let s? where (28 * 86_400...31 * 86_400).contains(s): .monthly
        default: .other
        }
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        JSON.date(window["reset_at"]) ?? JSON.double(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
    }
}
