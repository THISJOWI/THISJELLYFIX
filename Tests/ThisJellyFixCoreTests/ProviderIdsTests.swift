import XCTest
@testable import ThisJellyFixCore

final class ProviderIdsTests: XCTestCase {
    private func decode(_ json: String) throws -> JellyfinMediaItem {
        try JSONDecoder().decode(JellyfinMediaItem.self, from: Data(json.utf8))
    }

    func testDecodesProviderIds() throws {
        let item = try decode("""
        {
            "Id": "abc123",
            "Name": "Blade Runner 2049",
            "Type": "Movie",
            "ProviderIds": { "Tmdb": "335984", "Imdb": "tt1856101" }
        }
        """)
        XCTAssertEqual(item.providerId(for: "Tmdb"), "335984")
        XCTAssertEqual(item.providerId(for: "Imdb"), "tt1856101")
        XCTAssertEqual(item.tmdbId, "335984")
        XCTAssertEqual(item.imdbId, "tt1856101")
    }

    func testMissingProviderIdsIsEmpty() throws {
        let item = try decode("""
        { "Id": "abc123", "Name": "Sin IDs", "Type": "Series" }
        """)
        XCTAssertNil(item.tmdbId)
        XCTAssertNil(item.imdbId)
        XCTAssertTrue((item.providerIds ?? [:]).isEmpty)
    }

    func testUnknownProviderKeyReturnsNil() throws {
        let item = try decode("""
        { "Id": "x", "Name": "y", "Type": "Movie", "ProviderIds": { "Tvdb": "99" } }
        """)
        XCTAssertNil(item.providerId(for: "Tmdb"))
        XCTAssertNil(item.tmdbId)
        XCTAssertEqual(item.providerId(for: "Tvdb"), "99")
    }

    func testProviderIdsAreCaseInsensitive() throws {
        let item = try decode("""
        { "Id": "x", "Name": "y", "Type": "Movie", "ProviderIds": { "tmdb": "77" } }
        """)
        XCTAssertEqual(item.tmdbId, "77")
    }

    func testItemStaysCodableRoundTrip() throws {
        let item = try decode("""
        { "Id": "x", "Name": "y", "Type": "Movie", "ProviderIds": { "Tmdb": "77" } }
        """)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(JellyfinMediaItem.self, from: data)
        XCTAssertEqual(back.providerIds, ["Tmdb": "77"])
    }
}
