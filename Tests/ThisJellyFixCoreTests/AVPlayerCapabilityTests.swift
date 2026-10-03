import XCTest
@testable import ThisJellyFixCore

final class AVPlayerCapabilityTests: XCTestCase {
    private func source(
        container: String?,
        direct: String?,
        transcoding: String?,
        streams: [MediaStream]
    ) -> MediaSource {
        try! JSONDecoder().decode(MediaSource.self, from: JSONSerialization.data(withJSONObject: [
            "Id": "abc",
            "Name": "file",
            "Container": container as Any,
            "DirectStreamUrl": direct as Any,
            "TranscodingUrl": transcoding as Any,
            "MediaStreams": streams.map { stream -> [String: Any] in
                var dict: [String: Any] = ["Type": stream.type]
                dict["Codec"] = stream.codec as Any
                return dict
            },
        ]))
    }

    private func videoStream(codec: String?) -> MediaStream {
        try! JSONDecoder().decode(MediaStream.self, from: JSONSerialization.data(withJSONObject: [
            "Type": "Video", "Codec": codec as Any,
        ]))
    }

    private func audioStream(codec: String?) -> MediaStream {
        try! JSONDecoder().decode(MediaStream.self, from: JSONSerialization.data(withJSONObject: [
            "Type": "Audio", "Codec": codec as Any,
        ]))
    }

    func testDirectPlayMp4H264() throws {
        let src = source(
            container: "mp4",
            direct: "/Videos/abc/stream?static=true",
            transcoding: nil,
            streams: [videoStream(codec: "h264"), audioStream(codec: "aac")]
        )
        XCTAssertTrue(AVPlayerCapability.canDirectPlay(src))
        let pick = try XCTUnwrap(AVPlayerCapability.chooseURL(src, serverURL: URL(string: "https://srv")!))
        XCTAssertEqual(pick.method, .directPlay)
        XCTAssertEqual(pick.url.absoluteString, "https://srv/Videos/abc/stream?static=true")
    }

    func testMkvNeedsRemuxNotDirectPlay() throws {
        let src = source(
            container: "mkv",
            direct: "/Videos/abc/stream?static=false",
            transcoding: nil,
            streams: [videoStream(codec: "h264"), audioStream(codec: "aac")]
        )
        XCTAssertFalse(AVPlayerCapability.canDirectPlay(src))
        XCTAssertTrue(AVPlayerCapability.canDirectStream(src))
        let pick = try XCTUnwrap(AVPlayerCapability.chooseURL(src, serverURL: URL(string: "https://srv")!))
        XCTAssertEqual(pick.method, .directStream)
    }

    func testUnknownAudioCodecFallsToHls() throws {
        let src = source(
            container: "mp4",
            direct: "/Videos/abc/stream?static=true",
            transcoding: "/Videos/abc/master.m3u8",
            streams: [videoStream(codec: "h264"), audioStream(codec: "dts")]
        )
        XCTAssertFalse(AVPlayerCapability.canDirectPlay(src))
        XCTAssertFalse(AVPlayerCapability.canDirectStream(src))
        let pick = try XCTUnwrap(AVPlayerCapability.chooseURL(src, serverURL: URL(string: "https://srv")!))
        XCTAssertEqual(pick.method, .transcode)
    }

    func testAbsoluteURLResolvedAsIs() throws {
        let src = source(
            container: "mp4",
            direct: "http://cdn.example/Videos/abc/stream",
            transcoding: nil,
            streams: [videoStream(codec: "h264")]
        )
        let pick = try XCTUnwrap(AVPlayerCapability.chooseURL(src, serverURL: URL(string: "https://srv")!))
        XCTAssertEqual(pick.url.absoluteString, "http://cdn.example/Videos/abc/stream")
    }

    func testAvPlayerProfileForcesHlsWhenDirectRejected() throws {
        // Server answered only with transcoding (profile sent) → choose it.
        let src = source(
            container: "mkv",
            direct: nil,
            transcoding: "/Videos/abc/master.m3u8",
            streams: [videoStream(codec: "hevc"), audioStream(codec: "truehd")]
        )
        let pick = try XCTUnwrap(AVPlayerCapability.chooseURL(src, serverURL: URL(string: "https://srv")!))
        XCTAssertEqual(pick.method, .transcode)
    }
}
