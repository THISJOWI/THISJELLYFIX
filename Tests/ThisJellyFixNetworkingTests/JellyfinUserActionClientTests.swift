import XCTest
@testable import ThisJellyFixNetworking

final class JellyfinUserActionClientTests: XCTestCase {
    private let server = URL(string: "http://localhost:8096")!

    // MARK: - Routes
    //
    // Jellyfin exposes these as `/UserFavoriteItems/{itemId}?userId=…` and
    // `/UserPlayedItems/{itemId}?userId=…`. The Emby-style
    // `Users/{userId}/FavoriteItems/{itemId}` path is not routed anymore.

    func testEnableFavoriteUsesPostOnFavoriteItemsRoute() async throws {
        let session = MockNetworkSession(data: Data(), statusCode: 200)
        let client = JellyfinUserActionClient(session: session)

        try await client.setFavorite(true, userId: "u1", serverURL: server, token: "tok", itemId: "i9")

        let request = try XCTUnwrap(session.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/UserFavoriteItems/i9")
        XCTAssertEqual(request.url?.query, "userId=u1")
    }

    func testDisableFavoriteUsesDelete() async throws {
        let session = MockNetworkSession(data: Data(), statusCode: 204)
        let client = JellyfinUserActionClient(session: session)

        try await client.setFavorite(false, userId: "u1", serverURL: server, token: "tok", itemId: "i9")

        let request = try XCTUnwrap(session.capturedRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/UserFavoriteItems/i9")
    }

    func testPlayedTogglesUsePlayedItemsRoute() async throws {
        let enable = MockNetworkSession(data: Data(), statusCode: 200)
        try await JellyfinUserActionClient(session: enable)
            .setPlayed(true, userId: "u1", serverURL: server, token: "tok", itemId: "i9")
        let enableRequest = try XCTUnwrap(enable.capturedRequest)
        XCTAssertEqual(enableRequest.httpMethod, "POST")
        XCTAssertEqual(enableRequest.url?.path, "/UserPlayedItems/i9")
        XCTAssertEqual(enableRequest.url?.query, "userId=u1")

        let disable = MockNetworkSession(data: Data(), statusCode: 204)
        try await JellyfinUserActionClient(session: disable)
            .setPlayed(false, userId: "u1", serverURL: server, token: "tok", itemId: "i9")
        let disableRequest = try XCTUnwrap(disable.capturedRequest)
        XCTAssertEqual(disableRequest.httpMethod, "DELETE")
        XCTAssertEqual(disableRequest.url?.path, "/UserPlayedItems/i9")
    }

    func testAuthHeaderCarriesToken() async throws {
        let session = MockNetworkSession(data: Data(), statusCode: 200)
        let client = JellyfinUserActionClient(session: session)

        try await client.setFavorite(true, userId: "u1", serverURL: server, token: "mytoken", itemId: "i9")

        let request = try XCTUnwrap(session.capturedRequest)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("mytoken"))
        XCTAssertTrue(auth.contains("Token="))
    }

    func testUnauthorizedStatusThrows() async throws {
        let session = MockNetworkSession(data: Data(), statusCode: 401)
        let client = JellyfinUserActionClient(session: session)

        do {
            try await client.setPlayed(true, userId: "u1", serverURL: server, token: "tok", itemId: "i9")
            XCTFail("Expected unauthorized error")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    /// A 404 from an unrouted path is what a wrong route looks like; it must
    /// surface as an error instead of silently reporting success.
    func testNotFoundThrowsSoTheUiCanRollBack() async throws {
        let session = MockNetworkSession(data: Data(), statusCode: 404)
        let client = JellyfinUserActionClient(session: session)

        do {
            try await client.setFavorite(true, userId: "u1", serverURL: server, token: "tok", itemId: "i9")
            XCTFail("Expected server error")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .serverError(404))
        }
    }
}

// MARK: - Mock

private final class MockNetworkSession: JellyfinNetworkSession, @unchecked Sendable {
    let mockData: Data
    let mockStatusCode: Int
    private(set) var capturedRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.mockData = data
        self.mockStatusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (mockData, response)
    }
}
