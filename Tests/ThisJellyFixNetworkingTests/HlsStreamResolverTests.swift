import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class HlsStreamResolverTests: XCTestCase {
    private let server = URL(string: "http://localhost:8096")!

    func testResolvesRelativeTranscodingUrlAndAddsApiKey() async throws {
        let session = StubSession(data: """
        {"MediaSources":[{"Id":"i1","Name":"Ep","TranscodingUrl":"/Videos/i1/master.m3u8?DeviceId=d1&MediaSourceId=i1"}],"PlaySessionId":"ps1"}
        """.data(using: .utf8)!)

        let url = try await HlsStreamResolver(session: session)
            .resolveHlsURL(userId: "u1", serverURL: server, token: "tok", itemId: "i1")

        let resolved = try XCTUnwrap(url)
        XCTAssertTrue(resolved.absoluteString.hasPrefix("http://localhost:8096/Videos/i1/master.m3u8"))
        XCTAssertTrue(resolved.absoluteString.contains("DeviceId=d1"))
        XCTAssertTrue(resolved.absoluteString.contains("ApiKey=tok"))
        // Query separator must survive resolution (no %3F mangling).
        XCTAssertFalse(resolved.absoluteString.contains("%3F"))
    }

    func testDoesNotDuplicateExistingApiKey() async throws {
        let session = StubSession(data: """
        {"MediaSources":[{"Id":"i1","Name":"Ep","TranscodingUrl":"http://localhost:8096/Videos/i1/master.m3u8?api_key=abc"}]}
        """.data(using: .utf8)!)

        let url = try await HlsStreamResolver(session: session)
            .resolveHlsURL(userId: "u1", serverURL: server, token: "tok", itemId: "i1")

        let resolved = try XCTUnwrap(url)
        let count = resolved.absoluteString.components(separatedBy: "api_key=").count - 1
        XCTAssertEqual(count, 1)
        XCTAssertTrue(resolved.absoluteString.contains("api_key=abc"))
    }

    func testReturnsNilWhenServerOffersNoHls() async throws {
        let session = StubSession(data: """
        {"MediaSources":[{"Id":"i1","Name":"Ep"}]}
        """.data(using: .utf8)!)

        let url = await HlsStreamResolver(session: session)
            .resolveHlsURL(userId: "u1", serverURL: server, token: "tok", itemId: "i1")

        XCTAssertNil(url)
    }

    func testPlaybackInfoRequestSendsHlsDeviceProfile() async throws {
        let session = StubSession(data: """
        {"MediaSources":[{"Id":"i1","Name":"Ep","TranscodingUrl":"/Videos/i1/master.m3u8"}]}
        """.data(using: .utf8)!)

        _ = await HlsStreamResolver(session: session)
            .resolveHlsURL(userId: "u1", serverURL: server, token: "tok", itemId: "i1")

        let request = try XCTUnwrap(session.capturedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try XCTUnwrap(json["DeviceProfile"] as? [String: Any])

        XCTAssertEqual(profile["Name"] as? String, "thisjellyfix-pip-hls")
        let direct = try XCTUnwrap(profile["DirectPlayProfiles"] as? [Any])
        XCTAssertTrue(direct.isEmpty)
        let transcoding = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcoding.first?["Protocol"] as? String, "hls")
    }
}

// MARK: - Mock

private final class StubSession: JellyfinNetworkSession, @unchecked Sendable {
    let mockData: Data
    private(set) var capturedRequest: URLRequest?

    init(data: Data) {
        self.mockData = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (mockData, response)
    }
}
