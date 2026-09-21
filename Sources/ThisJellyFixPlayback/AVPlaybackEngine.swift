import AVFoundation
import Foundation
import ThisJellyFixCore

/// AVFoundation-based playback engine for direct stream and transcoded content.
public final class AVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let kind: PlaybackEngineKind = .native

    private var player: AVPlayer?
    private var currentStreamURL: URL?

    public init() {}

    public func prepare(_ request: PlaybackRequest) async throws {
        currentStreamURL = request.streamURL
        let playerItem = AVPlayerItem(url: request.streamURL)
        player = AVPlayer(playerItem: playerItem)
    }

    public func play() async {
        player?.play()
    }

    public func pause() async {
        player?.pause()
    }

    public func stop() async {
        player?.pause()
        await player?.seek(to: .zero)
        player = nil
        currentStreamURL = nil
    }

    public func seek(to seconds: Double) async {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        await player?.seek(to: time)
    }

    public func setPlaybackRate(_ rate: Float) async {
        player?.rate = rate
    }

    public func selectAudioTrack(index: Int) async {
        // AVPlayer does not support track selection
    }

    public func selectSubtitleTrack(index: Int) async {
        // AVPlayer does not support track selection
    }

    public func loadExternalSubtitle(url: URL) async {
        // AVPlayer does not support external subtitles
    }

    public var availableAudioTracks: [AudioTrack] { [] }
    public var availableSubtitleTracks: [SubtitleTrack] { [] }

    public var currentTime: Double {
        player?.currentTime().seconds ?? 0
    }

    public var duration: Double {
        player?.currentItem?.duration.seconds ?? 0
    }

    public var isPlaying: Bool {
        player?.rate != 0 && player != nil
    }

    /// Returns the underlying AVPlayer for use with AVPlayerViewController.
    public func makePlayer() -> AVPlayer? {
        player
    }
}
