import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class JellyfinAuthClientTests: XCTestCase {
    func testSuccessfulAuthentication() async throws {
        let mockSession = MockNetworkSession(
            data: """
            {
                "User": {"Id": "u1", "Name": "Admin"},
                "AccessToken": "token-abc",
                "ServerId": "srv-1"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let client = JellyfinAuthClient(session: mockSession)
        let result = try await client.authenticate(
            username: "Admin",
            password: "pass",
            serverURL: URL(string: "http://localhost:8096")!,
            deviceId: "test-device"
        )

        XCTAssertEqual(result.accessToken, "token-abc")
        XCTAssertEqual(result.user.name, "Admin")
        XCTAssertEqual(result.user.id, "u1")
        XCTAssertEqual(result.serverId, "srv-1")
    }

    func testInvalidCredentialsThrows() async {
        let mockSession = MockNetworkSession(
            data: Data(),
            statusCode: 401
        )

        let client = JellyfinAuthClient(session: mockSession)

        do {
            _ = try await client.authenticate(
                username: "Admin",
                password: "wrong",
                serverURL: URL(string: "http://localhost:8096")!,
                deviceId: "test-device"
            )
            XCTFail("Expected invalidCredentials error")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testNetworkErrorThrows() async {
        let mockSession = MockNetworkSession(error: URLError(.notConnectedToInternet))

        let client = JellyfinAuthClient(session: mockSession)

        do {
            _ = try await client.authenticate(
                username: "Admin",
                password: "pass",
                serverURL: URL(string: "http://localhost:8096")!,
                deviceId: "test-device"
            )
            XCTFail("Expected networkError")
        } catch {
            guard case AuthError.networkError = error else {
                XCTFail("Expected networkError, got \(error)")
                return
            }
        }
    }

    func testRequestContainsCorrectHeaders() async throws {
        let mockSession = MockNetworkSession(
            data: """
            {"User":{"Id":"u1","Name":"A"},"AccessToken":"t","ServerId":"s"}
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let client = JellyfinAuthClient(session: mockSession)
        _ = try await client.authenticate(
            username: "Admin",
            password: "pass",
            serverURL: URL(string: "http://localhost:8096")!,
            deviceId: "dev-123"
        )

        let request = mockSession.capturedRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let authHeader = request?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authHeader.contains("thisjellyfix"))
        XCTAssertTrue(authHeader.contains("dev-123"))
    }
}

// MARK: - Mock Network Session

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

        if let error = mockError {
            throw error
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (mockData, response)
    }
}
