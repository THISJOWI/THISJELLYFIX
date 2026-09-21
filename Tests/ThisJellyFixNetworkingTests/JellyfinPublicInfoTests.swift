import XCTest
@testable import ThisJellyFixNetworking

final class JellyfinPublicInfoTests: XCTestCase {
    func testDecodesJellyfinPublicInfo() throws {
        let data = """
        {"ServerName":"My Jellyfin","Version":"10.10.0","Id":"server-id"}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(JellyfinPublicInfo.self, from: data)

        XCTAssertEqual(info.serverName, "My Jellyfin")
        XCTAssertEqual(info.version, "10.10.0")
        XCTAssertEqual(info.id, "server-id")
    }
}
