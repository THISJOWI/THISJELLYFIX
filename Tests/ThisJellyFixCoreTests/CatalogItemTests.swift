import XCTest
@testable import ThisJellyFixCore

final class CatalogItemTests: XCTestCase {
    private func makeItem(
        kind: CatalogItem.Kind = .movie,
        tmdbId: String? = "335984",
        imdbId: String? = nil,
        jellyfinId: String? = nil
    ) -> CatalogItem {
        CatalogItem(
            id: tmdbId ?? "local-1",
            kind: kind,
            title: "Blade Runner 2049",
            year: 2017,
            overview: "Un nuevo secreto.",
            posterURL: URL(string: "https://image.tmdb.org/t/p/w500/a.jpg"),
            backdropURL: nil,
            tmdbId: tmdbId,
            imdbId: imdbId,
            jellyfinId: jellyfinId
        )
    }

    func testIsInLibraryFollowsJellyfinId() {
        XCTAssertFalse(makeItem().isInLibrary)
        XCTAssertTrue(makeItem(jellyfinId: "abc").isInLibrary)
    }

    func testMovieRoutesToRadarrAndSeriesToSonarr() {
        XCTAssertEqual(makeItem(kind: .movie).downloadService, .radarr)
        XCTAssertEqual(makeItem(kind: .series).downloadService, .sonarr)
    }

    func testMatchesLibraryItemByTmdbId() {
        let external = makeItem(tmdbId: "335984")
        let inLibrary = makeItem(jellyfinId: "j1")
        XCTAssertTrue(external.matches(tmdbId: "335984"))
        XCTAssertFalse(external.matches(tmdbId: "1"))
        XCTAssertFalse(external.matches(tmdbId: nil))
        _ = inLibrary
    }

    func testMatchIsCaseInsensitiveOnProviderValue() {
        let item = makeItem(tmdbId: "335984")
        XCTAssertTrue(item.matches(tmdbId: "335984".uppercased()))
    }

    func testIdentifiableAndEquatableByContent() {
        let a = makeItem()
        let same = makeItem()
        XCTAssertEqual(a, same)
        XCTAssertEqual(a.id, same.id)
        let other = CatalogItem(
            id: "1", kind: .movie, title: "Otro", year: 2000, overview: nil,
            posterURL: nil, backdropURL: nil, tmdbId: "1", imdbId: nil
        )
        XCTAssertNotEqual(a, other)
    }
}
