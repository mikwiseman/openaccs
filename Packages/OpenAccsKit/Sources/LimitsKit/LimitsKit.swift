import Foundation
import OpenAccsCore

/// Where a Z.ai or Kimi account lives. The regions are separate account systems on separate hosts.
public enum Region: String, Codable, Sendable { case global, china }

extension HTTPClient {
    /// GET with an Authorization header; returns the body and HTTP status.
    func get(_ url: URL, authorization: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        return (data, response.statusCode)
    }
}

/// A non-empty, trimmed string, or nil.
func nonEmpty(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}
