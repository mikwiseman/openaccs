import CommonCrypto
import CryptoKit
import Foundation
import OpenAccsCore
import Security
import SQLite3

/// Read-only use of the selected Claude desktop session. No browser search, token refresh, or cookie cache.
public actor ClaudeDesktopUsage {
    private let http: HTTPClient
    private var password: Data?
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Only an explicit Refresh may show the system access prompt, once per action.
    public func allowAccess() throws {
        if password == nil { password = try Self.safeStorage(allowPrompt: true) }
    }

    public func usage(profile: ClaudeProfile, account: ClaudeAccountKey) async throws -> UsageSnapshot {
        let cookie = try Self.cookie(in: profile.dataDir)
        if password == nil { password = try Self.safeStorage(allowPrompt: false) }
        let session = try Self.decrypt(cookie.encrypted, password: password!, host: cookie.host, version: cookie.version)
        return try await fetch(session: session, account: account)
    }

    func fetch(session: String, account: ClaudeAccountKey) async throws -> UsageSnapshot {
        guard session.hasPrefix("sk-ant-"), !session.contains(where: { $0.isWhitespace || $0 == ";" }) else { throw UsageError.needsSignIn }
        let owner = try await get("/api/account", session: session)
        guard (owner["uuid"] as? String)?.lowercased() == account.account else { throw UsageError.needsSignIn }
        let limits = try await get("/api/organizations/\(account.org)/usage", session: session)
        var result = try ClaudeCodeCLI.parseUsage(["response": ["response": ["rate_limits_available": true, "rate_limits": limits]]], now: Date())
        guard !result.windows.isEmpty else { throw UsageError.noPlan }
        result.source = "Claude"
        return result
    }

    private func get(_ path: String, session: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://claude.ai" + path)!)
        request.setValue("sessionKey=\(session)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        if response.statusCode == 401 { throw UsageError.needsSignIn }
        guard response.statusCode == 200, let object = JSON.object(data) else {
            throw UsageError.unexpected("Claude could not refresh limits (HTTP \(response.statusCode))")
        }
        return object
    }

    /// SQLite's own read transaction sees a consistent snapshot, including WAL, without copying the database.
    private static func cookie(in directory: URL) throws -> (host: String, encrypted: Data, version: Int) {
        let files = [directory.appending(path: "Cookies"), directory.appending(path: "Network/Cookies")]
        guard let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw UsageError.needsSignIn }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw UsageError.unexpected("Claude's sign-in is busy. Try refreshing again.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &statement, nil) == SQLITE_OK else { throw UsageError.needsSignIn }
        let version = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        sqlite3_finalize(statement)
        guard version > 0 else { throw UsageError.needsSignIn }
        let sql = "SELECT host_key, encrypted_value FROM cookies WHERE name='sessionKey' AND host_key IN ('claude.ai','.claude.ai') AND path='/' ORDER BY last_access_utc DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageError.needsSignIn }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let host = sqlite3_column_text(statement, 0),
              let bytes = sqlite3_column_blob(statement, 1), sqlite3_column_bytes(statement, 1) > 3 else { throw UsageError.needsSignIn }
        return (String(cString: host), Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))), version)
    }

    private static func safeStorage(allowPrompt: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Claude uses the legacy login Keychain ACL. LAContext.interactionNotAllowed does not
        // suppress its password dialog, so use the Keychain's process-level interaction gate.
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        if !allowPrompt { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowPrompt { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            throw UsageError.unexpected("Refresh to allow access to Claude's saved sign-in")
        }
        return data
    }

    /// Chromium macOS v10: PBKDF2-SHA1, AES-128-CBC. Version 24 also binds the plaintext to its cookie host.
    static func decrypt(_ encrypted: Data, password: Data, host: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw UsageError.unexpected("Unsupported Claude sign-in format") }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.bindMemory(to: Int8.self).baseAddress, password.count,
                               salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw UsageError.needsSignIn }
        let bytes = Data(encrypted.dropFirst(3)), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: bytes.count + kCCBlockSizeAES128), written = 0
        let capacity = output.count
        let status = bytes.withUnsafeBytes { raw in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, raw.baseAddress, bytes.count, &output, capacity, &written)
        }
        guard status == kCCSuccess else { throw UsageError.needsSignIn }
        var data = Data(output.prefix(written))
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard data.starts(with: digest) else { throw UsageError.needsSignIn }
            data = Data(data.dropFirst(digest.count))
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw UsageError.needsSignIn }
        return value
    }
}
