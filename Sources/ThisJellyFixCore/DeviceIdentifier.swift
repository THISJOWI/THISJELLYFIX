import Foundation

public struct DeviceIdentifier: Sendable {
    private let keychain: any KeychainStoring
    private let storageKey = KeychainKey.deviceId

    public init(keychain: any KeychainStoring = KeychainStore()) {
        self.keychain = keychain
    }

    public func current() -> String {
        if let existing = keychain.read(key: storageKey) {
            return existing
        }
        let newId = UUID().uuidString
        try? keychain.save(key: storageKey, value: newId)
        return newId
    }
}
