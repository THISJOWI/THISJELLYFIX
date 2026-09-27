import XCTest
@testable import ThisJellyFixCore

final class JellyfinItemDetailUserDataTests: XCTestCase {
    func testDecodesFavoriteAndPlayedState() throws {
        let json = """
        {
          "Id": "i1", "Name": "Josee", "Type": "Movie", "Year": 2020,
          "RunTimeTicks": 588000000000,
          "UserData": {"IsFavorite": true, "Played": false, "PlaybackPositionTicks": 1200000000}
        }
        """
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.isFavorite, true)
        XCTAssertEqual(detail.isPlayed, false)
        XCTAssertEqual(detail.resumePositionSeconds, 120)
    }

    func testMissingUserDataDefaultsToFalse() throws {
        let json = #"{"Id": "i1", "Name": "Josee", "Type": "Movie"}"#
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertNil(detail.userData)
        XCTAssertEqual(detail.isFavorite, false)
        XCTAssertEqual(detail.isPlayed, false)
    }
}
