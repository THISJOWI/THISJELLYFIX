import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore
import ThisJellyFixNetworking

final class TMDBMetadataProviderTests: XCTestCase {
    private func makeProvider(_ json: String, statusCode: Int = 200) -> (TMDBMetadataProvider, SpySession) {
        let session = SpySession(data: Data(json.utf8), statusCode: statusCode)
        let provider = TMDBMetadataProvider(apiKey: "tmdb-key", session: session)
        return (provider, session)
    }

    // MARK: - Trending

    func testTrendingMapsMovieAndSeries() async throws {
        let (provider, _) = makeProvider("""
        {
          "results": [
            {"id": 335984, "media_type": "movie", "title": "Blade Runner 2049",
             "release_date": "2017-10-04", "overview": "o", "poster_path": "/p.jpg",
             "backdrop_path": "/b.jpg", "vote_average": 7.6},
            {"id": 1396, "media_type": "tv", "name": "Breaking Bad",
             "first_air_date": "2008-01-20", "overview": "o", "poster_path": "/s.jpg"}
          ]
        }
        """)

        let items = try await provider.trending()

        XCTAssertEqual(items.count, 2)
        let movie = items[0]
        XCTAssertEqual(movie.kind, .movie)
        XCTAssertEqual(movie.title, "Blade Runner 2049")
        XCTAssertEqual(movie.year, 2017)
        XCTAssertEqual(movie.tmdbId, "335984")
        XCTAssertEqual(movie.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w500/p.jpg")
        XCTAssertEqual(movie.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w780/b.jpg")

        let series = items[1]
        XCTAssertEqual(series.kind, .series)
        XCTAssertEqual(series.title, "Breaking Bad")
        XCTAssertEqual(series.year, 2008)
        XCTAssertEqual(series.tmdbId, "1396")
    }

    func testTrendingSendsApiKeyAsQueryItem() async throws {
        let (provider, session) = makeProvider(#"{"results": []}"#)
        _ = try await provider.trending()
        let url = try XCTUnwrap(session.capturedRequest?.url)
        XCTAssertEqual(url.queryParameters["api_key"], "tmdb-key")
        XCTAssertEqual(url.path, "/3/trending/all/day")
    }

    func testTrendingSkipsPersonEntries() async throws {
        let (provider, _) = makeProvider("""
        {"results": [
          {"id": 1, "media_type": "person", "name": "Actor"},
          {"id": 2, "media_type": "movie", "title": "Film", "release_date": "2020-01-01"}
        ]}
        """)
        let items = try await provider.trending()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Film")
    }

    // MARK: - Recommendations

    func testRecommendationsForMovieHitMovieEndpoint() async throws {
        let (provider, session) = makeProvider(#"{"results": []}"#)
        _ = try await provider.recommendations(tmdbId: "335984", kind: .movie)
        let url = try XCTUnwrap(session.capturedRequest?.url)
        XCTAssertEqual(url.path, "/3/movie/335984/recommendations")
    }

    func testRecommendationsForSeriesHitTvEndpoint() async throws {
        let (provider, session) = makeProvider(#"{"results": []}"#)
        _ = try await provider.recommendations(tmdbId: "1396", kind: .series)
        let url = try XCTUnwrap(session.capturedRequest?.url)
        XCTAssertEqual(url.path, "/3/tv/1396/recommendations")
    }

    func testRecommendationsMapItemsWithoutMediaType() async throws {
        // /recommendations responses carry no media_type: kind comes from the endpoint.
        let (provider, _) = makeProvider("""
        {"results": [{"id": 9, "name": "Better Call Saul", "first_air_date": "2015-02-08"}]}
        """)
        let items = try await provider.recommendations(tmdbId: "1396", kind: .series)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .series)
        XCTAssertEqual(items[0].title, "Better Call Saul")
        XCTAssertEqual(items[0].year, 2015)
    }

    // MARK: - Search

    func testSearchQueriesMultiEndpoint() async throws {
        let (provider, session) = makeProvider(#"{"results": []}"#)
        _ = try await provider.search(query: "blade runner")
        let url = try XCTUnwrap(session.capturedRequest?.url)
        XCTAssertEqual(url.path, "/3/search/multi")
        XCTAssertEqual(url.queryParameters["query"], "blade runner")
    }

    func testSearchMapsResults() async throws {
        let (provider, _) = makeProvider("""
        {"results": [
          {"id": 78, "media_type": "movie", "title": "Blade Runner", "release_date": "1982-06-25"},
          {"id": 335984, "media_type": "movie", "title": "Blade Runner 2049", "release_date": "2017-10-04"}
        ]}
        """)
        let items = try await provider.search(query: "blade runner")
        XCTAssertEqual(items.map(\.title), ["Blade Runner", "Blade Runner 2049"])
        XCTAssertEqual(items.map(\.year), [1982, 2017])
    }

    // MARK: - Errors

    func testUnauthorizedStatusThrowsUnauthorized() async {
        let (provider, _) = makeProvider(#"{"status_message": "Invalid key"}"#, statusCode: 401)
        do {
            _ = try await provider.trending()
            XCTFail("Expected error")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testServerErrorThrowsServerError() async {
        let (provider, _) = makeProvider("{}", statusCode: 500)
        do {
            _ = try await provider.trending()
            XCTFail("Expected error")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .serverError(500))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}

