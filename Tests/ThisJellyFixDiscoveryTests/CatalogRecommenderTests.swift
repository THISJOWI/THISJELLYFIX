import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore

final class CatalogRecommenderTests: XCTestCase {
    private func item(
        _ tmdbId: String,
        title: String,
        kind: CatalogItem.Kind = .movie,
        anime: Bool = false
    ) -> CatalogItem {
        CatalogItem(
            id: tmdbId, kind: kind, title: title, year: 2020, overview: nil,
            posterURL: nil, backdropURL: nil, tmdbId: tmdbId, imdbId: nil,
            genreIds: anime ? [16] : [18],
            originalLanguage: anime ? "ja" : "en"
        )
    }

    /// Jellyfin library items carrying TMDB ids (what ProviderIds gives us).
    private func libraryItem(_ tmdbId: String) -> JellyfinMediaItem {
        let json = """
        {"Id":"j-\(tmdbId)","Name":"In library","Type":"Movie","ProviderIds":{"Tmdb":"\(tmdbId)"}}
        """
        return try! JSONDecoder().decode(JellyfinMediaItem.self, from: Data(json.utf8))
    }

    // MARK: - Marking

    func testItemsAlreadyInLibraryAreMarked() {
        let library = [libraryItem("1"), libraryItem("2")]
        let catalog = [item("1", title: "A"), item("3", title: "C")]

        let result = CatalogRecommender.markLibrary(catalog, library: library)

        XCTAssertTrue(result[0].isInLibrary)
        XCTAssertEqual(result[0].jellyfinId, "j-1")
        XCTAssertFalse(result[1].isInLibrary)
    }

    func testMarkIsCaseInsensitive() {
        let library = [libraryItem("ABC")]
        let catalog = [item("abc", title: "A")]
        let result = CatalogRecommender.markLibrary(catalog, library: library)
        XCTAssertTrue(result[0].isInLibrary)
    }

    // MARK: - Dedupe

    func testDedupeByTmdbIdKeepsFirst() {
        let catalog = [item("1", title: "First"), item("1", title: "Dup"), item("2", title: "Other")]
        let result = CatalogRecommender.dedupe(catalog)
        XCTAssertEqual(result.map(\.title), ["First", "Other"])
    }

    func testDedupeIgnoresEntriesWithoutTmdbId() {
        let noIds = CatalogItem(id: "x", kind: .movie, title: "NoIds", year: nil,
                                overview: nil, posterURL: nil, backdropURL: nil,
                                tmdbId: nil, imdbId: nil)
        let result = CatalogRecommender.dedupe([noIds, noIds])
        // Different source ids, neither has tmdbId: both survive (can't match).
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Rows

    func testBuildRowsSplitsTrendingByKind() {
        let trendingSeries = [item("1", title: "T1", kind: .series), item("2", title: "T2", kind: .series)]
        let trendingMovies = [item("3", title: "M1"), item("4", title: "M2")]

        let rows = CatalogRecommender.buildRows(
            trendingSeries: trendingSeries,
            trendingMovies: trendingMovies,
            recommendations: nil,
            library: []
        )

        XCTAssertEqual(rows.map(\.title), ["Tendencias de series", "Tendencias de películas"])
        XCTAssertEqual(rows.map(\.id), ["trending-series", "trending-movies"])
        XCTAssertEqual(rows[0].items.map(\.title), ["T1", "T2"])
        XCTAssertEqual(rows[1].items.map(\.title), ["M1", "M2"])
    }

    func testBuildRowsFiltersLibraryTitlesFromForYou() {
        let library = [libraryItem("10")]
        let forYou = [item("10", title: "Owned"), item("3", title: "F3")]

        let rows = CatalogRecommender.buildRows(
            trendingSeries: nil,
            trendingMovies: nil,
            recommendations: forYou,
            library: library
        )

        // "Owned" is already in the library → not offered as a download.
        XCTAssertEqual(rows.map(\.title), ["Películas para ti"])
        XCTAssertEqual(rows[0].items.map(\.title), ["F3"])
    }

    func testForYouRowsGroupSeriesMoviesAndAnimeSeparately() {
        let recommendations = [
            item("1", title: "Breaking Bad", kind: .series),
            item("2", title: "Dune"),
            item("3", title: "Frieren", kind: .series, anime: true),
            item("4", title: "Your Name", anime: true),
        ]

        let rows = CatalogRecommender.buildRows(
            trendingSeries: nil,
            trendingMovies: nil,
            recommendations: recommendations,
            library: []
        )

        XCTAssertEqual(rows.map(\.title), ["Series para ti", "Películas para ti", "Anime para ti"])
        XCTAssertEqual(rows.map(\.id), ["forYou-series", "forYou-movies", "forYou-anime"])
        XCTAssertEqual(rows[0].items.map(\.title), ["Breaking Bad"])
        XCTAssertEqual(rows[1].items.map(\.title), ["Dune"])
        // Anime leaves both the plain series and the plain movie rows.
        XCTAssertEqual(rows[2].items.map(\.title), ["Frieren", "Your Name"])
    }

    func testBuildRowsSkipsEmptyRows() {
        let rows = CatalogRecommender.buildRows(
            trendingSeries: [],
            trendingMovies: [],
            recommendations: [item("3", title: "F3")],
            library: []
        )
        XCTAssertEqual(rows.map(\.title), ["Películas para ti"])
    }

    func testNothingConfiguredYieldsNoRows() {
        let rows = CatalogRecommender.buildRows(
            trendingSeries: nil,
            trendingMovies: nil,
            recommendations: nil,
            library: []
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testTrendingSeriesRowKeepsOwnedTitles() {
        // Trending is public discovery: owning the hit must not hide it.
        let library = [libraryItem("1")]
        let rows = CatalogRecommender.buildRows(
            trendingSeries: [item("1", title: "Owned hit", kind: .series)],
            trendingMovies: nil,
            recommendations: nil,
            library: library
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].items[0].isInLibrary)
    }
}
