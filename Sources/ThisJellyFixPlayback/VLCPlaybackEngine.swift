import Foundation
import ThisJellyFixCore
import VLCKitSPM

/// VLCKit-based playback engine for maximum format compatibility.
public final class VLCPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let kind: PlaybackEngineKind = .universal

    private let mediaPlayer: VLCMediaPlayer

    public init() {
        // Configure VLC for stable network streaming
        mediaPlayer = VLCMediaPlayer(
            options: [
                "--network-caching=10000",
                "--file-caching=1000",
                "--live-caching=1000",
                "--sout-mux-caching=1000",
                "--no-video-title-show",
            ]
        )
    }

    deinit {
        // Detach drawable first so VLC render thread doesn't access freed view,
        // then stop. libvlc_media_player_release joins threads — must be safe.
        mediaPlayer.drawable = nil
        mediaPlayer.stop()
    }

    public func prepare(_ request: PlaybackRequest) async throws {
        let media = VLCMedia(url: request.streamURL)
        mediaPlayer.media = media

        // Brief pause so the media object is fully associated
        try? await Task.sleep(for: .milliseconds(150))
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
        // Use jumpForward/jumpBackward for reliable seeking in VLC 4.0
        // VLC ignores time/position setters on many formats
        let currentMs = Double(mediaPlayer.time.intValue)
        let targetMs = seconds * 1000.0
        let deltaMs = targetMs - currentMs

        // Minimum jump of 1 second to avoid truncation to 0
        guard abs(deltaMs) > 1000 else { return }

        if deltaMs > 0 {
            mediaPlayer.jumpForward(deltaMs / 1000.0)
        } else {
            mediaPlayer.jumpBackward(-deltaMs / 1000.0)
        }
    }

    public func seekRelative(_ deltaSeconds: Double) async {
        if deltaSeconds > 0 {
            mediaPlayer.jumpForward(deltaSeconds)
        } else if deltaSeconds < 0 {
            mediaPlayer.jumpBackward(-deltaSeconds)
        }
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
            AudioTrack(id: idx, name: track.trackName ?? track.trackId ?? "Audio \(idx)", language: track.language)
        }
    }

    public var availableSubtitleTracks: [SubtitleTrack] {
        mediaPlayer.textTracks.enumerated().map { idx, track in
            SubtitleTrack(id: idx, name: track.trackName ?? track.trackId ?? "Subtitle \(idx)", language: track.language)
        }
    }

    public var audioTrackCount: Int {
        mediaPlayer.audioTracks.count
    }

    public var textTrackCount: Int {
        mediaPlayer.textTracks.count
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
