import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore
import ThisJellyFixNetworking

final class ArrClientTests: XCTestCase {
    private let radarrBase = URL(string: "http://radarr.local:7878")!
    private let sonarrBase = URL(string: "http://sonarr.local:8989")!

    // MARK: - Radarr: lookup + add

    func testRadarrLookupByTmdbId() async throws {
        let session = SpySession(json: """
        [{"id": 1, "title": "Blade Runner 2049", "year": 2017, "tmdbId": 335984,
          "hasFile": false, "monitored": true, "status": "released",
          "images": [{"coverType": "poster", "url": "/radarr/poster.jpg"}]}]
        """)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)

        let results = try await client.lookup(tmdbId: "335984")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Blade Runner 2049")
        XCTAssertEqual(results[0].tmdbId, "335984")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/movie/lookup")
        XCTAssertEqual(
            session.capturedRequest?.url?.queryParameters["term"],
            "tmdb:335984"
        )
        XCTAssertEqual(session.capturedRequest?.value(forHTTPHeaderField: "X-Api-Key"), "rk")
    }

    func testRadarrAddMovieSendsDefaultsWithoutSearch() async throws {
        let session = SpySession(json: #"{"id": 42}"#)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)

        let added = try await client.addMovie(
            tmdbId: "335984",
            title: "Blade Runner 2049",
            qualityProfileId: 1,
            rootFolderPath: "/films",
            monitored: true,
            searchForMovie: false
        )

        XCTAssertEqual(added, 42)
        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/movie")
        let body = try XCTUnwrap(session.capturedRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["tmdbId"] as? Int, 335984)
        XCTAssertEqual(json["qualityProfileId"] as? Int, 1)
        XCTAssertEqual(json["rootFolderPath"] as? String, "/films")
        XCTAssertEqual(json["monitored"] as? Bool, true)
        XCTAssertEqual(json["title"] as? String, "Blade Runner 2049")
        // Radarr only reads the search flag from addOptions — a top-level
        // copy is ignored (movie added, no search triggered).
        let addOptions = try XCTUnwrap(json["addOptions"] as? [String: Any])
        XCTAssertEqual(addOptions["searchForMovie"] as? Bool, false)
        XCTAssertNil(json["searchForMovie"])
    }

    func testRadarrAddMovieCanSearchImmediately() async throws {
        let session = SpySession(json: #"{"id": 42}"#)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)
        _ = try await client.addMovie(
            tmdbId: "1", title: "X", qualityProfileId: 1,
            rootFolderPath: "/f", monitored: true, searchForMovie: true
        )
        let body = try XCTUnwrap(session.capturedRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let addOptions = try XCTUnwrap(json["addOptions"] as? [String: Any])
        XCTAssertEqual(addOptions["searchForMovie"] as? Bool, true)
    }

    /// The add-time search runs with a non-Manual trigger, so Radarr skips
    /// unavailable movies entirely ("Performing search for 0 movies").
    /// Posting the command through the API marks it Manual → same path as
    /// clicking search in Radarr's UI, which bypasses the availability filter.
    func testRadarrTriggerSearchPostsMoviesSearchCommand() async throws {
        let session = SpySession(json: #"{"id": 7}"#)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)

        try await client.triggerSearch(movieId: 42)

        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/command")
        let body = try XCTUnwrap(session.capturedRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["name"] as? String, "MoviesSearch")
        XCTAssertEqual(json["movieIds"] as? [Int], [42])
    }

    // MARK: - Radarr: options (quality profiles, root folders)

    func testRadarrQualityProfiles() async throws {
        let session = SpySession(json: """
        [{"id": 1, "name": "HD"}, {"id": 4, "name": "Bluray"}]
        """)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)
        let profiles = try await client.qualityProfiles()
        XCTAssertEqual(profiles.map(\.name), ["HD", "Bluray"])
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/qualityprofile")
    }

    func testRadarrRootFolders() async throws {
        let session = SpySession(json: #"[{"id": 1, "path": "/films"}]"#)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)
        let folders = try await client.rootFolders()
        XCTAssertEqual(folders.map(\.path), ["/films"])
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/rootfolder")
    }

    // MARK: - Sonarr: lookup + add

    func testSonarrLookupByTmdbId() async throws {
        let session = SpySession(json: """
        [{"id": 7, "title": "Breaking Bad", "year": 2008, "tvdbId": 81189, "tmdbId": 1396,
          "status": "continuing", "network": "AMC", "seasonCount": 5,
          "images": [{"coverType": "poster", "url": "/sonarr/poster.jpg"}],
          "seasons": [{"seasonNumber": 1, "monitored": true}]}]
        """)
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)

        let results = try await client.lookup(tmdbId: "1396")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Breaking Bad")
        XCTAssertEqual(results[0].tmdbId, "1396")
        XCTAssertEqual(results[0].seasons.map(\.seasonNumber), [1])
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/series/lookup")
        XCTAssertEqual(session.capturedRequest?.url?.queryParameters["term"], "tmdb:1396")
        XCTAssertEqual(session.capturedRequest?.value(forHTTPHeaderField: "X-Api-Key"), "sk")
    }

    func testSonarrAddSeriesSendsMonitoredSeasons() async throws {
        let session = SpySession(json: #"{"id": 99}"#)
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)

        let added = try await client.addSeries(
            tvdbId: 81189,
            title: "Breaking Bad",
            qualityProfileId: 2,
            rootFolderPath: "/series",
            monitored: true,
            monitor: .all,
            seasons: [1, 2],
            searchForMissing: true
        )

        XCTAssertEqual(added, 99)
        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/series")
        let body = try XCTUnwrap(session.capturedRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["tvdbId"] as? Int, 81189)
        XCTAssertEqual(json["qualityProfileId"] as? Int, 2)
        XCTAssertEqual(json["rootFolderPath"] as? String, "/series")
        XCTAssertEqual(json["monitored"] as? Bool, true)
        XCTAssertEqual(json["seasonFolder"] as? Bool, true)
        // seasons must be SeasonResource objects: bare ints make Sonarr's
        // JSON parser fail → 400 on every series add.
        let seasons = try XCTUnwrap(json["seasons"] as? [[String: Any]])
        XCTAssertEqual(seasons.compactMap { $0["seasonNumber"] as? Int }, [1, 2])
        XCTAssertEqual(seasons.allSatisfy { $0["monitored"] as? Bool == true }, true)
        // monitor + search live inside addOptions; top-level copies are
        // ignored by Sonarr → no search would ever fire.
        let addOptions = try XCTUnwrap(json["addOptions"] as? [String: Any])
        XCTAssertEqual(addOptions["monitor"] as? String, "all")
        XCTAssertEqual(addOptions["searchForMissingEpisodes"] as? Bool, true)
        XCTAssertNil(json["monitor"])
        XCTAssertNil(json["searchForMissingEpisodes"])
    }

    /// Same as Radarr: the post-add search ignores delay profiles and aired
    /// checks unless the command carries a Manual trigger, which the API
    /// assigns to every POST /command request.
    func testSonarrTriggerSearchPostsSeriesSearchCommand() async throws {
        let session = SpySession(json: #"{"id": 7}"#)
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)

        try await client.triggerSearch(seriesId: 99)

        XCTAssertEqual(session.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/command")
        let body = try XCTUnwrap(session.capturedRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["name"] as? String, "SeriesSearch")
        XCTAssertEqual(json["seriesId"] as? Int, 99)
    }

    func testSonarrQualityProfiles() async throws {
        let session = SpySession(json: #"[{"id": 3, "name": "Any"}]"#)
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)
        let profiles = try await client.qualityProfiles()
        XCTAssertEqual(profiles.map(\.name), ["Any"])
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/qualityprofile")
    }

    // MARK: - Base URL with subpath (reverse proxy)

    func testBaseURLWithSubpathIsPreserved() async throws {
        let session = SpySession(json: #"[{"id": 1, "name": "HD"}]"#)
        let client = RadarrClient(
            baseURL: URL(string: "http://host.local/radarr")!,
            apiKey: "rk",
            session: session
        )
        _ = try await client.qualityProfiles()
        XCTAssertEqual(session.capturedRequest?.url?.path, "/radarr/api/v3/qualityprofile")
    }

    // MARK: - Errors

    func testUnauthorizedThrows() async {
        let session = SpySession(json: "{}", statusCode: 401)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "bad", session: session)
        do {
            _ = try await client.qualityProfiles()
            XCTFail("Expected error")
        } catch let error as ArrError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testConnectionRefusedThrowsUnreachable() async {
        let session = SpySession(json: "", statusCode: 0, error: URLError(.cannotConnectToHost))
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)
        do {
            _ = try await client.qualityProfiles()
            XCTFail("Expected error")
        } catch let error as ArrError {
            XCTAssertEqual(error, .unreachable)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    /// A 400 is useless without the service's explanation: surface the
    /// response body so the user sees WHY the add was rejected.
    func testServerErrorSurfacesServerMessage() async {
        let session = SpySession(
            json: #"[{"propertyName":"seasons","errorMessage":"Invalid seasons value"}]"#,
            statusCode: 400
        )
        let client = SonarrClient(baseURL: sonarrBase, apiKey: "sk", session: session)
        do {
            _ = try await client.qualityProfiles()
            XCTFail("Expected error")
        } catch let error as ArrError {
            XCTAssertEqual(error, .serverError(400, "Invalid seasons value"))
            XCTAssertTrue(error.localizedDescription.contains("código 400"))
            XCTAssertTrue(error.localizedDescription.contains("Invalid seasons value"))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testServerErrorWithoutBodyKeepsCodeOnly() async {
        let session = SpySession(json: "", statusCode: 500)
        let client = RadarrClient(baseURL: radarrBase, apiKey: "rk", session: session)
        do {
            _ = try await client.qualityProfiles()
            XCTFail("Expected error")
        } catch let error as ArrError {
            XCTAssertEqual(error, .serverError(500, nil))
            XCTAssertEqual(error.localizedDescription, "El servicio devolvió un error (código 500).")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}
