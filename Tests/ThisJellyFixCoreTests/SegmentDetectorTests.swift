import XCTest
@testable import ThisJellyFixCore

final class SegmentDetectorTests: XCTestCase {
    private let intro = SegmentMarker(type: .intro, start: 10, end: 70)
    private let credits = SegmentMarker(type: .credits, start: 600, end: nil)
    private let markers = [
        SegmentMarker(type: .intro, start: 10, end: 70),
        SegmentMarker(type: .credits, start: 600, end: nil),
    ]

    func testOutsideAnySegmentReturnsNone() {
        var detector = SegmentDetector()
        let outcome = detector.tick(time: 500, delta: 0.5, markers: markers, settings: SkipSettings())
        XCTAssertEqual(outcome, .none)
        XCTAssertNil(detector.activeMarker)
    }

    func testInsideSegmentShowsButtonWithCountdown() {
        var detector = SegmentDetector()
        let outcome = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
        guard case .show(let marker, let countdown) = outcome else {
            return XCTFail("expected .show, got \(outcome)")
        }
        XCTAssertEqual(marker, intro)
        XCTAssertEqual(countdown ?? -1, 4.5, accuracy: 0.001)
    }

    func testAutoSkipTriggersAfterDelay() {
        var detector = SegmentDetector()
        var last: SegmentDetector.Outcome = .none
        // 11 ticks × 0.5s = 5.5s > 5s default delay
        for _ in 0..<11 {
            last = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
        }
        XCTAssertEqual(last, .triggerSkip(intro))
    }

    func testAutoSkipDisabledNeverTriggers() {
        var detector = SegmentDetector()
        var settings = SkipSettings()
        settings.autoSkip = false
        var countdowns: [Double?] = []
        for _ in 0..<100 {
            if case .show(_, let countdown) = detector.tick(time: 20, delta: 0.5, markers: markers, settings: settings) {
                countdowns.append(countdown)
            }
        }
        XCTAssertEqual(countdowns.count, 100)
        XCTAssertTrue(countdowns.allSatisfy { $0 == nil })
    }

    func testDisabledTypeInSettingsHidden() {
        var detector = SegmentDetector()
        var settings = SkipSettings()
        settings.introEnabled = false
        let outcome = detector.tick(time: 20, delta: 0.5, markers: markers, settings: settings)
        XCTAssertEqual(outcome, .none)
    }

    func testMarkSkippedSuppressesReveal() {
        var detector = SegmentDetector()
        detector.markSkipped(intro)
        let outcome = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
        XCTAssertEqual(outcome, .none)
    }

    func testManualSkipDismissesUntilLeavingSegment() {
        var detector = SegmentDetector()
        _ = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
        detector.markSkipped(intro)
        // Still inside intro — must stay hidden
        XCTAssertEqual(detector.tick(time: 60, delta: 0.5, markers: markers, settings: SkipSettings()), .none)
        // Left and re-entered — dismissed set still suppresses (per-session rule)
        XCTAssertEqual(detector.tick(time: 500, delta: 0.5, markers: markers, settings: SkipSettings()), .none)
        XCTAssertEqual(detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings()), .none)
    }

    func testZeroDeltaFreezesCountdown() {
        var detector = SegmentDetector()
        let first = detector.tick(time: 20, delta: 0, markers: markers, settings: SkipSettings())
        let second = detector.tick(time: 20, delta: 0, markers: markers, settings: SkipSettings())
        guard case .show(_, let c1) = first, case .show(_, let c2) = second else {
            return XCTFail("expected .show twice")
        }
        XCTAssertEqual(c1 ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(c1, c2)
    }

    func testCountdownResetsWhenSwitchingSegments() {
        var detector = SegmentDetector()
        // Dwell 4s in intro
        for _ in 0..<8 {
            _ = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
        }
        // Jump into credits — fresh countdown
        let outcome = detector.tick(time: 610, delta: 0.5, markers: markers, settings: SkipSettings())
        guard case .show(let marker, let countdown) = outcome else {
            return XCTFail("expected .show, got \(outcome)")
        }
        XCTAssertEqual(marker, credits)
        XCTAssertEqual(countdown ?? -1, 4.5, accuracy: 0.001)
    }

    func testTriggerSkipThenMarkKeepsHidden() {
        var detector = SegmentDetector()
        var outcome: SegmentDetector.Outcome = .none
        for _ in 0..<11 {
            outcome = detector.tick(time: 20, delta: 0.5, markers: markers, settings: SkipSettings())
            if outcome == .triggerSkip(intro) {
                detector.markSkipped(intro)
            }
        }
        XCTAssertEqual(outcome, .none) // no re-trigger after dismissal
    }

    func testInvalidMarkersIgnored() {
        var detector = SegmentDetector()
        let bad = SegmentMarker(type: .intro, start: 50, end: 50) // invalid: end == start
        let outcome = detector.tick(time: 50, delta: 0.5, markers: [bad], settings: SkipSettings())
        XCTAssertEqual(outcome, .none)
    }
}
