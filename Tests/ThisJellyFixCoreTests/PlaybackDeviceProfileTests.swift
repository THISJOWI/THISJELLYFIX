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

    func testAvPlayerProfileDirectPlaysOnlyAVPlayerSafeContainers() throws {
        let data = try JSONEncoder().encode(PlaybackDeviceProfile.avPlayer)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["Name"] as? String, "thisjellyfix-avplayer")

        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let containers = direct.map { $0["Container"] as? String ?? "" }.joined(separator: ",")
        XCTAssertTrue(containers.contains("mp4"))
        XCTAssertFalse(containers.contains("mkv"), "AVPlayer can't open mkv progressively")

        let transcoding = try XCTUnwrap(json["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcoding.first?["Protocol"] as? String, "hls")
        XCTAssertEqual(transcoding.first?["VideoCodec"] as? String, "h264")
    }

    func testAvPlayerProfileHybridSubtitleDelivery() throws {
        let data = try JSONEncoder().encode(PlaybackDeviceProfile.avPlayer)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let subs = try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])

        func delivery(_ format: String) -> String? {
            subs.first { $0["Format"] as? String == format }?["DeliveryMethod"] as? String
        }
        XCTAssertEqual(delivery("srt"), "External")
        XCTAssertEqual(delivery("ass"), "Encode", "ASS can't be rendered by AVPlayer → burn-in")
        XCTAssertEqual(delivery("mov_text"), "Embed")
        XCTAssertEqual(delivery("pgssub"), "Encode", "bitmap subs get burned in by the server")
    }

    func testPipHLSProfileHasSubtitleDeliveryProfiles() throws {
        let data = try JSONEncoder().encode(PlaybackDeviceProfile.pipHLS)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let subs = try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])

        XCTAssertTrue(subs.contains { $0["Format"] as? String == "srt" && $0["DeliveryMethod"] as? String == "External" })
    }
}
