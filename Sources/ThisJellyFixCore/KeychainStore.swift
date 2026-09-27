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
    public static let userId      = "com.thisjellyfix.auth.userId"
    public static let userName    = "com.thisjellyfix.auth.userName"
    public static let serverURL   = "com.thisjellyfix.auth.serverURL"
    public static let deviceId    = "com.thisjellyfix.auth.deviceId"
}

// MARK: - Constants

private enum KeychainConstants {
    /// Shared across all THISJELLYFIX targets and, when iCloud Keychain is
    /// enabled, across all of the user's Apple devices.
    static let accessGroup = "group.com.thisjellyfix"
}

// MARK: - Implementation

public struct KeychainStore: KeychainStoring {
    private let service: String

    public init(service: String = "com.thisjellyfix.auth") {
        self.service = service
        // Silently migrate any legacy items (written without an access group)
        // into the shared group so iCloud Keychain can sync them.
        // This runs at most once per install: once an item lives in the group
        // it is not found by the legacy query any more.
        migrateIfNeeded()
    }

    // MARK: - KeychainStoring

    public func save(key: String, value: String) throws {
        deleteIfExists(key: key)

        guard let data = value.data(using: .utf8) else { return }

        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecAttrAccessGroup as String:    KeychainConstants.accessGroup,
            kSecAttrSynchronizable as String: true,   // iCloud Keychain sync
            kSecValueData as String:          data,
        ]

        // kSecAttrSynchronizable is not supported on tvOS simulator; guard it
        // so a Debug build on the simulator doesn't silently swallow errors.
        #if targetEnvironment(simulator)
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        #endif

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func read(key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecAttrAccessGroup as String:    KeychainConstants.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]

        #if targetEnvironment(simulator)
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        #endif

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
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecAttrAccessGroup as String:    KeychainConstants.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        #if targetEnvironment(simulator)
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        #endif

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    public func deleteAll() throws {
        // Fetch all accounts for this service, then delete each individually.
        // SecItemDelete with class+service alone is unreliable on some macOS versions.
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccessGroup as String:    KeychainConstants.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String:   true,
            kSecMatchLimit as String:         kSecMatchLimitAll,
        ]

        #if targetEnvironment(simulator)
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        #endif

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

    // MARK: - Migration

    /// Reads any item written by the old code (no access group, not
    /// synchronizable) and re-saves it under the shared group so iCloud
    /// Keychain can start syncing it. The old item is removed afterward.
    private func migrateIfNeeded() {
        let keys = [
            KeychainKey.accessToken,
            KeychainKey.userId,
            KeychainKey.userName,
            KeychainKey.serverURL,
            KeychainKey.deviceId,
        ]

        for key in keys {
            // 1. Check whether a shared-group item already exists — nothing to do.
            if read(key: key) != nil { continue }

            // 2. Try to find a legacy item (no access group, not synchronizable).
            let legacyQuery: [String: Any] = [
                kSecClass as String:              kSecClassGenericPassword,
                kSecAttrService as String:        service,
                kSecAttrAccount as String:        key,
                kSecReturnData as String:         true,
                kSecMatchLimit as String:         kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { continue }

            // 3. Write into the shared group (with iCloud sync).
            try? save(key: key, value: value)

            // 4. Remove the legacy item so reads from `read()` always hit the group.
            let deleteQuery: [String: Any] = [
                kSecClass as String:      kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
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
