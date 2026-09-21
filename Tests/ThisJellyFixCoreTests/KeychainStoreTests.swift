import XCTest
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
}
