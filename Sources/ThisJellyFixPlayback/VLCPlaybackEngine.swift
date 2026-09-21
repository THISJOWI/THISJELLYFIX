import Foundation
import ThisJellyFixCore
import VLCKitSPM

/// VLCKit-based playback engine for maximum format compatibility.
public final class VLCPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let kind: PlaybackEngineKind = .universal

    private let mediaPlayer = VLCMediaPlayer()

    public init() {}

    public func prepare(_ request: PlaybackRequest) async throws {
        let media = VLCMedia(url: request.streamURL)
        mediaPlayer.media = media
    }

    public func play() async {
        mediaPlayer.play()
    }

    public func pause() async {
        mediaPlayer.pause()
    }

    public func stop() async {
        mediaPlayer.stop()
    }

    public func seek(to seconds: Double) async {
        mediaPlayer.time = VLCTime(int: Int32(seconds * 1000))
    }

    public func setPlaybackRate(_ rate: Float) async {
        mediaPlayer.rate = rate
    }

    public func selectAudioTrack(index: Int) async {
        mediaPlayer.selectTrack(at: index, type: .audio)
    }

    public func selectSubtitleTrack(index: Int) async {
        if index < 0 {
            mediaPlayer.deselectAllTextTracks()
        } else {
            mediaPlayer.selectTrack(at: index, type: .text)
        }
    }

    public func loadExternalSubtitle(url: URL) async {
        mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: false)
    }

    public var availableAudioTracks: [AudioTrack] {
        mediaPlayer.audioTracks.enumerated().map { idx, track in
            AudioTrack(id: idx, name: track.trackId ?? "Audio \(idx)")
        }
    }

    public var availableSubtitleTracks: [SubtitleTrack] {
        mediaPlayer.textTracks.enumerated().map { idx, track in
            SubtitleTrack(id: idx, name: track.trackId ?? "Subtitle \(idx)")
        }
    }

    public var currentTime: Double {
        Double(mediaPlayer.time.intValue) / 1000.0
    }

    public var duration: Double {
        guard let mediaLength = mediaPlayer.media?.length else { return 0 }
        return Double(mediaLength.intValue) / 1000.0
    }

    public var isPlaying: Bool {
        mediaPlayer.isPlaying
    }

    /// Direct access to the VLCMediaPlayer for rendering.
    public func vlcMediaPlayer() -> VLCMediaPlayer {
        mediaPlayer
    }
}
