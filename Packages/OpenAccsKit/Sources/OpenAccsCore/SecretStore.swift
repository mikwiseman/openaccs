import Foundation
import Security

/// Where OpenAccs keeps secrets it owns (API keys, Codex auth.json snapshots).
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
}

/// macOS Keychain, generic passwords under one service. Items are created by OpenAccs, so reading
/// them never shows a prompt for OpenAccs itself.
public struct KeychainSecretStore: SecretStore {
    public var service: String

    public init(service: String = "is.wai.openaccs") { self.service = service }

    public func read(_ key: String) throws -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    public func write(_ data: Data, for key: String) throws {
        let update = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(base(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public var status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// For tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ key: String) throws -> Data? { lock.withLock { items[key] } }
    public func write(_ data: Data, for key: String) throws { lock.withLock { items[key] = data } }
    public func delete(_ key: String) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
}
