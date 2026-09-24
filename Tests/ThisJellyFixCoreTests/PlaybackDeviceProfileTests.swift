import XCTest
@testable import ThisJellyFixCore

final class PlaybackDeviceProfileTests: XCTestCase {
    func testPipHLSProfileEncodesHlsOnlyTranscoding() throws {
        let data = try JSONEncoder().encode(PlaybackDeviceProfile.pipHLS)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["Name"] as? String, "thisjellyfix-pip-hls")

        // No direct play → server is forced to transcode and answer with
        // a TranscodingUrl (master.m3u8) that AVPlayer can consume.
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [Any])
        XCTAssertTrue(direct.isEmpty)

        let transcoding = try XCTUnwrap(json["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcoding.count, 1)
        XCTAssertEqual(transcoding[0]["Protocol"] as? String, "hls")
        XCTAssertEqual(transcoding[0]["Container"] as? String, "ts")
        XCTAssertEqual(transcoding[0]["VideoCodec"] as? String, "h264")
        XCTAssertEqual(transcoding[0]["AudioCodec"] as? String, "aac")
        XCTAssertEqual(transcoding[0]["Context"] as? String, "Streaming")
    }

    func testPipHLSProfileHasSubtitleDeliveryProfiles() throws {
        let data = try JSONEncoder().encode(PlaybackDeviceProfile.pipHLS)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let subs = try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])

        XCTAssertTrue(subs.contains { $0["Format"] as? String == "srt" && $0["DeliveryMethod"] as? String == "External" })
    }
}
