import Foundation
import OpenAccsCore

/// Claude's account-owned sidebar preferences. A local dframe-store edit can be replaced on sign-in;
/// update the current server copy with its checksum instead. Never seeds an absent store or copies one
/// account's pins, sections or layout to another.
public struct ClaudeSidebarSettings: Sendable {
    public enum Result: Sendable, Equatable {
        case unchanged
        /// Confirmed by a fresh read; an already open Claude window may still need to reload it.
        case updated
        /// Claude has not saved this account's sidebar yet. Retry after its first Code-tab initialization.
        case awaitingSidebar
    }

    private let http: HTTPClient
    private static let key = "ccd/dframe-store"

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Uses the existing desktop session in memory only. Each conflict starts from a fresh server copy,
    /// preserving edits made meanwhile. No unconditional write and no change to model or permissions.
    public func apply(session: String, account: ClaudeAccountKey, now: Date = Date()) async throws -> Result {
        guard session.hasPrefix("sk-ant-"), !session.contains(where: { $0.isWhitespace || $0 == ";" }) else {
            throw UsageError.needsSignIn
        }
        let url = URL(string: "https://claude.ai/api/claude_code/organizations/\(account.org)/user_settings")!
        func request(_ method: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("sessionKey=\(session)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        for _ in 0..<3 {
            let current = try await read(request("GET"), account: account)
            guard let envelope = current.envelope else { return .awaitingSidebar }
            guard let patched = try Self.chronological(envelope, now: now) else { return .unchanged }
            var write = request("PUT")
            write.setValue(current.checksum, forHTTPHeaderField: "If-Match")
            write.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let text = String(decoding: try JSONSerialization.data(withJSONObject: patched), as: UTF8.self)
            write.httpBody = try JSONSerialization.data(withJSONObject: ["entries": [Self.key: text]])
            let (_, response) = try await http.send(write)
            if response.statusCode == 409 || response.statusCode == 412 { continue }
            try Self.check(response.statusCode)
            let confirmed = try await read(request("GET"), account: account)
            guard let after = confirmed.envelope, try Self.chronological(after, now: now) == nil else {
                throw UsageError.unexpected("Claude's sidebar update was not confirmed")
            }
            return .updated
        }
        throw UsageError.unexpected("Claude's sidebar changed during the update. Try again.")
    }

    private func read(_ request: URLRequest, account: ClaudeAccountKey) async throws -> (checksum: String, envelope: [String: Any]?) {
        let (data, response) = try await http.send(request)
        try Self.check(response.statusCode)
        guard let object = JSON.object(data), let owner = object["userId"] as? String,
              Self.accountID(owner) == Self.accountID(account.account) else {
            throw UsageError.unexpected("Claude is signed in to another account")
        }
        guard let checksum = object["checksum"] as? String, !checksum.isEmpty,
              !checksum.contains(where: { $0.isNewline }) else {
            throw UsageError.unexpected("Claude's sidebar response has no checksum")
        }
        guard let content = object["content"] as? [String: Any], let entries = content["entries"] as? [String: Any] else {
            throw Self.unsupported
        }
        guard let stored = entries[Self.key] else { return (checksum, nil) }
        guard let text = stored as? String, let envelope = JSON.object(Data(text.utf8)) else { throw Self.unsupported }
        return (checksum, envelope)
    }

    /// nil means it already has the requested grouping and order. Every other field is retained as read.
    static func chronological(_ envelope: [String: Any], now: Date) throws -> [String: Any]? {
        guard var state = envelope["state"] as? [String: Any],
              var sections = state["sidebarSections"] as? [[String: Any]],
              let index = sections.firstIndex(where: { $0["id"] as? String == "sessions" && $0["kind"] as? String == "sessions" }),
              sections.filter({ $0["id"] as? String == "sessions" }).count == 1 else { throw unsupported }
        guard sections[index]["groupBy"] as? String != "date" || sections[index]["sortBy"] as? String != "recency"
                || sections[index]["ascending"] as? Bool != false else { return nil }
        sections[index]["groupBy"] = "date"
        sections[index]["sortBy"] = "recency"
        sections[index]["ascending"] = false
        state["sidebarSections"] = sections
        var patched = envelope
        patched["state"] = state
        patched["updatedAt"] = now.timeIntervalSince1970 * 1000
        return patched
    }

    /// The native API returns userId without UUID separators; profile identities include them.
    private static func accountID(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static var unsupported: UsageError { .unexpected("Claude's sidebar format is not supported") }

    private static func check(_ status: Int) throws {
        if status == 401 { throw UsageError.needsSignIn }
        if status == 403 { throw UsageError.unexpected("Claude's sidebar membership is unavailable") }
        guard (200..<300).contains(status) else { throw UsageError.unexpected("Claude could not update the sidebar (HTTP \(status))") }
    }
}
