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

    // MARK: - Dependencies
    private let engine: VLCPlaybackEngine
    private var updateTimer: Timer?
    private var tracksLoaded = false
    private var trackLoadAttempts = 0

    init(engine: VLCPlaybackEngine = VLCPlaybackEngine()) {
        self.engine = engine
    }

    // MARK: - Playback Control

    func prepareStream(url: URL) async {
        do {
            let request = PlaybackRequest(itemID: "", streamURL: url)
            try await engine.prepare(request)
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
        try? await Task.sleep(for: .milliseconds(300))
        isSeeking = false
    }

    func seekRelative(_ delta: Double) async {
        isSeeking = true
        await engine.seekRelative(delta)
        // Update time estimate immediately for responsive UI
        currentTime = max(0, min(currentTime + delta, duration))
        try? await Task.sleep(for: .milliseconds(300))
        isSeeking = false
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

    func startUpdating() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isSeeking else { return }
                self.currentTime = await self.engine.currentTime
                self.duration = await self.engine.duration
                self.isPlaying = await self.engine.isPlaying

                // Retry loading tracks until they appear (VLC needs time to parse)
                if !self.tracksLoaded {
                    self.trackLoadAttempts += 1
                    let audioCount = await self.engine.audioTrackCount
                    let textCount = await self.engine.textTrackCount
                    let dur = self.duration
                    let log = "[PlayerViewModel] attempt=\(self.trackLoadAttempts) audioCount=\(audioCount) textCount=\(textCount) duration=\(dur)\n"
                    let logPath = NSTemporaryDirectory() + "tjf_playback.log"
                    if let fd = fopen(logPath, "a") {
                        fputs(log, fd)
                        fclose(fd)
                    }
                    // Wait until we have text tracks (subtitles) or exhaust attempts
                    // Give extra time for subtitle tracks to appear
                    if self.trackLoadAttempts > 30 {
                        self.tracksLoaded = true
                        await self.loadTracks()
                    } else if audioCount > 0 && textCount > 0 {
                        self.tracksLoaded = true
                        await self.loadTracks()
                    } else if audioCount > 0 && self.trackLoadAttempts > 12 {
                        // Audio found but no subs yet — they might not exist, load anyway
                        self.tracksLoaded = true
                        await self.loadTracks()
                    }
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

        let audioCount = availableAudioTracks.count
        let subCount = availableSubtitleTracks.count
        let log = "[PlayerViewModel] loadTracks: audio=\(audioCount) subs=\(subCount)\n"
        let logPath = NSTemporaryDirectory() + "tjf_playback.log"
        if let fd = fopen(logPath, "a") {
            fputs(log, fd)
            fclose(fd)
        }
    }

    func stop() async {
        await engine.stop()
        stopUpdating()
    }

    func vlcMediaPlayer() -> VLCMediaPlayer {
        engine.vlcMediaPlayer()
    }

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
