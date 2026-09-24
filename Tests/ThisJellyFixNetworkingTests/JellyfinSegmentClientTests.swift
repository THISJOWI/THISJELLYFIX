import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class JellyfinSegmentClientTests: XCTestCase {
    private let serverURL = URL(string: "http://localhost:8096")!

    func testMediaSegmentsSuccess() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (200, """
            {"Items":[
              {"Id":"s1","ItemId":"i1","Type":"Intro","StartTicks":100000000,"EndTicks":700000000},
              {"Id":"s2","ItemId":"i1","Type":"Outro","StartTicks":6000000000,"EndTicks":6600000000},
              {"Id":"s3","ItemId":"i1","Type":"Preview","StartTicks":0,"EndTicks":100000000},
              {"Id":"s4","ItemId":"i1","Type":"Recap","StartTicks":0,"EndTicks":50000000}
            ]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )

        // Preview filtered out; Intro/Outro/Recap kept
        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers[0].type, .intro)
        XCTAssertEqual(markers[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(markers[0].end ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(markers[1].type, .credits) // Outro → credits
        XCTAssertEqual(markers[2].type, .recap)
        XCTAssertNil(session.request(for: "Users/"), "chapters fallback must not be hit")
    }

    func testMediaSegmentsNotFoundFallsBackToChapters() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (404, Data()),
            "Users/u1/Items/i1": (200, """
            {"Id":"i1","Chapters":[
              {"StartPositionTicks":0,"Name":"Intro"},
              {"StartPositionTicks":900000000,"Name":"Act One"},
              {"StartPositionTicks":6000000000,"Name":"End Credits"}
            ]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].type, .intro)
        XCTAssertEqual(markers[0].end ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(markers[1].type, .credits)
        XCTAssertNil(markers[1].end)
    }

    func testBothSourcesUnavailableReturnsEmpty() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (404, Data()),
            "Users/u1/Items/i1": (200, """
            {"Id":"i1","Chapters":[{"StartPositionTicks":0,"Name":"Scene One"}]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )
        XCTAssertTrue(markers.isEmpty)
    }

    func testMediaSegmentsEmptyFallsBackToChapters() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (200, #"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.data(using: .utf8)!),
            "Users/u1/Items/i1": (200, """
            {"Id":"i1","Chapters":[{"StartPositionTicks":0,"Name":"Intro"}]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, .intro)
    }

    func testMalformedSegmentsJSONFallsBackToChapters() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (200, "not json".data(using: .utf8)!),
            "Users/u1/Items/i1": (200, """
            {"Id":"i1","Chapters":[{"StartPositionTicks":0,"Name":"Recap"}]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, .recap)
    }

    func testNumericSegmentTypeAccepted() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (200, """
            {"Items":[{"Type":5,"StartTicks":0,"EndTicks":300000000}]}
            """.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        let markers = try await client.fetchSegments(
            serverURL: serverURL, token: "tok", userId: "u1", itemId: "i1"
        )
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, .intro) // MediaSegmentType.Intro = 5
    }

    func testAuthHeaderSent() async throws {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (200, #"{"Items":[]}"#.data(using: .utf8)!),
            "Users/u1/Items/i1": (200, #"{"Id":"i1"}"#.data(using: .utf8)!),
        ])

        let client = JellyfinSegmentClient(session: session)
        _ = try await client.fetchSegments(
            serverURL: serverURL, token: "secret", userId: "u1", itemId: "i1"
        )

        let auth = session.requests.first?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("secret"))
    }

    func testUnauthorizedThrows() async {
        let session = MockSegmentSession(routes: [
            "MediaSegments/": (401, Data()),
        ])

        let client = JellyfinSegmentClient(session: session)
        do {
            _ = try await client.fetchSegments(
                serverURL: serverURL, token: "bad", userId: "u1", itemId: "i1"
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LibraryError, .unauthorized)
        }
    }
}

// MARK: - Mock

/// Routes requests by URL substring → (statusCode, body).
private final class MockSegmentSession: JellyfinNetworkSession, @unchecked Sendable {
    let routes: [String: (Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(routes: [String: (Int, Data)]) {
        self.routes = routes
    }

    func request(for substring: String) -> URLRequest? {
        requests.first { $0.url?.absoluteString.contains(substring) == true }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url?.absoluteString ?? ""
        guard let match = routes.first(where: { url.contains($0.key) }) else {
            XCTFail("unexpected request: \(url)")
            throw URLError(.badURL)
        }
        let (status, body) = match.value
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }
}
