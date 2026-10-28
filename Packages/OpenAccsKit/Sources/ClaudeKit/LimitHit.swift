import Foundation
import OpenAccsCore

/// A Claude limit a chat just ran into: Claude Code's own rejection (HTTP 429) in the chat's transcript,
/// with the exact time that limit comes back. The only place a reset time shows up without a sign-in.
public struct LimitHit: Sendable, Hashable {
    public var kind: UsageWindow.Kind
    public var resetsAt: Date
    /// When the chat was refused.
    public var at: Date
    public var sessionId: String
    public var cwd: String?

    /// The refusals written after `since` in the last 256 KB of a transcript.
    public static func read(_ file: URL, since: Date) -> [LimitHit] {
        guard let tail = ClaudeProfiles.tail(of: file, bytes: 256 << 10) else { return [] }
        let marker = Data(#""rate_limit""#.utf8)
        var hits: [LimitHit] = []
        for line in tail.split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let entry = JSON.object(Data(line)), entry["error"] as? String == "rate_limit",
                  let at = JSON.date(entry["timestamp"]), at > since,
                  let info = ((entry["apiErrorParams"] as? [String: Any])?["rate_limit_info"] ?? entry["quotaLimits"]) as? [String: Any],
                  let reset = JSON.double(info["resetsAt"]), let kind = kind(info["rateLimitType"] as? String),
                  let session = entry["sessionId"] as? String else { continue }
            hits.append(LimitHit(kind: kind, resetsAt: Date(timeIntervalSince1970: reset), at: at, sessionId: session, cwd: entry["cwd"] as? String))
        }
        return hits
    }

    static func kind(_ type: String?) -> UsageWindow.Kind? {
        switch type {
        case "five_hour": .fiveHour
        case "seven_day": .weekly
        default: nil
        }
    }
}

extension UsageSnapshot {
    /// These numbers with the limits the account ran into: such a window is empty until the hit's exact reset
    /// and free after it. Numbers taken after the reset know better, and so do exact numbers (with their own
    /// reset time) taken after the hit; numbers without a reset time taken in between get the hit's. Without
    /// numbers, a limit that already came back says nothing.
    public static func with(_ hits: [LimitHit], on snapshot: UsageSnapshot?, now: Date) -> UsageSnapshot? {
        var result = snapshot
        for hit in hits where snapshot.map({ $0.asOf < hit.resetsAt }) ?? (hit.resetsAt > now) {
            var usage = result ?? UsageSnapshot(windows: [], asOf: hit.at, source: "Claude Code")
            let current = usage.window(hit.kind)
            let newer = snapshot.map { $0.asOf >= hit.at } ?? false
            if newer, current?.resetsAt != nil { continue }
            usage.windows.removeAll { $0.kind == hit.kind && $0.label == nil }
            usage.windows.append(UsageWindow(kind: hit.kind, usedPercent: newer ? current?.usedPercent ?? 100 : 100, resetsAt: hit.resetsAt))
            usage.windows.sort { order($0.kind) < order($1.kind) }
            result = usage
        }
        return result?.at(now)
    }

    private static func order(_ kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .fiveHour: 0
        case .weekly: 1
        case .monthly: 2
        case .other: 3
        }
    }
}
