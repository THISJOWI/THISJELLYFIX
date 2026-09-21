import Foundation
import Security

// MARK: - Protocol

public protocol KeychainStoring: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) -> String?
    func delete(key: String) throws
    func deleteAll() throws
}

// MARK: - Keys

public enum KeychainKey {
    public static let accessToken = "com.thisjellyfix.auth.accessToken"
    public static let userId = "com.thisjellyfix.auth.userId"
    public static let userName = "com.thisjellyfix.auth.userName"
    public static let serverURL = "com.thisjellyfix.auth.serverURL"
    public static let deviceId = "com.thisjellyfix.auth.deviceId"
}

// MARK: - Implementation

public struct KeychainStore: KeychainStoring {
    private let service: String

    public init(service: String = "com.thisjellyfix.auth") {
        self.service = service
    }

    public func save(key: String, value: String) throws {
        deleteIfExists(key: key)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    public func deleteAll() throws {
        // Fetch all accounts for this service, then delete each individually.
        // SecItemDelete with class+service alone is unreliable on some macOS versions.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]]
        else {
            return
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            try delete(key: account)
        }
    }

    // MARK: - Private

    private func deleteIfExists(key: String) {
        try? delete(key: key)
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError, Equatable {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Error guardando en Keychain (código \(status))"
        case .deleteFailed(let status):
            "Error eliminando de Keychain (código \(status))"
        }
    }
}
