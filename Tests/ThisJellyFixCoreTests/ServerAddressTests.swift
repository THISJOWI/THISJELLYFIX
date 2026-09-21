import XCTest
@testable import ThisJellyFixCore

final class ServerAddressTests: XCTestCase {
    func testAddsHTTPSWhenSchemeIsOmitted() throws {
        XCTAssertEqual(
            try ServerAddress.normalizedURL(from: "jellyfin.example.com"),
            URL(string: "https://jellyfin.example.com")!
        )
    }

    func testPreservesLocalHTTPURL() throws {
        XCTAssertEqual(
            try ServerAddress.normalizedURL(from: "http://192.168.1.10:8096"),
            URL(string: "http://192.168.1.10:8096")!
        )
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try ServerAddress.normalizedURL(from: "ftp://example.com"))
    }
}
