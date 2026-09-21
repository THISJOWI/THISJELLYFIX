import XCTest
@testable import ThisJellyFixCore

final class DeviceIdentifierTests: XCTestCase {
    func testReturnsSameIdAcrossCalls() {
        let keychain = MockKeychainStore()
        let id1 = DeviceIdentifier(keychain: keychain).current()
        let id2 = DeviceIdentifier(keychain: keychain).current()
        XCTAssertEqual(id1, id2)
    }

    func testIdIsValidUUID() {
        let keychain = MockKeychainStore()
        let id = DeviceIdentifier(keychain: keychain).current()
        XCTAssertNotNil(UUID(uuidString: id))
    }
}

// MARK: - Mock

private final class MockKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        storage[key] = value
    }

    func read(key: String) -> String? {
        storage[key]
    }

    func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}
