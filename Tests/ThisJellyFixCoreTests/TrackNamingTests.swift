import XCTest
@testable import ThisJellyFixCore

final class TrackNamingTests: XCTestCase {

    // MARK: - Screenshot regression cases

    func testRedundantNameWithLanguageShowsLanguageAndGroup() {
        let d = TrackNaming.display(
            rawName: "[ToonsHub] English - [English]",
            languageCode: "eng",
            serverTitle: nil,
            index: 0
        )
        XCTAssertEqual(d.title, "Inglés")
        XCTAssertEqual(d.caption, "ToonsHub")
    }

    func testSecondLanguageRow() {
        let d = TrackNaming.display(
            rawName: "[ToonsHub] Arabic - [Arabic]",
            languageCode: "ara",
            serverTitle: nil,
            index: 1
        )
        XCTAssertEqual(d.title, "Árabe")
        XCTAssertEqual(d.caption, "ToonsHub")
    }

    func testBareTrackWithServerLanguage() {
        let d = TrackNaming.display(
            rawName: "Track 2",
            languageCode: "spa",
            serverTitle: nil,
            index: 2
        )
        XCTAssertEqual(d.title, "Español")
        XCTAssertNil(d.caption)
    }

    func testBareTrackWithNoMetadataFallsBackToNumber() {
        let d = TrackNaming.display(
            rawName: "Track 2",
            languageCode: nil,
            serverTitle: nil,
            index: 1
        )
        XCTAssertEqual(d.title, "Subtítulo 2")
        XCTAssertNil(d.caption)
    }

    func testDescriptiveServerTitleWinsWithLanguageCaption() {
        let d = TrackNaming.display(
            rawName: "Track 1",
            languageCode: "eng",
            serverTitle: "English SDH",
            index: 0
        )
        XCTAssertEqual(d.title, "English SDH")
        XCTAssertEqual(d.caption, "Inglés")
    }

    func testServerTitleStripsCodecToken() {
        // "Spanish · SRT" reduces to the language word → language becomes the title.
        let d = TrackNaming.display(
            rawName: "Track 3",
            languageCode: "spa",
            serverTitle: "Spanish · SRT",
            index: 2
        )
        XCTAssertEqual(d.title, "Español")
        XCTAssertNil(d.caption)
    }

    // MARK: - Language names

    func testLanguageDisplayNameVariants() {
        XCTAssertEqual(TrackNaming.languageDisplayName("eng"), "Inglés")
        XCTAssertEqual(TrackNaming.languageDisplayName("en-US"), "Inglés")
        XCTAssertEqual(TrackNaming.languageDisplayName("EN"), "Inglés")
        XCTAssertEqual(TrackNaming.languageDisplayName("spa"), "Español")
        XCTAssertEqual(TrackNaming.languageDisplayName("fre"), "Francés")
        XCTAssertNil(TrackNaming.languageDisplayName("und"))
        XCTAssertNil(TrackNaming.languageDisplayName("zzz"))
        XCTAssertNil(TrackNaming.languageDisplayName(nil))
    }

    // MARK: - Cleaning

    func testCleanTrackName() {
        XCTAssertEqual(
            TrackNaming.cleanTrackName("[ToonsHub] English - [English]"),
            "English"
        )
        XCTAssertEqual(
            TrackNaming.cleanTrackName("[Group] Spanish · SRT"),
            "Spanish"
        )
        XCTAssertNil(TrackNaming.cleanTrackName("Track 2"))
        XCTAssertNil(TrackNaming.cleanTrackName(nil))
    }

    func testDistinctSegmentsAreKept() {
        XCTAssertEqual(
            TrackNaming.cleanTrackName("English - Forced"),
            "English · Forced"
        )
    }

    // MARK: - Audio rows

    func testAudioFallbackPrefix() {
        let d = TrackNaming.display(
            rawName: "Track 1",
            languageCode: nil,
            serverTitle: nil,
            index: 0,
            fallbackPrefix: "Audio"
        )
        XCTAssertEqual(d.title, "Audio 1")
        XCTAssertNil(d.caption)
    }

    func testAudioBareTrackWithLanguage() {
        let d = TrackNaming.display(
            rawName: "Audio 2",
            languageCode: "eng",
            serverTitle: nil,
            index: 1,
            fallbackPrefix: "Audio"
        )
        XCTAssertEqual(d.title, "Inglés")
        XCTAssertNil(d.caption)
    }

    func testChannelLayoutGoesToCaption() {
        let d = TrackNaming.display(
            rawName: "Stereo",
            languageCode: "jpn",
            serverTitle: nil,
            index: 0,
            fallbackPrefix: "Audio"
        )
        XCTAssertEqual(d.title, "Japonés")
        XCTAssertEqual(d.caption, "Stereo")
    }

    func testChannelLayoutWithoutLanguageBecomesTitle() {
        let d = TrackNaming.display(
            rawName: "Stereo",
            languageCode: nil,
            serverTitle: nil,
            index: 0,
            fallbackPrefix: "Audio"
        )
        XCTAssertEqual(d.title, "Stereo")
        XCTAssertNil(d.caption)
    }
}
