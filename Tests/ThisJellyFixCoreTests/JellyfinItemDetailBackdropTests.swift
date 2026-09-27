import XCTest
@testable import ThisJellyFixCore

final class JellyfinItemDetailBackdropTests: XCTestCase {
    /// Jellyfin sends the backdrop of a Series as `BackdropImageTags` (array);
    /// only movies carry `ImageTags["Backdrop"]`.
    func testSeriesBackdropImageTagsCountAsBackdrop() throws {
        let json = """
        {
          "Id": "s1", "Name": "Call of the Night", "Type": "Series",
          "ImageTags": {"Primary": "abc"},
          "BackdropImageTags": ["def", "ghi"]
        }
        """
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertTrue(detail.hasBackdrop)
    }

    func testMovieBackdropImageTagCountsAsBackdrop() throws {
        let json = #"{"Id": "m1", "Name": "Josee", "Type": "Movie", "ImageTags": {"Backdrop": "x"}}"#
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertTrue(detail.hasBackdrop)
    }

    func testEmptyBackdropImageTagsIsNoBackdrop() throws {
        let json = """
        {
          "Id": "s1", "Name": "Sin fondo", "Type": "Series",
          "ImageTags": {"Primary": "abc"}, "BackdropImageTags": []
        }
        """
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertFalse(detail.hasBackdrop)
    }

    func testNoImageTagsAtAllIsNoBackdrop() throws {
        let json = #"{"Id": "m2", "Name": "Pelicula", "Type": "Movie"}"#
        let detail = try JSONDecoder().decode(JellyfinItemDetail.self, from: Data(json.utf8))

        XCTAssertFalse(detail.hasBackdrop)
    }
}
