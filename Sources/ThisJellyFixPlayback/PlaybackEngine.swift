import Foundation
import ThisJellyFixCore

/// The stable boundary for AVFoundation, an eventual universal player, and server-transcoded streams.
public protocol PlaybackEngine: Sendable {
    var kind: PlaybackEngineKind { get }
    func prepare(_ request: PlaybackRequest) async throws
    func play() async
    func pause() async
    func stop() async
    func seek(to seconds: Double) async
    func setPlaybackRate(_ rate: Float) async
    func selectAudioTrack(index: Int) async
    func selectSubtitleTrack(index: Int) async
    func loadExternalSubtitle(url: URL) async
    var availableAudioTracks: [AudioTrack] { get async }
    var availableSubtitleTracks: [SubtitleTrack] { get async }
    var currentTime: Double { get async }
    var duration: Double { get async }
    var isPlaying: Bool { get async }
}

public enum PlaybackEngineKind: String, Sendable {
    case native
    case universal
    case jellyfinTranscoded
}

public struct PlaybackRequest: Sendable, Equatable {
    public let itemID: String
    public let streamURL: URL
    /// Preferred start position in seconds — engines apply it when opening the media
    /// so resume doesn't need a post-play seek (which re-buffers HTTP streams).
    public let startTime: Double?

    public init(itemID: String, streamURL: URL, startTime: Double? = nil) {
        self.itemID = itemID
        self.streamURL = streamURL
        self.startTime = startTime
    }
}
