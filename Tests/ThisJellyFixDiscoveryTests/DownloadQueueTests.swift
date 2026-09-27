import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore

final class DownloadQueueTests: XCTestCase {
    // MARK: - Radarr queue parsing

    func testRadarrQueueMapsProgressAndStatus() async throws {
        let session = SpySession(json: """
        {"records": [
          {"id": 11, "status": "downloading", "progress": 42.5,
           "movie": {"id": 5, "title": "Dune", "tmdbId": 438631}},
          {"id": 12, "status": "completed", "progress": 100,
           "movie": {"id": 6, "title": "Tenet", "tmdbId": 615457}},
          {"id": 13, "status": "failed", "progress": 3,
           "movie": {"id": 7, "title": "Bad", "tmdbId": 1}}
        ]}
        """)
        let client = RadarrClient(baseURL: URL(string: "http://r:7878")!, apiKey: "k", session: session)
        let queue = try await DownloadQueue(client: .radarr(client)).fetch()

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue[0].service, .radarr)
        XCTAssertEqual(queue[0].title, "Dune")
        XCTAssertEqual(queue[0].state, .downloading(progress: 42.5))
        // remoteId = the movie id Radarr knows (DELETE /movie/{id}), which is
        // NOT the queue record id — deleting by record id 404s silently.
        XCTAssertEqual(queue[0].remoteId, "5")
        XCTAssertEqual(queue[1].state, .completed)
        XCTAssertEqual(queue[1].remoteId, "6")
        XCTAssertEqual(queue[2].state, .failed("failed"))
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/queue")
    }

    func testQueuePrefersEmbeddedMovieIdOverTopLevel() async throws {
        let session = SpySession(json: """
        {"records": [
          {"id": 14, "status": "queued", "progress": 0, "movieId": 9,
           "movie": {"id": 5, "title": "Dune", "tmdbId": 438631}},
          {"id": 15, "status": "queued", "progress": 0}
        ]}
        """)
        let client = RadarrClient(baseURL: URL(string: "http://r:7878")!, apiKey: "k", session: session)
        let queue = try await DownloadQueue(client: .radarr(client)).fetch()

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].remoteId, "5")
        // Record with no movie object has no title → skipped, no crash.
    }

    func testSonarrQueueUsesSeriesTitle() async throws {
        let session = SpySession(json: """
        {"records": [
          {"id": 1, "status": "downloading", "progress": 10,
           "series": {"id": 3, "title": "Breaking Bad", "tvdbId": 81189}},
          {"id": 2, "status": "paused", "progress": 50,
           "series": {"id": 3, "title": "Breaking Bad", "tvdbId": 81189}}
        ]}
        """)
        let client = SonarrClient(baseURL: URL(string: "http://s:8989")!, apiKey: "k", session: session)
        let queue = try await DownloadQueue(client: .sonarr(client)).fetch()

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue[0].service, .sonarr)
        XCTAssertEqual(queue[0].title, "Breaking Bad")
        XCTAssertEqual(queue[0].state, .downloading(progress: 10))
        // Series id (3), not the queue record id (1): cancel must DELETE
        // /series/3 server-side.
        XCTAssertEqual(queue[0].remoteId, "3")
        XCTAssertEqual(queue[1].state, .paused(progress: 50))
        XCTAssertEqual(session.capturedRequest?.url?.path, "/api/v3/queue")
    }

    func testEmptyQueue() async throws {
        let session = SpySession(json: #"{"records": []}"#)
        let client = RadarrClient(baseURL: URL(string: "http://r:7878")!, apiKey: "k", session: session)
        let queue = try await DownloadQueue(client: .radarr(client)).fetch()
        XCTAssertTrue(queue.isEmpty)
    }

    func testUnreachableServicePropagatesError() async {
        let session = SpySession(json: "", statusCode: 0, error: URLError(.cannotConnectToHost))
        let client = SonarrClient(baseURL: URL(string: "http://s:8989")!, apiKey: "k", session: session)
        do {
            _ = try await DownloadQueue(client: .sonarr(client)).fetch()
            XCTFail("Expected error")
        } catch let error as ArrError {
            XCTAssertEqual(error, .unreachable)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    // MARK: - State mapping

    func testStatusMappingCoversCommonCases() {
        XCTAssertEqual(DownloadState(status: "pending", progress: nil), .queued)
        XCTAssertEqual(DownloadState(status: "waiting", progress: nil), .queued)
        XCTAssertEqual(DownloadState(status: "paused", progress: 50), .paused(progress: 50))
        XCTAssertEqual(DownloadState(status: "downloading", progress: 10), .downloading(progress: 10))
        XCTAssertEqual(DownloadState(status: "completed", progress: 100), .completed)
        XCTAssertEqual(DownloadState(status: "failed", progress: nil), .failed("failed"))
        XCTAssertEqual(DownloadState(status: "error", progress: nil), .failed("error"))
        // Unknown status keeps the raw string in failed so the UI shows something.
        XCTAssertEqual(DownloadState(status: "weird", progress: nil), .failed("weird"))
    }
}
