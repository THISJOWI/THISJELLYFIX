import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking
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
    private var timerTickCount = 0

    // MARK: - Server media streams (external subtitles)
    private var serverMediaStreams: [MediaStream] = []
    private var externalSubsLoaded = false

    // MARK: - Playback Reporting
    private var reporter = JellyfinPlaybackReporter()
    private var reportingSessionId: String?
    private var hasReportedPlaying = false
    private var lastProgressReport: Date?
    private var itemId: String?
    private var serverURL: URL?
    private var token: String?
    private var userId: String?
    private var reportingConfigured = false

    init(engine: VLCPlaybackEngine = VLCPlaybackEngine()) {
        self.engine = engine
    }

    /// Configure playback reporting. Call before starting playback.
    func configureReporting(userId: String, serverURL: URL, token: String, itemId: String, playSessionId: String? = nil) {
        self.userId = userId
        self.serverURL = serverURL
        self.token = token
        self.itemId = itemId
        // Echo the server-issued PlaySessionId so reports attach to the right session.
        self.reportingSessionId = playSessionId ?? UUID().uuidString
        self.reporter.playSessionId = playSessionId
        self.reportingConfigured = true
        TJFLog("configureReporting OK itemId=\(itemId) server=\(serverURL.absoluteString) user=\(userId) tokenLen=\(token.count) playSessionId=\(playSessionId ?? "nil")")
    }

    /// Server-declared media streams — used to find external subtitle files
    /// that don't exist inside the container VLC parses.
    func configureMediaStreams(_ streams: [MediaStream]) {
        serverMediaStreams = streams
        TJFLog("configureMediaStreams total=\(streams.count) extSubs=\(streams.filter { $0.type == "Subtitle" && $0.isExternal == true }.count)")
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
        // Use VLC's position setter — more reliable than time setter for all formats
        let vlcPlayer = engine.vlcMediaPlayer()
        let dur = await engine.duration
        if dur > 0 {
            vlcPlayer.position = seconds / dur
        }
        // Wait for VLC to settle after seek
        try? await Task.sleep(for: .milliseconds(500))
        // Read back actual time from VLC
        currentTime = await engine.currentTime
        isSeeking = false
    }

    func seekRelative(_ delta: Double) async {
        let target = max(0, min(currentTime + delta, duration))
        await seek(to: target)
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

                // Diagnostic log (first 10 ticks only)
                self.timerTickCount += 1
                if self.timerTickCount <= 10 {
                    TJFLog("timer tick=\(self.timerTickCount) isPlaying=\(self.isPlaying) reportingConfigured=\(self.reportingConfigured) hasReported=\(self.hasReportedPlaying) time=\(self.currentTime) dur=\(self.duration)")
                }

                // Determine if playback is active — use time advancement as fallback
                // because VLCKit's isPlaying can return false even when playing
                let playbackActive = self.isPlaying || (self.currentTime > 0 && self.currentTime < self.duration)

                // Report "playing" once when playback starts (only if reporting configured)
                if self.reportingConfigured, playbackActive, !self.hasReportedPlaying {
                    self.hasReportedPlaying = true
                    self.reportPlayStarted()
                }

                // Report progress every 10 seconds (only if reporting configured)
                if self.reportingConfigured {
                    if playbackActive, let last = self.lastProgressReport,
                       Date().timeIntervalSince(last) >= 10 {
                        self.reportProgress()
                    } else if self.lastProgressReport == nil, self.currentTime > 0 {
                        self.reportProgress()
                    }
                }

                // Retry loading tracks until they appear (VLC needs time to parse)
                self.trackLoadAttempts += 1
                if !self.tracksLoaded {
                    let audioCount = await self.engine.audioTrackCount
                    let textCount = await self.engine.textTrackCount
                    TJFLog("attempt=\(self.trackLoadAttempts) audio=\(audioCount) text=\(textCount) dur=\(self.duration)")
                    // Load as soon as audio tracks appear — don't block on subtitles.
                    // VLC parses subtitle tracks lazily; they can appear 10-60s after audio.
                    if audioCount > 0 {
                        self.tracksLoaded = true
                        await self.loadTracks()
                    } else if self.trackLoadAttempts > 60 {
                        // After 30s with no audio at all — give up
                        self.tracksLoaded = true
                        await self.loadTracks()
                    }
                } else if self.trackLoadAttempts <= 240 {
                    // Keep checking for new tracks for up to 2 min (subtitles may appear very late)
                    let audioCount = await self.engine.audioTrackCount
                    let textCount = await self.engine.textTrackCount
                    let currentTotal = self.availableAudioTracks.count + self.availableSubtitleTracks.count
                    let newTotal = audioCount + textCount
                    if newTotal > currentTotal {
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

        TJFLog("loadTracks audio=\(availableAudioTracks.count) subs=\(availableSubtitleTracks.count)")

        await addExternalSubtitlesIfNeeded()
    }

    /// Server-side external subtitle files (.srt next to the video) are NOT inside
    /// the container VLC parses, so they never show up in VLC's track list.
    /// Load them explicitly as playback slaves — the track re-poll picks them up.
    private func addExternalSubtitlesIfNeeded() async {
        // Don't consume the flag before the streams are actually configured.
        guard !externalSubsLoaded, !serverMediaStreams.isEmpty else { return }
        guard reportingConfigured, let itemId, let serverURL, let token else { return }
        externalSubsLoaded = true

        let extStreams = serverMediaStreams.filter { $0.type == "Subtitle" && $0.isExternal == true }
        guard !extStreams.isEmpty else {
            TJFLog("extSubs: server declares none")
            return
        }
        for stream in extStreams {
            guard let idx = stream.index else { continue }
            let rawCodec = (stream.codec ?? "srt").lowercased()
            let ext = (rawCodec == "subrip" || rawCodec == "srt") ? "srt" : rawCodec
            let urlString = "\(serverURL.absoluteString)/Videos/\(itemId)/\(itemId)/Subtitles/\(idx)/Stream.\(ext)?api_key=\(token)"
            guard let url = URL(string: urlString) else { continue }
            TJFLog("extSubs load idx=\(idx) codec=\(rawCodec) lang=\(stream.language ?? "-") title=\(stream.title ?? "-")")
            await engine.loadExternalSubtitle(url: url)
        }
    }

    // MARK: - Playback Reporting

    private func reportPlayStarted() {
        guard let userId, let serverURL, let token, let itemId else {
            TJFLog("reportPlayStarted SKIPPED: userId=\(userId != nil) serverURL=\(serverURL != nil) token=\(token != nil) itemId=\(itemId != nil)")
            return
        }
        let mediaSourceId = itemId
        TJFLog("reportPlayStarted itemId=\(itemId)")
        Task {
            await reporter.reportPlaying(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, mediaSourceId: mediaSourceId
            )
        }
    }

    private func reportProgress() {
        guard let userId, let serverURL, let token, let itemId else {
            TJFLog("reportProgress SKIPPED: userId=\(userId != nil) serverURL=\(serverURL != nil) token=\(token != nil) itemId=\(itemId != nil)")
            return
        }
        let ticks = Int64(currentTime * 10_000_000) // 1 tick = 100ns
        lastProgressReport = Date()
        TJFLog("reportProgress itemId=\(itemId) ticks=\(ticks)")
        Task {
            await reporter.reportProgress(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, mediaSourceId: itemId,
                positionTicks: ticks, isPaused: !isPlaying
            )
        }
    }

    private func reportStopped() {
        guard let userId, let serverURL, let token, let itemId else {
            TJFLog("reportStopped SKIPPED: userId=\(userId != nil) serverURL=\(serverURL != nil) token=\(token != nil) itemId=\(itemId != nil)")
            return
        }
        let ticks = Int64(currentTime * 10_000_000)
        TJFLog("reportStopped itemId=\(itemId) ticks=\(ticks)")
        Task {
            await reporter.reportStopped(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, mediaSourceId: itemId,
                positionTicks: ticks
            )
        }
    }

    func stop() async {
        reportStopped()
        await engine.stop()
        stopUpdating()
    }

    /// Synchronous stop — call from onDisappear to ensure VLC stops before the view is deallocated.
    func stopSync() {
        reportStopped()
        engine.stopSync()
        stopUpdating()
    }

    /// Detach the drawable so VLC's render thread stops accessing the view.
    func detachDrawable() {
        engine.vlcMediaPlayer().drawable = nil
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
