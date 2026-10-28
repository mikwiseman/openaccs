import Foundation
import OpenAccsCore

/// Usage the Claude desktop app records in `<dataDir>/plan-usage-history.json` while it runs.
/// Credential-free; percentages only, no reset times.
public enum ClaudeAppUsage {
    /// `UsageSnapshot.source` of these numbers.
    public static let source = "Claude app"
    /// The app writes its numbers only when it refreshes its usage card (never more often than every 4.5
    /// minutes) and a closed window not at all, so they can be hours old. A window's number holds until that
    /// window could have started over (5 hours, 7 days); then it's dropped. nil when nothing is left.
    public static func current(_ usage: UsageSnapshot, now: Date) -> UsageSnapshot? {
        let age = now.timeIntervalSince(usage.asOf)
        var result = usage
        result.windows.removeAll { window in
            switch window.kind {
            case .fiveHour: age >= 5 * 3600
            case .weekly, .other: age >= 7 * 86400
            case .monthly: age >= 28 * 86400
            }
        }
        return result.windows.isEmpty ? nil : result
    }

    /// The newest numbers any of these windows saved, each read for the org it shows. Pass every window signed
    /// in to one account and org: they save that account's numbers, and one closed long ago keeps old ones.
    public static func read(profiles: [ClaudeProfile]) -> UsageSnapshot? {
        profiles.compactMap { profile in
            (try? Data(contentsOf: profile.dataDir.appending(path: "plan-usage-history.json"))).flatMap { parse($0, org: profile.orgUuid) }
        }.max { $0.asOf < $1.asOf }
    }

    /// Latest sample, preferring the profile's org: fh → 5h, sd → weekly, so/sn → weekly Opus/Sonnet.
    static func parse(_ data: Data, org: String?) -> UsageSnapshot? {
        guard let samples = (JSON.object(data)?["samples"] as? [Any])?.compactMap({ $0 as? [String: Any] }) else { return nil }
        // Samples are per org; never show another org's numbers for a profile whose org is known.
        let mine = org.map { org in samples.filter { $0["org"] as? String == org } } ?? samples
        guard let sample = mine.max(by: { (JSON.double($0["t"]) ?? 0) < (JSON.double($1["t"]) ?? 0) }),
              let t = JSON.double(sample["t"]), let u = sample["u"] as? [String: Any] else { return nil }
        let keys: [(String, UsageWindow.Kind, String?)] = [("fh", .fiveHour, nil), ("sd", .weekly, nil), ("so", .weekly, "Opus"), ("sn", .weekly, "Sonnet")]
        let windows = keys.compactMap { key, kind, label in
            JSON.double(u[key]).map { UsageWindow(kind: kind, label: label, usedPercent: $0) }
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(windows: windows, asOf: JSON.epoch(t), source: source)
    }
}
