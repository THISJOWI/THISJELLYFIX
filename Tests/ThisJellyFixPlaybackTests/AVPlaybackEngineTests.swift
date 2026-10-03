import AVFoundation
import XCTest
@testable import ThisJellyFixPlayback

/// Smoke tests for the AVPlayer engine seam: lifecycle, non-UI operations and
/// the fact that nothing here needs a drawable (the VLC-era failure mode).
final class AVPlaybackEngineTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let engine = AVPlaybackEngine()
        XCTAssertNotNil(engine.renderingLayer)
        XCTAssertTrue(engine.renderingLayer === engine.playerLayer)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(engine.duration, 0, accuracy: 0.001)
        XCTAssertEqual(engine.videoSize, .zero)
        XCTAssertEqual(engine.playerLayer.videoGravity, .resizeAspect)
        XCTAssertTrue(engine.availableAudioTracks.isEmpty)
        XCTAssertTrue(engine.availableSubtitleTracks.isEmpty)
    }

    @MainActor
    func testTransportCallsAreSafeBeforePrepare() async {
        let engine = AVPlaybackEngine()
        // No AVPlayerItem yet: play/pause/seek/stop must be no-ops, not crashes.
        engine.play()
        engine.pause()
        await engine.seek(to: 12)
        await engine.seekRelative(15)
        engine.setPlaybackRate(1.5)
        engine.stop()
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        XCTAssertNil(engine.player.currentItem)
    }

    @MainActor
    func testSetVideoFillChangesGravity() {
        let engine = AVPlaybackEngine()
        engine.setVideoFill(true)
        XCTAssertEqual(engine.playerLayer.videoGravity, .resizeAspectFill)
        engine.setVideoFill(false)
        XCTAssertEqual(engine.playerLayer.videoGravity, .resizeAspect)
    }

    @MainActor
    func testPrepareWithBadURLFailsWithCallback() async throws {
        let engine = AVPlaybackEngine()
        let failed = expectation(description: "engine reports .failed")
        var sawLoading = false
        engine.onStateChanged = { state in
            switch state {
            case .loading:
                sawLoading = true
            case .failed:
                failed.fulfill()
            default:
                break
            }
        }

        let url = URL(string: "https://127.0.0.1:1/definitely-not-here.m3u8")!
        try await engine.prepare(PlaybackRequest(itemID: "x", streamURL: url))
        XCTAssertTrue(sawLoading, "prepare must report .loading before resolving")

        await fulfillment(of: [failed], timeout: 10)
        engine.stop()
    }

    @MainActor
    func testStopClearsItemAndNotifiesIdle() async throws {
        let engine = AVPlaybackEngine()
        let url = URL(string: "https://127.0.0.1:1/item.m3u8")!
        try await engine.prepare(PlaybackRequest(itemID: "x", streamURL: url))
        XCTAssertNotNil(engine.player.currentItem)

        let idle = expectation(description: "idle after stop")
        engine.onStateChanged = { state in
            if state == .idle { idle.fulfill() }
        }
        engine.stop()
        XCTAssertNil(engine.player.currentItem)
        await fulfillment(of: [idle], timeout: 5)
    }

    @MainActor
    func testSatisfiesProtocolSeam() {
        // The view model talks to the protocol — keep the conformance real.
        let engine: any PlaybackEngine = AVPlaybackEngine()
        engine.setVideoFill(true)
        XCTAssertEqual(engine.renderingLayer === (engine as? AVPlaybackEngine)?.playerLayer, true)
    }
}
