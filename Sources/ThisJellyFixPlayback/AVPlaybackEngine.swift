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

    // MARK: - Properties

    public var isPlaying: Bool {
        player?.rate != 0 && player != nil
    }

    public var currentTime: Double {
        player?.currentTime().seconds ?? 0
    }

    public var duration: Double {
        player?.currentItem?.duration.seconds ?? 0
    }

    public func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        Task {
            await player?.seek(to: time)
        }
    }

    /// Returns the underlying AVPlayer for use with AVPlayerViewController.
    public func makePlayer() -> AVPlayer? {
        player
    }
}
