import Foundation
import QuartzCore
import ThisJellyFixCore

/// The stable boundary for AVFoundation, an eventual universal player, and server-transcoded streams.
///
/// Post-VLCKit this protocol is the single seam: `AVPlaybackEngine` is the
/// only implementation, but the view model talks to the protocol so the
/// rendering layer, state callbacks and track lists stay engine-agnostic.
public protocol PlaybackEngine: Sendable {
    /// Lifecycle transitions (ready / ended / failed). Fired on the main actor.
    var onStateChanged: ((PlaybackEngineState) -> Void)? { get set }
    func prepare(_ request: PlaybackRequest) async throws
    func play() async
    func pause() async
    func stop() async
    /// Synchronous teardown for `onDisappear` — the view may be gone before
    /// any async hop lands.
    func stopSync()
    func seek(to seconds: Double) async
    func seekRelative(_ deltaSeconds: Double) async
    func setPlaybackRate(_ rate: Float) async
    /// Fit (letterbox) vs fill (cover, crop overflow), applied to the
    /// rendering layer so subtitle placement follows the visible region.
    func setVideoFill(_ fill: Bool)
    func selectAudioTrack(index: Int) async
    /// `-1` turns subtitles off.
    func selectSubtitleTrack(index: Int) async
    var availableAudioTracks: [AudioTrack] { get async }
    var availableSubtitleTracks: [SubtitleTrack] { get async }
    var currentTime: Double { get async }
    var duration: Double { get async }
    var isPlaying: Bool { get async }
    /// Natural video size (0×0 until the first frame decodes).
    var videoSize: CGSize { get async }
    /// Layer the view must host (AVPlayerLayer for `AVPlaybackEngine`).
    /// PiP downcasts it to AVPlayerLayer.
    var renderingLayer: CALayer? { get }
}

/// Engine lifecycle — replaces VLCKit's state enum. `.ended` is a REAL
/// end-of-media signal (AVPlayerItemDidPlayToEndTime), which is what killed
/// the old `currentTime >= duration - 1.5` guess.
public enum PlaybackEngineState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

public struct PlaybackRequest: Sendable, Equatable {
    public let itemID: String
    public let streamURL: URL
    /// Hint only: `AVPlaybackEngine` opens at 0 and the view model seeks
    /// explicitly after play (the VLCKit `:start-time` freeze made the
    /// post-play seek the one proven-safe path; keep it).
    public let startTime: Double?

    public init(itemID: String, streamURL: URL, startTime: Double? = nil) {
        self.itemID = itemID
        self.streamURL = streamURL
        self.startTime = startTime
    }
}
