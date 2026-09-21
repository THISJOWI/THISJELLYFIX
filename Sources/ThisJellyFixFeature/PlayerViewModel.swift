import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixPlayback
import VLCKitSPM

@MainActor
@Observable
final class PlayerViewModel {
    // MARK: - Playback State
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var isSeeking = false

    // MARK: - Tracks
    var availableAudioTracks: [AudioTrack] = []
    var availableSubtitleTracks: [SubtitleTrack] = []
    var selectedAudioTrackIndex: Int?
    var selectedSubtitleTrackIndex: Int?

    // MARK: - UI State
    var showControls = true
    var showAudioPicker = false
    var showSubtitlePicker = false
    var showSpeedPicker = false
    var showQualityPicker = false
    var errorMessage: String?

    // MARK: - Brightness & Volume
    #if os(iOS)
    var brightness: CGFloat = UIScreen.main.brightness
    #else
    var brightness: CGFloat = 0.5
    #endif
    var systemVolume: Float = 1.0

    // MARK: - Dependencies
    private let engine: VLCPlaybackEngine
    private var updateTimer: Timer?

    init(engine: VLCPlaybackEngine = VLCPlaybackEngine()) {
        self.engine = engine
    }

    // MARK: - Playback Control

    func prepareStream(url: URL) async {
        do {
            let request = PlaybackRequest(itemID: "", streamURL: url)
            try await engine.prepare(request)
            // Don't load tracks here — VLC hasn't parsed them yet.
            // Tracks will be loaded by startUpdating() after play begins.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayPause() async {
        if isPlaying {
            await engine.pause()
        } else {
            await engine.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) async {
        isSeeking = true
        currentTime = seconds
        await engine.seek(to: seconds)
        // Give VLC time to process the seek before resuming timer updates
        try? await Task.sleep(for: .milliseconds(200))
        isSeeking = false
    }

    func seekRelative(_ delta: Double) async {
        let newTime = max(0, min(currentTime + delta, duration))
        await seek(to: newTime)
    }

    func setPlaybackRate(_ rate: Float) async {
        await engine.setPlaybackRate(rate)
        playbackRate = rate
    }

    // MARK: - Track Selection

    func selectAudioTrack(_ track: AudioTrack?) async {
        guard let track else { return }
        await engine.selectAudioTrack(index: track.id)
        selectedAudioTrackIndex = track.id
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) async {
        if let track {
            await engine.selectSubtitleTrack(index: track.id)
            selectedSubtitleTrackIndex = track.id
        } else {
            await engine.selectSubtitleTrack(index: -1)
            selectedSubtitleTrackIndex = nil
        }
    }

    func loadExternalSubtitle(url: URL) async {
        await engine.loadExternalSubtitle(url: url)
        await loadTracks()
    }

    // MARK: - Timer

    private var tracksLoaded = false

    func startUpdating() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isSeeking else { return }
                self.currentTime = await self.engine.currentTime
                self.duration = await self.engine.duration
                self.isPlaying = await self.engine.isPlaying

                // Load tracks once VLC has parsed the media (duration > 0)
                if !self.tracksLoaded, self.duration > 0 {
                    self.tracksLoaded = true
                    await self.loadTracks()
                }
            }
        }
    }

    func stopUpdating() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Private

    private func loadTracks() async {
        availableAudioTracks = await engine.availableAudioTracks
        availableSubtitleTracks = await engine.availableSubtitleTracks
    }

    func stop() async {
        await engine.stop()
        stopUpdating()
    }

    /// Expose the underlying VLCMediaPlayer for rendering.
    func vlcMediaPlayer() -> VLCMediaPlayer {
        engine.vlcMediaPlayer()
    }

    /// Attach a view as the video output using the drawable property.
    #if os(macOS)
    func attachDrawable(_ view: Any) {
        engine.vlcMediaPlayer().drawable = view
    }
    #elseif os(iOS)
    func attachDrawable(_ view: UIView) {
        engine.vlcMediaPlayer().drawable = view
    }
    #endif
}
