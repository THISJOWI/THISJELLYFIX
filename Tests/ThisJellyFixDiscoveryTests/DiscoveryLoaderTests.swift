import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore

final class DiscoveryLoaderTests: XCTestCase {
    private func libraryItem(_ tmdbId: String, type: String) -> JellyfinMediaItem {
        let json = """
        {"Id":"j-\(tmdbId)","Name":"Lib","Type":"\(type)","ProviderIds":{"Tmdb":"\(tmdbId)"}}
        """
        return try! JSONDecoder().decode(JellyfinMediaItem.self, from: Data(json.utf8))
    }

    private func catalog(_ tmdbId: String, title: String, kind: CatalogItem.Kind = .movie) -> CatalogItem {
        CatalogItem(id: tmdbId, kind: kind, title: title, year: 2020, overview: nil,
                    posterURL: nil, backdropURL: nil, tmdbId: tmdbId, imdbId: nil)
    }

    // MARK: - Rows

    func testLoadRowsUsesTrendingPlusRecommendationsFromLibrary() async throws {
        let provider = FakeProvider()
        provider.trendingByKind[.series] = [catalog("1", title: "TS", kind: .series)]
        provider.trendingByKind[.movie] = [catalog("2", title: "TM")]
        provider.recommendationsResult = [catalog("9", title: "Rec")]
        let loader = DiscoveryLoader(provider: provider)

        let rows = try await loader.loadRows(library: [
            libraryItem("50", type: "Movie"),
            libraryItem("60", type: "Series"),
        ])

        // Separate trending shelves per kind, homogeneous "para ti" rows.
        XCTAssertEqual(rows.map(\.title), ["Tendencias de series", "Tendencias de películas", "Películas para ti"])
        XCTAssertEqual(provider.askedTrendingKinds, [.series, .movie])
        // Recommendations asked for both library TMDB ids.
        XCTAssertEqual(provider.askedRecommendations.sorted(), ["50", "60"])
        XCTAssertEqual(rows[2].items.map(\.title), ["Rec"])
    }

    func testLoadRowsWithoutProviderReturnsEmpty() async throws {
        let loader = DiscoveryLoader(provider: nil)
        let rows = try await loader.loadRows(library: [])
        XCTAssertTrue(rows.isEmpty)
    }

    func testLoadRowsSurvivesProviderFailure() async throws {
        let provider = FakeProvider()
        provider.trendingError = MetadataProviderError.serverError(500)
        provider.recommendationsError = MetadataProviderError.unauthorized
        let loader = DiscoveryLoader(provider: provider)

        // One failing call must not sink the whole Home screen.
        let rows = try await loader.loadRows(library: [libraryItem("50", type: "Movie")])
        XCTAssertTrue(rows.isEmpty)
    }

    func testRecommendationsPreferMovieSourcesForMovies() async throws {
        let provider = FakeProvider()
        provider.recommendationsResult = [catalog("9", title: "Rec")]
        let loader = DiscoveryLoader(provider: provider)

        _ = try await loader.loadRows(library: [
            libraryItem("50", type: "Movie"),
            libraryItem("60", type: "Series"),
        ])

        XCTAssertEqual(provider.askedKinds["50"], .movie)
        XCTAssertEqual(provider.askedKinds["60"], .series)
    }

    // MARK: - Search

    func testSearchMergesLibraryAndCatalogWithoutDuplicates() async throws {
        let provider = FakeProvider()
        provider.searchResult = [
            catalog("1", title: "Inception"),       // also in library
            catalog("2", title: "Inception 2"),
        ]
        let loader = DiscoveryLoader(provider: provider)

        let library = [
            // Same title as catalog "1", matched by TMDB id.
            libraryItem("1", type: "Movie"),
            libraryItem("77", type: "Movie"),
        ]
        let results = try await loader.search(query: "inception", library: library)

        XCTAssertEqual(results.map(\.title), ["Inception", "Inception 2"])
        // The library copy is marked so the UI can badge it instead of
        // offering a second download of the same title.
        XCTAssertEqual(results[0].jellyfinId, "j-1")
        XCTAssertNil(results[1].jellyfinId)
    }

    func testSearchWithoutProviderReturnsEmpty() async throws {
        let loader = DiscoveryLoader(provider: nil)
        let results = try await loader.search(query: "x", library: [])
        XCTAssertTrue(results.isEmpty)
    }
}

// MARK: - Fake provider

final class FakeProvider: MetadataProvider, @unchecked Sendable {
    var trendingResult: [CatalogItem] = []
    var trendingByKind: [CatalogItem.Kind: [CatalogItem]] = [:]
    var trendingError: Error?
    var recommendationsResult: [CatalogItem] = []
    var recommendationsError: Error?
    var searchResult: [CatalogItem] = []
    var searchError: Error?

    private(set) var askedTrendingKinds: [CatalogItem.Kind] = []
    private(set) var askedRecommendations: [String] = []
    private(set) var askedKinds: [String: CatalogItem.Kind] = [:]

    func trending(kind: CatalogItem.Kind) async throws -> [CatalogItem] {
        askedTrendingKinds.append(kind)
        if let trendingError { throw trendingError }
        return trendingByKind[kind] ?? trendingResult
    }

    func recommendations(tmdbId: String, kind: CatalogItem.Kind) async throws -> [CatalogItem] {
        askedRecommendations.append(tmdbId)
        askedKinds[tmdbId] = kind
        if let recommendationsError { throw recommendationsError }
        return recommendationsResult
    }

    func search(query: String) async throws -> [CatalogItem] {
        if let searchError { throw searchError }
        return searchResult
    }
}
