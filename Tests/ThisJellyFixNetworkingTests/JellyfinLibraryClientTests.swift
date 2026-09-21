import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class JellyfinLibraryClientTests: XCTestCase {
    func testFetchViews() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[{"Id":"v1","Name":"Movies","CollectionType":"movies"},{"Id":"v2","Name":"TV Shows","CollectionType":"tvshows"}]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        let views = try await client.fetchViews(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "tok"
        )

        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(views[0].name, "Movies")
    }

    func testFetchItems() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[{"Id":"m1","Name":"Inception","Type":"Movie","Year":2010}]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        let items = try await client.fetchItems(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "tok",
            parentId: "v1",
            includeTypes: "Movie",
            limit: 20,
            orderBy: "DateCreated",
            filters: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Inception")
    }

    func testAuthHeaderContainsToken() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        _ = try await client.fetchViews(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "mytoken"
        )

        let request = session.capturedRequest
        let auth = request?.value(forHTTPHeaderField: "X-Emby-Authorization") ?? ""
        XCTAssertTrue(auth.contains("mytoken"))
        XCTAssertTrue(auth.contains("Token="))
    }
}

// MARK: - Mock

private final class MockNetworkSession: JellyfinNetworkSession, @unchecked Sendable {
    let mockData: Data
    let mockStatusCode: Int
    let mockError: Error?
    private(set) var capturedRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.mockData = data
        self.mockStatusCode = statusCode
        self.mockError = nil
    }

    init(error: Error) {
        self.mockData = Data()
        self.mockStatusCode = 0
        self.mockError = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        if let error = mockError { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: mockStatusCode, httpVersion: nil, headerFields: nil)!
        return (mockData, response)
    }
}
