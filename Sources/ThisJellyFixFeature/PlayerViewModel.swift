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
    /// true = fill screen (crop), false = fit whole video (letterbox)
    var isFill = true
    var showAudioPicker = false
    var showSubtitlePicker = false
    var showSpeedPicker = false
    var showQualityPicker = false
    var errorMessage: String?

    // MARK: - Skip Segments (intro / recap / credits)
    /// Current skip UI state — driven by the 0.5s playback timer.
    var activeSegment: SegmentMarker?
    /// Seconds until auto-skip fires inside `activeSegment` (nil = auto-skip off).
    var segmentCountdown: Double?
    /// Provided by the view: plays the next episode (nil when unavailable).
    var onPlayNextEpisode: (() -> Void)?
    /// true when a next-episode action is wired (credits shows both buttons).
    var hasNextEpisode = false

    private var segmentDetector = SegmentDetector()
    private var segmentMarkers: [SegmentMarker] = []
    private var segmentClient: any JellyfinSegmentProviding
    private var segmentsLoaded = false
    private var segmentsLoadAttempts = 0
    private var skipInProgress = false

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

    init(engine: VLCPlaybackEngine = VLCPlaybackEngine(), segmentClient: any JellyfinSegmentProviding = JellyfinSegmentClient()) {
        self.engine = engine
        self.segmentClient = segmentClient
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

    /// Stream URL of the current playback — lets the PiP resume path
    /// re-prepare VLC after the view was torn down.
    private var currentStreamURL: URL?
    /// True once VLC has been stopped (view disappeared) — a PiP resume must
    /// re-prepare the media instead of just seeking.
    private var engineStopped = false
    /// The floating PiP session already reported playback stopped (user hit
    /// X) — the fullscreen teardown must not send a second, stale stop.
    private var pipSessionReportedStop = false

    func prepareStream(url: URL, startPosition: Double? = nil) async {
        do {
            // A floating PiP from a previous item must not keep playing (and
            // reporting) over the new playback.
            #if os(iOS)
            if let itemId, PipSession.shared.isActive, PipSession.shared.activeItemId != itemId {
                TJFLog("pip: closing foreign session item=\(PipSession.shared.activeItemId ?? "nil") for new item=\(itemId)")
                PipSession.shared.onRestore = nil
                PipSession.shared.onClosed = nil
                PipSession.shared.closeAndReport()
            }
            #endif
            let request = PlaybackRequest(itemID: "", streamURL: url, startTime: startPosition)
            try await engine.prepare(request)
            currentStreamURL = url
            engineStopped = false
            pipSessionReportedStop = false
            // Apply the persisted fit/fill mode natively so VLC composes
            // subtitles within the visible region from the start.
            await engine.setVideoFill(isFill)
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
        // VLC needs the container length before position (0-1) can be computed.
        var dur = engine.duration
        var waitedMs = 0
        while dur <= 0 && waitedMs < 10000 {
            try? await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
            dur = engine.duration
        }
        guard dur > 0 else {
            // Length never known — let the timer sync currentTime to reality
            isSeeking = false
            return
        }
        vlcPlayer.position = seconds / dur
        // Wait PATIENTLY for the seek to land before judging — HTTP seeks take
        // seconds. Checking at 600ms used to always look "not applied yet" and
        // fired a second seek → double re-buffer → sluggish resume.
        var actual = engine.currentTime
        waitedMs = 0
        while abs(actual - seconds) > 2.0 && waitedMs < 5000 {
            try? await Task.sleep(for: .milliseconds(300))
            waitedMs += 300
            actual = engine.currentTime
        }
        if abs(actual - seconds) > 2.0 {
            // Genuinely didn't land — one retry
            vlcPlayer.position = seconds / dur
            try? await Task.sleep(for: .milliseconds(800))
            actual = engine.currentTime
        }
        currentTime = actual
        isSeeking = false
    }

    /// Initial resume path: the engine may have opened the media already at
    /// `seconds` (start-time input option) — wait for it to arrive instead of
    /// blindly re-seeking (a redundant seek re-buffers the HTTP stream).
    func verifyResume(at seconds: Double) async {
        isSeeking = true
        var actual = engine.currentTime
        var waitedMs = 0
        while abs(actual - seconds) > 2.0 && waitedMs < 4000 {
            try? await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
            actual = engine.currentTime
        }
        if abs(actual - seconds) > 2.0 {
            // start-time didn't take (unusual container/stream) → fallback explicit seek
            isSeeking = false
            await seek(to: seconds)
            return
        }
        currentTime = actual
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

    /// Switch between fill (cover screen) and fit (whole video) modes.
    /// Applied INSIDE VLC (`videoFitMode`) so subtitles stay visible when the
    /// video is cropped to fill the screen.
    func setFill(_ fill: Bool) {
        guard fill != isFill else { return }
        isFill = fill
        Task { await engine.setVideoFill(fill) }
    }

    /// Native video aspect ratio (width/height), nil until known.
    private(set) var videoAspect: CGFloat?

    // MARK: - Track Selection

    func selectAudioTrack(_ track: AudioTrack?) async {
        guard let track else { return }
        await engine.selectAudioTrack(index: track.id)
        selectedAudioTrackIndex = track.id
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) async {
        snapshotTextTracks("before select id=\(track.map { "\($0.id)" } ?? "off")")
        if let track {
            await engine.selectSubtitleTrack(index: track.id)
            selectedSubtitleTrackIndex = track.id
        } else {
            await engine.selectSubtitleTrack(index: -1)
            selectedSubtitleTrackIndex = nil
        }
        snapshotTextTracks("right after select")
        // Verification later — libvlc applies ES changes asynchronously via the
        // input control queue; state 600ms later tells whether it STUCK.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.snapshotTextTracks("verify +600ms")
        }
    }

    /// Diagnostic: dump VLC's real text-track state (selected flags) — the UI's
    /// `selectedSubtitleTrackIndex` only records our INTENT, not VLC's truth.
    func snapshotTextTracks(_ tag: String) {
        let snap = engine.vlcMediaPlayer().textTracks.enumerated().map { idx, t in
            let name = t.trackName ?? t.trackId
            return "[\(idx)] \(name) fourcc=\(Self.fourccString(t.fourcc)) sel=\(t.isSelected)"
        }.joined(separator: " | ")
        TJFLog("subState[\(tag)] \(snap.isEmpty ? "NONE" : snap)")
    }

    private static func fourccString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }

    func loadExternalSubtitle(url: URL) async {
        await engine.loadExternalSubtitle(url: url)
        await loadTracks()
    }

    // MARK: - Timer

    func startUpdating() {
        // A PiP handoff race (start vs resume) must never stack timers —
        // a leaked timer keeps reporting stale progress forever.
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isSeeking else { return }
                self.currentTime = await self.engine.currentTime
                self.duration = await self.engine.duration
                self.isPlaying = await self.engine.isPlaying

                // Native video aspect (diagnostics)
                let vs = self.engine.videoSize
                if vs.width > 0, vs.height > 0 {
                    let aspect = vs.width / vs.height
                    if abs(aspect - (self.videoAspect ?? 0)) > 0.001 {
                        let voutJustReady = self.videoAspect == nil
                        self.videoAspect = aspect
                        TJFLog("videoAspect=\(aspect) videoSize=\(vs.width)x\(vs.height)")
                        // vout just created — re-apply fit/fill; this VLCKit
                        // alpha can drop videoFitMode across vout setup.
                        if voutJustReady {
                            await self.engine.setVideoFill(self.isFill)
                        }
                    }
                } else if self.videoAspect == nil && self.timerTickCount <= 6 {
                    TJFLog("videoAspect PENDING videoSize=\(vs.width)x\(vs.height)")
                }

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

                // Skip segments: fetch markers once, then evaluate every tick
                await self.loadSegmentsIfNeeded()
                self.evaluateSkipState(delta: 0.5)
            }
        }
    }

    func stopUpdating() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Skip Segments

    /// Fetches skip markers once per playback session. Network/plugin failures
    /// degrade silently after a couple of attempts — the player works normally.
    private func loadSegmentsIfNeeded() async {
        guard !segmentsLoaded else { return }
        guard reportingConfigured, let serverURL, let token, let userId, let itemId else { return }
        segmentsLoadAttempts += 1
        do {
            let markers = try await segmentClient.fetchSegments(
                serverURL: serverURL,
                token: token,
                userId: userId,
                itemId: itemId
            )
            segmentMarkers = markers
            segmentsLoaded = true
        } catch {
            TJFLog("segments fetch error attempt=\(segmentsLoadAttempts): \(error)")
            if segmentsLoadAttempts >= 3 {
                segmentsLoaded = true // give up quietly
            }
        }
    }

    private func evaluateSkipState(delta: Double) {
        guard !skipInProgress else { return }
        // Freeze countdown while paused or seeking — only advance during playback.
        let effectiveDelta = (isPlaying && !isSeeking) ? delta : 0
        let settings = SkipSettings.current()
        let outcome = segmentDetector.tick(
            time: currentTime,
            delta: effectiveDelta,
            markers: segmentMarkers,
            settings: settings
        )
        switch outcome {
        case .none:
            activeSegment = nil
            segmentCountdown = nil
        case .show(let marker, let countdown):
            activeSegment = marker
            segmentCountdown = countdown
        case .triggerSkip(let marker):
            activeSegment = marker
            segmentCountdown = nil
            segmentDetector.markSkipped(marker)
            Task { await performSkip(marker) }
        }
    }

    /// Skip action for the overlay button: jump to the end of the segment.
    func skipActiveSegment() {
        guard let marker = activeSegment, !skipInProgress else { return }
        segmentDetector.markSkipped(marker)
        Task { await performSkip(marker) }
    }

    /// Ending segment: offer/trigger next episode playback.
    func playNextEpisode() {
        guard activeSegment?.type == .credits else { return }
        onPlayNextEpisode?()
    }

    private func performSkip(_ marker: SegmentMarker) async {
        skipInProgress = true
        defer {
            skipInProgress = false
            activeSegment = nil
            segmentCountdown = nil
        }
        let target: Double
        if let end = marker.end {
            target = end
        } else {
            // Chapter-derived marker running to video end: skip to the very end.
            target = max(0, duration - 0.5)
        }
        guard target > currentTime else { return }
        TJFLog("skip \(marker.type.rawValue) → \(Int(target))s")
        await seek(to: target)
    }

    // MARK: - Private

    private func loadTracks() async {
        availableAudioTracks = await engine.availableAudioTracks
        availableSubtitleTracks = await engine.availableSubtitleTracks

        TJFLog("loadTracks audio=\(availableAudioTracks.count) subs=\(availableSubtitleTracks.count)")
        snapshotTextTracks("loadTracks")

        await addExternalSubtitlesIfNeeded()

        await applyLanguagePreferences()
    }

    /// Apply profile language preferences once per item, only when the user
    /// hasn't manually picked a track yet. No match → leave VLC's default.
    private func applyLanguagePreferences() async {
        let prefs = LanguagePreferences.current()

        if selectedAudioTrackIndex == nil,
           let audio = LanguagePreferences.selectTrack(
               in: availableAudioTracks,
               preferred: prefs.preferredAudio,
               language: { $0.language }
           ) {
            TJFLog("langPref audio -> id=\(audio.id) lang=\(audio.language ?? "-")")
            await engine.selectAudioTrack(index: audio.id)
            selectedAudioTrackIndex = audio.id
        }

        if selectedSubtitleTrackIndex == nil,
           let sub = LanguagePreferences.selectTrack(
               in: availableSubtitleTracks,
               preferred: prefs.preferredSubtitles,
               language: { $0.language }
           ) {
            TJFLog("langPref subtitles -> id=\(sub.id) lang=\(sub.language ?? "-")")
            await engine.selectSubtitleTrack(index: sub.id)
            selectedSubtitleTrackIndex = sub.id
        }
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
        reportProgress(at: currentTime)
    }

    private func reportProgress(at position: Double) {
        guard let userId, let serverURL, let token, let itemId else {
            TJFLog("reportProgress SKIPPED: userId=\(userId != nil) serverURL=\(serverURL != nil) token=\(token != nil) itemId=\(itemId != nil)")
            return
        }
        let ticks = Int64(position * 10_000_000) // 1 tick = 100ns
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
    /// - Parameter reportStop: false when playback continues in the floating
    ///   PiP window — the session keeps reporting progress on its own.
    func stopSync(reportStop: Bool = true) {
        if reportStop && !pipSessionReportedStop {
            reportStopped()
        }
        engine.stopSync()
        stopUpdating()
        engineStopped = true
    }

    /// Detach the drawable so VLC's render thread stops accessing the view.
    func detachDrawable() {
        engine.vlcMediaPlayer().drawable = nil
    }

    func vlcMediaPlayer() -> VLCMediaPlayer {
        engine.vlcMediaPlayer()
    }

    /// Diagnostic: SwiftUI calls updateNSView/updateUIView on every re-render
    /// (timer ticks!) — setDrawable has NO same-value guard in VLCKit, so churn
    /// here restarts the vout on some platforms. Count it.
    private static var drawableAttachCount = 0

    #if os(macOS)
    func attachDrawable(_ view: Any) {
        Self.drawableAttachCount += 1
        if Self.drawableAttachCount <= 5 || Self.drawableAttachCount % 100 == 0 {
            TJFLog("attachDrawable #\(Self.drawableAttachCount)")
        }
        engine.vlcMediaPlayer().drawable = view
    }
    #elseif os(iOS)
    func attachDrawable(_ view: UIView) {
        Self.drawableAttachCount += 1
        if Self.drawableAttachCount <= 5 || Self.drawableAttachCount % 100 == 0 {
            TJFLog("attachDrawable #\(Self.drawableAttachCount)")
        }
        engine.vlcMediaPlayer().drawable = view
    }
    #endif

    // MARK: - Picture in Picture (iOS)

    /// True while playback continues in the floating PiP window — the
    /// fullscreen view must NOT stop the play session when it disappears.
    var isPiPPlaybackContinuing: Bool {
        #if os(iOS)
        return pipState == .active
        #else
        return false
        #endif
    }

    #if os(iOS)
    enum PipState { case idle, active }

    /// Handoff state for this player instance.
    private(set) var pipState: PipState = .idle
    /// True when the server offered an HLS playlist — PiP can start.
    private(set) var pipAvailable = false
    /// HLS playlist played by the floating AVPlayer.
    private var hlsURL: URL?
    /// PlayerView sets this so a user-closed PiP window dismisses fullscreen UI.
    var onPiPClosed: (() -> Void)?

    /// Prefetch the HLS playlist needed for PiP. Non-blocking — called on
    /// appear so the handoff is instant when the app backgrounds.
    func resolvePipSupport() {
        guard hlsURL == nil, !pipAvailable,
              reportingConfigured, let itemId, let serverURL, let token, let userId
        else { return }
        Task {
            let resolved = await HlsStreamResolver().resolveHlsURL(
                userId: userId, serverURL: serverURL, token: token, itemId: itemId
            )
            hlsURL = resolved
            pipAvailable = resolved != nil
            TJFLog("pip: hls available=\(resolved != nil)")
        }
    }

    /// Hand playback over to the floating PiP window — automatically on
    /// background, or manually via the controls button. On failure falls back
    /// to VLC background audio (playback keeps running without a window).
    func startPictureInPicture() async {
        guard pipState == .idle, let hlsURL, reportingConfigured,
              let itemId, let serverURL, let token, let userId
        else { return }
        // Only hand off while something is actually playing.
        guard isPlaying || (currentTime > 0 && (duration <= 0 || currentTime < duration)) else {
            TJFLog("pip: skipped — not playing")
            return
        }
        // Another player instance already owns the floating window.
        guard !PipSession.shared.isActive else { return }

        let position = currentTime
        TJFLog("pip: handoff from VLC at \(String(format: "%.1f", position))s")

        reportProgress(at: position)
        stopUpdating()
        await engine.pause()
        isPlaying = false

        pipState = .active

        let context = PipSession.Context(
            itemId: itemId, serverURL: serverURL, token: token,
            userId: userId, playSessionId: reportingSessionId
        )
        let started = await PipSession.shared.start(
            hlsURL: hlsURL, position: position, context: context
        )

        if started {
            // Wire callbacks only for the session this instance owns — a
            // later player instance must not inherit them.
            wirePipCallbacks(itemId: itemId)
        } else {
            TJFLog("pip: start failed → resuming VLC (background audio fallback)")
            // A concurrent resume (rapid background→foreground) may already
            // have taken playback back — only the owner recovers here.
            if pipState == .active {
                pipState = .idle
                await engine.play()
                isPlaying = true
                startUpdating()
            }
        }
    }

    /// Take playback back from the floating window — user tapped the PiP
    /// window, or the app returned to foreground. Re-prepares VLC when the
    /// view was torn down while floating, otherwise seeks the loaded media.
    func resumeFromPictureInPicture() async {
        guard pipState == .active else { return }
        pipState = .idle

        // Returns the last tracked position even when the session already
        // cleaned up (didStop racing the restore callback).
        let position = PipSession.shared.stop()
        TJFLog("pip: resume from \(String(format: "%.1f", position))s")

        guard let streamURL = currentStreamURL else {
            startUpdating()
            return
        }

        if engineStopped {
            // View disappeared while floating — full re-prepare at position.
            await prepareStream(url: streamURL, startPosition: position > 0 ? position : nil)
            await engine.play()
            isPlaying = true
            if position > 0 { await verifyResume(at: position) }
        } else {
            // Media still loaded (just paused) — seek to the PiP position.
            if position > 0 { await seek(to: position) }
            await engine.play()
            isPlaying = true
        }
        startUpdating()
    }

    private func wirePipCallbacks(itemId: String) {
        PipSession.shared.onRestore = { [weak self] position in
            guard let self, self.itemId == itemId else { return false }
            Task { await self.resumeFromPictureInPicture() }
            return true
        }
        PipSession.shared.onClosed = { [weak self] in
            guard let self else { return }
            TJFLog("pip: closed by user — dismissing fullscreen")
            // Session already reported playback stopped to the server.
            self.pipSessionReportedStop = true
            self.pipState = .idle
            self.stopUpdating()
            self.onPiPClosed?()
        }
    }
    #endif
}
