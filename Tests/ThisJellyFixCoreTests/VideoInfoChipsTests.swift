import XCTest
@testable import ThisJellyFixCore

final class VideoInfoChipsTests: XCTestCase {
    private func source(_ json: String) throws -> MediaSource {
        try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
    }

    func testAllChipsPresentForFullVideoStream() throws {
        let source = try source("""
        {
          "Id": "s1",
          "Name": "main",
          "Container": "mkv",
          "Size": 26600000000,
          "MediaStreams": [
            {"Type": "Video", "Codec": "h264", "Width": 1920, "Height": 1080,
             "BitRate": 30060000, "RealFrameRate": 24, "VideoRange": "SDR"},
            {"Type": "Audio", "Codec": "aac", "Language": "spa"}
          ]
        }
        """)

        let chips = VideoInfoChips.chips(from: source)

        XCTAssertEqual(chips.map(\.kind), [.size, .resolution, .range, .codec, .bitrate, .fps])
        XCTAssertEqual(chips[0].text, "26.6 GB")
        XCTAssertEqual(chips[1].text, "1920x1080")
        XCTAssertEqual(chips[2].text, "SDR")
        XCTAssertEqual(chips[3].text, "h264")
        XCTAssertEqual(chips[4].text, "30.06 Mbps")
        XCTAssertEqual(chips[5].text, "24 fps")
    }

    func testMissingValuesProduceNoChips() throws {
        let source = try source("""
        {"Id": "s1", "Name": "main", "MediaStreams": [{"Type": "Audio", "Codec": "aac"}]}
        """)

        XCTAssertTrue(VideoInfoChips.chips(from: source).isEmpty)
    }

    func testPartialValuesKeepOnlyAvailableChips() throws {
        let source = try source("""
        {
          "Id": "s1", "Name": "main",
          "MediaStreams": [{"Type": "Video", "Codec": "hevc", "Height": 720}]
        }
        """)

        let chips = VideoInfoChips.chips(from: source)

        XCTAssertEqual(chips.map(\.kind), [.codec])
        XCTAssertEqual(chips[0].text, "hevc")
    }

    func testBitrateAliasDecodesLowercaseKey() throws {
        let source = try source("""
        {
          "Id": "s1", "Name": "main",
          "MediaStreams": [{"Type": "Video", "Codec": "h264", "Bitrate": 500000}]
        }
        """)

        XCTAssertEqual(source.mediaStreams.first?.bitRate, 500_000)
        XCTAssertEqual(VideoInfoChips.chips(from: source).first { $0.kind == .bitrate }?.text, "500 Kbps")
    }

    func testFractionalFrameRateKeepsDecimals() throws {
        let source = try source("""
        {
          "Id": "s1", "Name": "main",
          "MediaStreams": [{"Type": "Video", "Codec": "h264", "RealFrameRate": 23.976}]
        }
        """)

        XCTAssertEqual(VideoInfoChips.chips(from: source).first { $0.kind == .fps }?.text, "23.98 fps")
    }

    func testSizeFormattingBoundaries() {
        XCTAssertEqual(VideoInfoChips.formatSize(999_000_000), "999 MB")
        XCTAssertEqual(VideoInfoChips.formatSize(1_500_000_000), "1.5 GB")
        XCTAssertNil(VideoInfoChips.formatSize(0))
        XCTAssertNil(VideoInfoChips.formatSize(nil))
    }
}
