import XCTest
import Security
@testable import ThisJellyFixCore

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        // Use unique service per test to avoid collisions
        store = KeychainStore(service: "com.thisjellyfix.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.deleteAll()
        super.tearDown()
    }

    func testSaveAndRead() throws {
        try store.save(key: "token", value: "abc123")
        XCTAssertEqual(store.read(key: "token"), "abc123")
    }

    func testReadReturnsNilForMissingKey() {
        XCTAssertNil(store.read(key: "nonexistent"))
    }

    func testOverwriteExistingValue() throws {
        try store.save(key: "token", value: "first")
        try store.save(key: "token", value: "second")
        XCTAssertEqual(store.read(key: "token"), "second")
    }

    func testDeleteRemovesValue() throws {
        try store.save(key: "token", value: "abc123")
        try store.delete(key: "token")
        XCTAssertNil(store.read(key: "token"))
    }

    func testDeleteNonexistentKeyDoesNotThrow() throws {
        try store.delete(key: "nonexistent")
    }

    func testDeleteAllRemovesAllValues() throws {
        try store.save(key: "a", value: "1")
        try store.save(key: "b", value: "2")
        try store.deleteAll()
        XCTAssertNil(store.read(key: "a"))
        XCTAssertNil(store.read(key: "b"))
    }

    // MARK: - Access group

    /// An App Group id (`group.…`) is NOT a keychain access group. Passing
    /// one made every SecItem call fail with -34018 on signed builds, and
    /// the swallowed error meant the API keys were never stored at all.
    func testQueryUsesDefaultAccessGroupNotAppGroup() {
        let query = KeychainStore.baseQuery(service: "svc", key: "acc")

        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query[kSecAttrService as String] as? String, "svc")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "acc")
    }

    /// Keychain groups must be `<TeamID>.<name>`; the entitlements can't
    /// declare an App Group id or every query above would be rejected.
    func testEntitlementsDeclareRealKeychainGroups() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for target in ["iOS", "macOS"] {
            let url = root.appendingPathComponent("Apps/\(target)/ThisJellyfix.entitlements")
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            let groups = try XCTUnwrap(plist["keychain-access-groups"] as? [String])
            for group in groups {
                XCTAssertFalse(
                    group.hasPrefix("group."),
                    "\(target) declares an App Group id as a keychain group: \(group)"
                )
                XCTAssertTrue(
                    group.hasPrefix("$(") || group.contains("."),
                    "\(target) keychain group is not team-prefixed: \(group)"
                )
            }
        }
    }
}
