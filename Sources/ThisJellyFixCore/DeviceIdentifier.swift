import Foundation

// MARK: - Debug Logging

/// Debug logger: writes to NSTemporaryDirectory()/tjf_playback.log AND stdout
/// (visible in Xcode console, including on physical devices).
public func TJFLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[TJF \(timestamp)] \(message)"
    print(line)
    let logPath = NSTemporaryDirectory() + "tjf_playback.log"
    if let fd = fopen(logPath, "a") {
        fputs(line + "\n", fd)
        fclose(fd)
    }
}

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
