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

    func testFirstVariantParsesMasterPlaylist() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        hls1/main/0.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        hls1/main/1.m3u8
        """
        let base = URL(string: "http://localhost:8096/Videos/i1/master.m3u8?api_key=tok")!

        let url = HlsStreamResolver.firstVariant(in: Data(master.utf8), base: base)

        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:8096/Videos/i1/hls1/main/0.m3u8"
        )
    }

    func testFirstSegmentParsesVariantPlaylist() {
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:3
        #EXTINF:3.000000,
        0.ts?device=1
        #EXTINF:3.000000,
        1.ts
        """
        let base = URL(string: "http://localhost:8096/Videos/i1/hls1/main/0.m3u8?api_key=tok")!

        let url = HlsStreamResolver.firstSegment(in: Data(variant.utf8), base: base)

        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:8096/Videos/i1/hls1/main/0.ts?device=1"
        )
    }

    func testWarmUpFetchesMasterVariantAndSegmentInOrder() async {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        variant.m3u8
        """
        let variant = """
        #EXTM3U
        #EXTINF:3.000000,
        seg0.ts
        """
        let session = RoutingStubSession(routes: [
            "master.m3u8": Data(master.utf8),
            "variant.m3u8": Data(variant.utf8),
            "seg0.ts": Data("segment-bytes".utf8),
        ])

        await HlsStreamResolver(session: session).warmUp(
            hlsURL: URL(string: "http://localhost:8096/Videos/i1/master.m3u8?ApiKey=tok")!,
            token: "tok"
        )

        XCTAssertEqual(session.requestedPaths, [
            "/Videos/i1/master.m3u8",
            "/Videos/i1/variant.m3u8",
            "/Videos/i1/seg0.ts",
        ])
    }

    func testWarmUpToleratesMissingVariant() async {
        let session = RoutingStubSession(routes: [
            "master.m3u8": Data("#EXTM3U".utf8),
        ])

        await HlsStreamResolver(session: session).warmUp(
            hlsURL: URL(string: "http://localhost:8096/Videos/i1/master.m3u8?ApiKey=tok")!,
            token: "tok"
        )

        XCTAssertEqual(session.requestedPaths, ["/Videos/i1/master.m3u8"])
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

/// Serves canned bodies keyed by URL path suffix and records every request.
private final class RoutingStubSession: JellyfinNetworkSession, @unchecked Sendable {
    private let routes: [String: Data]
    private(set) var requestedPaths: [String] = []

    init(routes: [String: Data]) {
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        requestedPaths.append(path)
        let body = routes.first(where: { path.hasSuffix($0.key) })?.value ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}
