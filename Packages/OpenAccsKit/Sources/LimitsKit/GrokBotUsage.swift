import Foundation
import OpenAccsCore

/// Grok Bot's local weekly-usage cache (read-only, zero network). The app keeps one blob per key in
/// `sand-client-persistence`, named by the base32 (RFC 4648, lowercase, no padding) of the key;
/// usage lives under `sand.client.slice.account.<account>.weekly-usage.cache`.
public struct GrokBotUsage: Sendable {
    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// Accounts with a usage cache, e.g. `google-oauth2|user_…` (percent-decoded).
    public func accounts() -> [String] {
        caches().map(\.account)
    }

    /// nil when the cache is missing or not in the expected shape.
    public func read(account: String) -> UsageSnapshot? {
        guard let file = caches().first(where: { $0.account == account })?.file,
              let data = try? Data(contentsOf: file) else { return nil }
        return Self.parse(data)
    }

    /// `{schemaVersion, value:{kind:"present", reading:{usage:{percentUsed, nextResetMs, grokPlanLabel}, readAtMs}}}`.
    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let value = JSON.object(data)?["value"] as? [String: Any], value["kind"] as? String == "present",
              let reading = value["reading"] as? [String: Any], let usage = reading["usage"] as? [String: Any],
              let percent = JSON.double(usage["percentUsed"]), let readAt = JSON.date(reading["readAtMs"])
        else { return nil }
        let window = UsageWindow(kind: .weekly, usedPercent: percent, resetsAt: JSON.date(usage["nextResetMs"]))
        return UsageSnapshot(plan: nonEmpty(usage["grokPlanLabel"]), windows: [window], asOf: readAt, source: "Grok Bot")
    }

    private func caches() -> [(account: String, file: URL)] {
        let dir = paths.grokBotPersistenceDir
        let prefix = "sand.client.slice.account.", suffix = ".weekly-usage.cache"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (String, URL)? in
            guard let bytes = Base32.decode(name.prefix { $0 != "." }), let key = String(data: bytes, encoding: .utf8),
                  key.count > prefix.count + suffix.count, key.hasPrefix(prefix), key.hasSuffix(suffix)
            else { return nil }
            let raw = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            return (raw.removingPercentEncoding ?? raw, dir.appending(path: name))
        }
        .sorted { $0.0 < $1.0 }
    }
}

/// RFC 4648 base32, case-insensitive, padding optional.
enum Base32 {
    static func decode(_ text: Substring) -> Data? {
        var bytes: [UInt8] = []
        var buffer = 0, bits = 0
        for c in text.unicodeScalars where c != "=" {
            let value: Int
            switch c {
            case "a"..."z": value = Int(c.value) - 97
            case "A"..."Z": value = Int(c.value) - 65
            case "2"..."7": value = Int(c.value) - 50 + 26
            default: return nil
            }
            buffer = (buffer << 5 | value) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> bits))
            }
        }
        return Data(bytes)
    }
}
