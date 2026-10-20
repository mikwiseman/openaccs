import Foundation

/// accounts.json: the ordered list of accounts. Small, so every save rewrites the whole file atomically.
public struct AccountStore: Sendable {
    public var file: URL

    public init(file: URL) { self.file = file }

    /// [] only when the file doesn't exist; a file that can't be read or decoded throws, so callers never
    /// mistake it for "no accounts" and save over it.
    public func load() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSON.decoder.decode([Account].self, from: Data(contentsOf: file))
    }

    public func save(_ accounts: [Account]) throws {
        try AtomicFile.write(JSON.encoder.encode(accounts), to: file, permissions: 0o600)
    }
}

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFractional.string(from: date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = isoFractional.date(from: s) ?? iso.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()

    /// Parses ISO-8601 with or without fractional seconds, or epoch seconds/milliseconds.
    public static func date(_ value: Any?) -> Date? {
        switch value {
        case let s as String:
            if let d = isoFractional.date(from: s) ?? iso.date(from: s) { return d }
            return Double(s).map(epoch)
        case let n as NSNumber:
            return epoch(n.doubleValue)
        default:
            return nil
        }
    }

    /// Epoch seconds, or milliseconds when the value is too large to be seconds.
    public static func epoch(_ n: Double) -> Date {
        n > 1e11 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lenient number reading for loosely typed JSON (`"12.5"`, `12`, `12.5`).
    public static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Decodes the payload of a JWT without verifying it (identity hints only, never trust decisions).
public enum JWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return JSON.object(data)
    }

    public static func expiry(_ token: String) -> Date? {
        JSON.date(claims(token)?["exp"])
    }
}
