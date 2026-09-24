import Foundation
import ThisJellyFixCore
import VLCKitSPM

/// VLCKit-based playback engine for maximum format compatibility.
public final class VLCPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public let kind: PlaybackEngineKind = .universal

    private let mediaPlayer: VLCMediaPlayer

    /// One-time libvlc file logger — captures internal messages (es_out,
    /// decoder, "slave N EOF", demux) that TJFLog alone can't show.
    private static let installVLCLoggerOnce: Void = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tjf-vlc.log")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            let logger = VLCFileLogger.create(with: handle)
            logger.level = .debug
            VLCLibrary.shared().loggers = [logger]
            TJFLog("VLC file logger ON → \(url.path)")
        } catch {
            TJFLog("VLC file logger FAILED: \(error)")
        }
    }()

    public init() {
        _ = Self.installVLCLoggerOnce
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
        // VLC letterboxes natively (videoFitMode) — subs are composed by VLC
        // inside the visible area, so they follow fit/fill correctly.
        mediaPlayer.videoFitMode = .smaller
    }

    /// Fit (letterbox) or fill (cover, crop overflow) — VLC-native so the
    /// subtitle layer is positioned within the VISIBLE region, unlike a
    /// post-render SwiftUI scale that crops subs off-screen.
    public func setVideoFill(_ fill: Bool) async {
        mediaPlayer.videoFitMode = fill ? .larger : .smaller
    }

    /// Native video size (0 until the vout reports it).
    public var videoSize: CGSize {
        mediaPlayer.videoSize
    }

    deinit {
        // Detach drawable first so VLC render thread doesn't access freed view,
        // then stop. libvlc_media_player_release joins threads — must be safe.
        mediaPlayer.drawable = nil
        mediaPlayer.stop()
    }

    public func prepare(_ request: PlaybackRequest) async throws {
        let media = VLCMedia(url: request.streamURL)
        // Open DIRECTLY at the resume position via input option — VLC seeks as part
        // of opening the media, so there is no open-at-0 → seek → HTTP re-buffer
        // round trip (the slow resume). Must be added before playback starts.
        if let media, let start = request.startTime, start > 0 {
            media.addOption(":start-time=\(Int(start))")
        }
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

    /// Synchronous stop — call from onDisappear to guarantee VLC stops before view deallocation.
    public func stopSync() {
        mediaPlayer.stop()
    }

    public func seek(to seconds: Double) async {
        // Use position (0.0-1.0) — more reliable than time setter or jumps
        guard let length = mediaPlayer.media?.length else { return }
        let dur = Double(length.intValue) / 1000.0
        guard dur > 0 else { return }
        mediaPlayer.position = seconds / dur
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
