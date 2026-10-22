import Foundation
import OpenAccsCore

/// Usage the Claude desktop app records in `<dataDir>/plan-usage-history.json` while it runs.
/// Credential-free; percentages only, no reset times.
public enum ClaudeAppUsage {
    /// `UsageSnapshot.source` of these numbers.
    public static let source = "Claude app"
    /// The app writes its numbers only now and then (at launch and quit): older ones aren't today's limits.
    public static let freshFor: TimeInterval = 15 * 60

    public static func read(profile: ClaudeProfile) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: profile.dataDir.appending(path: "plan-usage-history.json")) else { return nil }
        return parse(data, org: profile.orgUuid)
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
