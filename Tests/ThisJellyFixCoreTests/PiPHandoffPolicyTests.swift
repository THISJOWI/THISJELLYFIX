import XCTest
@testable import ThisJellyFixCore

final class PiPHandoffPolicyTests: XCTestCase {
    private func canAutoStart(
        isPlaying: Bool = false,
        userPaused: Bool = false,
        position: Double = 0,
        duration: Double = 1800,
        engineStopped: Bool = false,
        hasError: Bool = false
    ) -> Bool {
        PiPHandoffPolicy.canAutoStart(
            isPlaying: isPlaying,
            userPaused: userPaused,
            position: position,
            duration: duration,
            engineStopped: engineStopped,
            hasError: hasError
        )
    }

    func testPlayingItemHandsOff() {
        XCTAssertTrue(canAutoStart(isPlaying: true, position: 10))
    }

    func testEngineLieStillHandsOff() {
        // VLCKit reporting false while time advances must not skip the
        // swipe-up handoff — that was "no me persigue el reproductor".
        XCTAssertTrue(canAutoStart(isPlaying: false, userPaused: false, position: 120))
    }

    func testUserPausedNeverHandsOff() {
        XCTAssertFalse(canAutoStart(isPlaying: false, userPaused: true, position: 120))
    }

    func testUserPausedBeatsStaleEngineReport() {
        // The timer refreshes `isPlaying` from the engine every 0.5s: right
        // after a pause tap the engine can still say "playing", but the user's
        // intent must win — otherwise a swipe-up floats a paused player away.
        XCTAssertTrue(canAutoStart(isPlaying: true, userPaused: false, position: 120))
        XCTAssertFalse(canAutoStart(isPlaying: true, userPaused: true, position: 120))
    }

    func testFinalSecondsCountAsFinished() {
        // Same 1.5s threshold the player uses to turn EndReached into
        // "finished" instead of an error: never float a completed episode.
        XCTAssertFalse(canAutoStart(isPlaying: false, position: 1799.5, duration: 1800))
        XCTAssertTrue(canAutoStart(isPlaying: false, position: 1797.0, duration: 1800))
    }

    func testPausedAtStartNeverHandsOff() {
        // Nothing watched yet: a swipe-up must not open a floating window.
        XCTAssertFalse(canAutoStart(isPlaying: false, position: 0))
    }

    func testFinishedItemNeverHandsOff() {
        XCTAssertFalse(canAutoStart(isPlaying: false, position: 1800, duration: 1800))
    }

    func testPlayingFlagStillRefusesFinishedItem() {
        // Natural end: engine may briefly still claim `isPlaying` while the
        // clock sits at the very end — a completed episode never floats away.
        XCTAssertFalse(canAutoStart(isPlaying: true, position: 1799.8, duration: 1800))
    }

    func testLiveOrUnknownDurationHandsOffMidStream() {
        // duration <= 0 (live / not yet known) + a position = still playing.
        XCTAssertTrue(canAutoStart(isPlaying: false, position: 42, duration: 0))
        XCTAssertTrue(canAutoStart(isPlaying: false, position: 42, duration: -1))
    }

    func testStoppedEngineNeverHandsOff() {
        XCTAssertFalse(canAutoStart(isPlaying: true, engineStopped: true))
    }

    func testErrorStateNeverHandsOff() {
        XCTAssertFalse(canAutoStart(isPlaying: true, hasError: true))
    }
}
