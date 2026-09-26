import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore

final class CatalogRecommenderTests: XCTestCase {
    private func item(_ tmdbId: String, title: String, kind: CatalogItem.Kind = .movie) -> CatalogItem {
        CatalogItem(id: tmdbId, kind: kind, title: title, year: 2020, overview: nil,
                    posterURL: nil, backdropURL: nil, tmdbId: tmdbId, imdbId: nil)
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

    func testBuildRowsCombinesAndFiltersLibraryTitlesFromForYou() {
        let library = [libraryItem("10")]
        let trending = [item("1", title: "T1"), item("2", title: "T2")]
        let forYou = [item("10", title: "Owned"), item("3", title: "F3")]

        let rows = CatalogRecommender.buildRows(
            trending: trending,
            recommendations: forYou,
            library: library
        )

        // "Owned" is already in the library → not offered as a download.
        XCTAssertEqual(rows.map { $0.items.map(\.title) }, [["T1", "T2"], ["F3"]])
        XCTAssertEqual(rows.map(\.title), ["Tendencias", "Para ti"])
    }

    func testBuildRowsSkipsEmptyRows() {
        let rows = CatalogRecommender.buildRows(
            trending: [],
            recommendations: [item("3", title: "F3")],
            library: []
        )
        XCTAssertEqual(rows.map(\.title), ["Para ti"])
    }

    func testNothingConfiguredYieldsNoRows() {
        let rows = CatalogRecommender.buildRows(
            trending: nil,
            recommendations: nil,
            library: []
        )
        XCTAssertTrue(rows.isEmpty)
    }
}
