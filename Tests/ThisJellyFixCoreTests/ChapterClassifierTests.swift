import XCTest
@testable import ThisJellyFixCore

final class ChapterClassifierTests: XCTestCase {
    // MARK: - classify

    func testIntroNames() {
        XCTAssertEqual(ChapterClassifier.classify(name: "Intro"), .intro)
        XCTAssertEqual(ChapterClassifier.classify(name: "intro"), .intro)
        XCTAssertEqual(ChapterClassifier.classify(name: "Opening Credits"), .intro)
        XCTAssertEqual(ChapterClassifier.classify(name: "Main Title"), .intro)
        XCTAssertEqual(ChapterClassifier.classify(name: "Abertura"), .intro)
        XCTAssertEqual(ChapterClassifier.classify(name: "  INTRO  "), .intro)
    }

    func testRecapNames() {
        XCTAssertEqual(ChapterClassifier.classify(name: "Previously On"), .recap)
        XCTAssertEqual(ChapterClassifier.classify(name: "Recap"), .recap)
        XCTAssertEqual(ChapterClassifier.classify(name: "Resumen"), .recap)
        XCTAssertEqual(ChapterClassifier.classify(name: "Anteriormente en"), .recap)
    }

    func testCreditsNames() {
        XCTAssertEqual(ChapterClassifier.classify(name: "Credits"), .credits)
        XCTAssertEqual(ChapterClassifier.classify(name: "End Credits"), .credits)
        XCTAssertEqual(ChapterClassifier.classify(name: "Closing Credits"), .credits)
        XCTAssertEqual(ChapterClassifier.classify(name: "Outro"), .credits)
        XCTAssertEqual(ChapterClassifier.classify(name: "Créditos"), .credits)
    }

    func testIrrelevantNamesReturnNil() {
        XCTAssertNil(ChapterClassifier.classify(name: "Act I"))
        XCTAssertNil(ChapterClassifier.classify(name: ""))
        XCTAssertNil(ChapterClassifier.classify(name: "   "))
        XCTAssertNil(ChapterClassifier.classify(name: "Cold Open Battle"))
    }

    func testCaseAndDiacriticInsensitive() {
        XCTAssertEqual(ChapterClassifier.classify(name: "CRÉDITOS"), .credits)
        XCTAssertEqual(ChapterClassifier.classify(name: "prevIOusLY On"), .recap)
    }

    // MARK: - markers

    func testMarkersUseNextChapterAsEnd() {
        let markers = ChapterClassifier.markers(from: [
            (start: 0, name: "Intro"),
            (start: 90, name: "Act I"),
            (start: 600, name: "Credits"),
        ])
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].type, .intro)
        XCTAssertEqual(markers[0].start, 0)
        XCTAssertEqual(markers[0].end, 90) // ends at next chapter
        XCTAssertEqual(markers[1].type, .credits)
        XCTAssertEqual(markers[1].start, 600)
        XCTAssertNil(markers[1].end) // last chapter runs to video end
    }

    func testMarkersSortedByStart() {
        let markers = ChapterClassifier.markers(from: [
            (start: 600, name: "Credits"),
            (start: 0, name: "Intro"),
        ])
        XCTAssertEqual(markers.map(\.type), [.intro, .credits])
    }

    func testUnnamedChaptersIgnored() {
        let markers = ChapterClassifier.markers(from: [
            (start: 0, name: nil),
            (start: 30, name: "Intro"),
        ])
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].type, .intro)
    }

    func testUnknownNamesProduceNoMarkers() {
        let markers = ChapterClassifier.markers(from: [
            (start: 0, name: "Scene 1"),
            (start: 100, name: "Scene 2"),
        ])
        XCTAssertTrue(markers.isEmpty)
    }
}

final class SegmentMarkerTests: XCTestCase {
    func testContainsRange() {
        let marker = SegmentMarker(type: .intro, start: 10, end: 70)
        XCTAssertFalse(marker.contains(9.9))
        XCTAssertTrue(marker.contains(10))
        XCTAssertTrue(marker.contains(69.9))
        XCTAssertFalse(marker.contains(70))
    }

    func testContainsOpenEnded() {
        let marker = SegmentMarker(type: .credits, start: 600, end: nil)
        XCTAssertFalse(marker.contains(599))
        XCTAssertTrue(marker.contains(600))
        XCTAssertTrue(marker.contains(100_000))
    }

    func testValidity() {
        XCTAssertTrue(SegmentMarker(type: .intro, start: 0, end: 30).isValid)
        XCTAssertFalse(SegmentMarker(type: .intro, start: 30, end: 30).isValid)
        XCTAssertFalse(SegmentMarker(type: .intro, start: -1, end: nil).isValid)
    }

    func testStableIdentity() {
        let a = SegmentMarker(type: .intro, start: 10, end: 70)
        let b = SegmentMarker(type: .intro, start: 10, end: 70)
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, SegmentMarker(type: .intro, start: 11, end: 70).id)
    }
}
