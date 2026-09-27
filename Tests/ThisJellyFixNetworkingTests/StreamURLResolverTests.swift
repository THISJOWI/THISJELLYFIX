import XCTest
@testable import ThisJellyFixNetworking

final class StreamURLResolverTests: XCTestCase {
    private let server = URL(string: "http://localhost:8096")!

    // MARK: - Relative resolution

    func testResolvesRelativePathAgainstServer() throws {
        let url = try XCTUnwrap(
            StreamURLResolver.resolve("/Videos/i1/stream?static=true", serverURL: server, token: "tok")
        )
        XCTAssertEqual(url.absoluteString, "http://localhost:8096/Videos/i1/stream?static=true&ApiKey=tok")
    }

    func testKeepsAbsoluteUrlAndAddsApiKey() throws {
        let url = try XCTUnwrap(
            StreamURLResolver.resolve("http://localhost:8096/Videos/i1/stream", serverURL: server, token: "tok")
        )
        XCTAssertEqual(url.host, "localhost")
        XCTAssertTrue(url.absoluteString.contains("ApiKey=tok"))
    }

    func testServerTrailingSlashIsNotDoubled() throws {
        let base = URL(string: "http://localhost:8096/")!
        let url = try XCTUnwrap(StreamURLResolver.resolve("/Videos/x", serverURL: base, token: "t"))
        XCTAssertFalse(url.absoluteString.contains("//Videos"))
        XCTAssertTrue(url.absoluteString.hasPrefix("http://localhost:8096/Videos/x"))
    }

    func testDoesNotPercentEncodeQuerySeparator() throws {
        let url = try XCTUnwrap(
            StreamURLResolver.resolve("/Videos/i1/m.m3u8?DeviceId=d1&MediaSourceId=i1", serverURL: server, token: "tok")
        )
        XCTAssertFalse(url.absoluteString.contains("%3F"))
        XCTAssertTrue(url.absoluteString.contains("DeviceId=d1"))
    }

    func testReturnsNilForUnparseableString() {
        XCTAssertNil(StreamURLResolver.resolve("ht tp://bad url", serverURL: server, token: "tok"))
    }

    // MARK: - ApiKey

    func testDoesNotDuplicateExistingApiKeyVariants() throws {
        for name in ["ApiKey", "api_key", "apiKey", "APIKEY"] {
            let url = try XCTUnwrap(
                StreamURLResolver.resolve("http://localhost:8096/s?\(name)=abc", serverURL: server, token: "tok")
            )
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let keys = items.filter { StreamURLResolver.isApiKey($0.name) }
            XCTAssertEqual(keys.count, 1, "item \(name) must keep a single ApiKey")
            XCTAssertEqual(keys.first?.value, "abc", "item \(name): existing key wins")
        }
    }

    // MARK: - playbackURL (DetailView / DirectPlayer branches)

    func testPlaybackURLPrefersDirectStreamUrlAndAuthenticates() throws {
        let url = try XCTUnwrap(
            StreamURLResolver.playbackURL(
                directStreamUrl: "/Videos/i1/stream?static=true",
                transcodingUrl: "/Videos/i1/master.m3u8",
                serverURL: server,
                itemId: "i1",
                token: "tok"
            )
        )
        XCTAssertEqual(url.absoluteString, "http://localhost:8096/Videos/i1/stream?static=true&ApiKey=tok")
    }

    func testPlaybackURLFallsBackToTranscodingUrlWhenRelative() throws {
        // Regression: the transcoding branch used to hand the RELATIVE string
        // straight to VLC (no scheme) and never attached the ApiKey.
        let url = try XCTUnwrap(
            StreamURLResolver.playbackURL(
                directStreamUrl: nil,
                transcodingUrl: "/Videos/i1/master.m3u8?DeviceId=d1",
                serverURL: server,
                itemId: "i1",
                token: "tok"
            )
        )
        XCTAssertEqual(url.absoluteString, "http://localhost:8096/Videos/i1/master.m3u8?DeviceId=d1&ApiKey=tok")
    }

    func testPlaybackURLFallsBackToStaticStreamWhenNothingProvided() throws {
        let url = try XCTUnwrap(
            StreamURLResolver.playbackURL(
                directStreamUrl: nil,
                transcodingUrl: nil,
                serverURL: server,
                itemId: "i1",
                token: "tok"
            )
        )
        XCTAssertEqual(url.absoluteString, "http://localhost:8096/Videos/i1/stream?static=true&ApiKey=tok")
    }
}
