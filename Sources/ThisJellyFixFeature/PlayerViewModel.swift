import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking
import ThisJellyFixPlayback

@MainActor
@Observable
final class PlayerViewModel {
    // MARK: - Playback State
    var isPlaying = false
    /// True while playback is stopped **because the user asked for it**
    /// (play/pause control) — the auto-PiP gate must not float a pause away.
    var userPaused = false
    /// Whether an automatic PiP handoff (view exit / background) may run.
    var canAutoHandoffToPiP: Bool {
        // The rule lives in Core (`PiPHandoffPolicy`) so it is unit-tested.
        PiPHandoffPolicy.canAutoStart(
            isPlaying: isPlaying,
            userPaused: userPaused,
            position: currentTime,
            duration: duration,
            engineStopped: engineStopped,
            hasError: errorMessage != nil
        )
    }
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var isSeeking = false
    /// Target of a seek requested while another one is still in flight — the
    /// running pass hands over to it instead of stacking concurrent position sets.
    var pendingSeekTarget: Double?

    // MARK: - Tracks
    var availableAudioTracks: [AudioTrack] = []
    var availableSubtitleTracks: [SubtitleTrack] = []
    var selectedAudioTrackIndex: Int?
    var selectedSubtitleTrackIndex: Int?
    /// True once the user manually picked a subtitle track (or turned them
    /// off): preference auto-selection must not override that choice later.
    var subtitleSelectionLocked = false
    /// Number of embedded (AVMediaSelection) subtitle tracks — ids from
    /// `embeddedSubtitleCount` up are external client-composed tracks.
    private var embeddedSubtitleCount = 0
    /// External SRT tracks appended after the embedded ones, with their cues.
    private var externalSubs: [(track: SubtitleTrack, cues: [SubtitleCue])] = []
    /// Index into `externalSubs` when an external track is selected.
    private var selectedExternalSubIndex: Int?
    /// Text for the SwiftUI subtitle overlay — only for EXTERNAL tracks.
    /// Embedded subs are rendered natively by AVPlayerLayer.
    var subtitleText: String?

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
    /// true while a next-episode swap is loading — the view covers the loading
    /// gap with an in-player indicator instead of dropping back out.
    var isSwitchingEpisode = false

    private var segmentDetector = SegmentDetector()
    private var segmentMarkers: [SegmentMarker] = []
    private var segmentClient: any JellyfinSegmentProviding
    private var segmentsLoaded = false
    private var segmentsLoadAttempts = 0
    private var skipInProgress = false

    // MARK: - Dependencies
    /// The one and only engine — the view hosts `engine.playerLayer` and the
    /// PiP coordinator hands the same layer to the system window.
    let engine: AVPlaybackEngine
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

    // MARK: - Lock screen (Now Playing)
    private var nowPlayingActive = false
    private var nowPlayingSession: Int?

    init(
        engine: AVPlaybackEngine = AVPlaybackEngine(),
        segmentClient: any JellyfinSegmentProviding = JellyfinSegmentClient()
    ) {
        self.engine = engine
        self.segmentClient = segmentClient
        // Real state machine: .failed surfaces a message, .ended is the true
        // end-of-media signal (the `duration - 1.5` guess is gone).
        engine.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleEngineState(state)
            }
        }
        // Lock-screen / headphone remote commands → the same VM entry points.
        let np = NowPlayingController.shared
        np.onPlay = { [weak self] in
            guard let self, !self.isPlaying else { return }
            Task { await self.togglePlayPause() }
        }
        np.onPause = { [weak self] in
            guard let self, self.isPlaying else { return }
            Task { await self.togglePlayPause() }
        }
        np.onTogglePlayPause = { [weak self] in
            Task { await self?.togglePlayPause() }
        }
        np.onSkipBackward = { [weak self] in
            Task { await self?.seekRelative(-15) }
        }
        np.onSkipForward = { [weak self] in
            Task { await self?.seekRelative(15) }
        }
        np.onSeek = { [weak self] position in
            Task { await self?.seek(to: position) }
        }
    }

    /// Lock screen / Control Center: publish what's playing (title + poster).
    /// Called once when the player mounts; the timer keeps time/rate fresh.
    func configureNowPlaying(title: String) {
        guard !nowPlayingActive else { return }
        nowPlayingActive = true
        nowPlayingSession = NowPlayingController.shared.activate(title: title, duration: duration)
        if let serverURL, let itemId {
            let artwork = URL(string: "\(serverURL.absoluteString)/Items/\(itemId)/Images/Primary?maxWidth=400&quality=90")
            NowPlayingController.shared.setArtworkURL(artwork)
        }
    }

    private func handleEngineState(_ state: PlaybackEngineState) {
        switch state {
        case .failed(let message):
            TJFLog("engine FAILED item=\(itemId ?? "nil"): \(message)")
            isPlaying = false
            if errorMessage == nil {
                errorMessage = message
            }
        case .ended:
            // Natural end — credits/next-episode UI keep showing, no error.
            TJFLog("engine ENDED item=\(itemId ?? "nil")")
            isPlaying = false
        case .buffering, .loading, .ready, .playing, .paused, .idle:
            break
        }
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
    /// that don't exist inside the container AVPlayer parses.
    func configureMediaStreams(_ streams: [MediaStream]) {
        serverMediaStreams = streams
        TJFLog("configureMediaStreams total=\(streams.count) extSubs=\(streams.filter { $0.type == "Subtitle" && $0.isExternal == true }.count)")
    }

    // MARK: - Playback Control

    /// Stream URL of the current playback — the PiP context carries it so the
    /// root view can rebuild the fullscreen player after a floating window.
    private var currentStreamURL: URL?
    /// True once the engine has been stopped (view disappeared).
    private var engineStopped = false
    /// A stop report was already sent for this item — teardown must not
    /// send a second, stale one (float→close→exit chains).
    private var stopReported = false
    /// Resume target not yet reached. Progress/stop reports never send a
    /// lower position while it is pending, so exiting before the resume seek
    /// lands cannot overwrite the server's saved resume point with 0.
    private var pendingResumePosition: Double?
    /// Last time a seek landed — used to tell "user scrubbed here on purpose"
    /// from "playback drifted into an auto-skippable segment".
    private var lastSeekAt: Date?
    /// Display title — carried into the PiP context for restore.
    var playbackTitle: String = ""

    func prepareStream(url: URL, startPosition: Double? = nil) async {
        do {
            // Fresh attempt: a stale error must not block the exit handoff later.
            errorMessage = nil
            #if os(iOS)
            // A floating session must not keep playing (and reporting) over a
            // new fullscreen playback — one live session at a time.
            PipCoordinator.shared.closeFloating()
            PipCoordinator.shared.configure(engine: engine)
            #endif
            // Track the resume target from here so reports can never fall
            // below it until the post-play seek actually lands.
            pendingResumePosition = (startPosition ?? 0) > 0 ? startPosition : nil
            let request = PlaybackRequest(itemID: itemId ?? "", streamURL: url, startTime: startPosition)
            try await engine.prepare(request)
            // The view can vanish mid-prepare (task cancelled in onDisappear):
            // re-arming `engineStopped = false` here would let a zombie
            // continuation play audio on a player nobody can see.
            guard !Task.isCancelled else { return }
            currentStreamURL = url
            engineStopped = false
            stopReported = false
            // Apply the persisted fit/fill mode natively so subtitles stay
            // inside the visible region from the start.
            engine.setVideoFill(isFill)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayPause() async {
        // Zombie guard: playback work that outlived the player (dismissal
        // during the post-prepare delay) must not restart audio.
        guard !engineStopped else { return }
        if isPlaying {
            engine.pause()
            userPaused = true
        } else {
            engine.play()
            userPaused = false
            // The user resumed in THIS mount: reporting is live again, so a
            // later exit may report its stop (a stale flag from a closed
            // floating window would block it).
            stopReported = false
        }
        isPlaying.toggle()
    }

    // MARK: - Episode Switching

    /// Swap to another episode WITHOUT tearing the player down.
    ///
    /// Forgets every per-item state, then feeds the new stream to the same
    /// AVPlayer (replaceCurrentItem keeps the layer and PiP wiring intact).
    func switchToEpisode(
        url: URL,
        startPosition: Double?,
        itemId: String?,
        serverURL: URL?,
        token: String?,
        userId: String?,
        playSessionId: String?,
        mediaStreams: [MediaStream]
    ) async {
        isSwitchingEpisode = true
        defer { isSwitchingEpisode = false }

        endCurrentItemSession()
        resetItemState()

        if let itemId, let serverURL, let token, let userId {
            configureReporting(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, playSessionId: playSessionId
            )
        } else {
            reportingConfigured = false
        }
        configureMediaStreams(mediaStreams)

        engine.stop()
        // Dismissed mid-swap: the task is cancelled in onDisappear, and a
        // zombie continuation would call play() + startUpdating() on a view
        // that is already gone.
        guard !Task.isCancelled, !engineStopped else { return }

        await prepareStream(url: url, startPosition: startPosition)
        guard !Task.isCancelled else { return }
        engine.play()
        guard !Task.isCancelled else { return }
        isPlaying = true
        userPaused = false
        startUpdating()
        if let startPosition, startPosition > 0 {
            await seek(to: startPosition)
        }
    }

    /// Close out the previous item's Jellyfin session so the next episode
    /// starts a fresh one.
    private func endCurrentItemSession() {
        guard reportingConfigured else { return }
        #if os(iOS)
        if PipCoordinator.shared.isFloating {
            // The floating window owns the session — closing it reports the
            // stop itself. Programmatic close: no closed handlers fire.
            PipCoordinator.shared.closeFloating()
            return
        }
        #endif
        if !stopReported {
            reportStopped()
        }
    }

    /// Forget everything that belongs to the previous item.
    private func resetItemState() {
        availableAudioTracks = []
        availableSubtitleTracks = []
        selectedAudioTrackIndex = nil
        selectedSubtitleTrackIndex = nil
        subtitleSelectionLocked = false
        embeddedSubtitleCount = 0
        externalSubs = []
        selectedExternalSubIndex = nil
        subtitleText = nil
        showAudioPicker = false
        showSubtitlePicker = false
        showSpeedPicker = false

        errorMessage = nil
        isSeeking = false
        currentTime = 0
        duration = 0
        playbackRate = 1.0
        // nil → the timer re-reads the new item's size.
        videoAspect = nil

        segmentDetector.reset()
        segmentMarkers = []
        segmentsLoaded = false
        segmentsLoadAttempts = 0
        skipInProgress = false
        activeSegment = nil
        segmentCountdown = nil

        tracksLoaded = false
        trackLoadAttempts = 0
        timerTickCount = 0
        externalSubsLoaded = false

        hasReportedPlaying = false
        lastProgressReport = nil
        engineStopped = false
        stopReported = false
        pendingResumePosition = nil
        lastSeekAt = nil
    }

    func seek(to seconds: Double) async {
        // Zombie guard — a dismissed player must not keep positioning.
        guard !engineStopped else { return }
        // Coalesce overlapping triggers (scrub release + auto-skip, double tap
        // ±15s, swipe while scrubbing).
        if isSeeking {
            pendingSeekTarget = seconds
            return
        }
        isSeeking = true
        var target = seconds
        while true {
            pendingSeekTarget = nil
            await performSeek(to: target)
            guard let next = pendingSeekTarget else { break }
            target = next
        }
        isSeeking = false
    }

    /// One seek pass: AVPlayer seeks are precise (zero tolerance) and the
    /// engine awaits the completion handler, so this only verifies the landing
    /// and clears the resume pin.
    private func performSeek(to seconds: Double) async {
        currentTime = seconds
        await engine.seek(to: seconds)
        guard !engineStopped else { return }

        let actual = engine.currentTime
        if abs(actual - seconds) <= 2.0 {
            // Landed — from here the real playback time is authoritative.
            pendingResumePosition = nil
        } else {
            TJFLog("seek: landed at \(String(format: "%.1f", actual))s (target \(String(format: "%.1f", seconds))s)")
        }
        lastSeekAt = Date()
        currentTime = actual
        // The timer skips subtitle updates while isSeeking — without this the
        // overlay kept the PRE-seek cue until the next 0.5s tick (subs lagging
        // after skipping the opening).
        updateSubtitleText()
    }

    func seekRelative(_ delta: Double) async {
        let target = max(0, min(currentTime + delta, duration))
        await seek(to: target)
    }

    func setPlaybackRate(_ rate: Float) async {
        engine.setPlaybackRate(rate)
        playbackRate = rate
    }

    /// Switch between fill (cover screen) and fit (whole video) modes.
    /// Applied to the AVPlayerLayer's videoGravity so subtitles follow the
    /// visible region.
    func setFill(_ fill: Bool) {
        guard fill != isFill else { return }
        isFill = fill
        engine.setVideoFill(fill)
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
        // Manual choice — including explicit "Desactivados" — wins over the
        // stored preference for the rest of this item.
        subtitleSelectionLocked = true
        await applySubtitleSelection(track)
    }

    /// Select an embedded (AVMediaSelection) or external (client-composed)
    /// subtitle track. nil = off.
    private func applySubtitleSelection(_ track: SubtitleTrack?) async {
        guard let track else {
            await engine.selectSubtitleTrack(index: -1)
            selectedExternalSubIndex = nil
            selectedSubtitleTrackIndex = nil
            subtitleText = nil
            return
        }
        if track.id >= embeddedSubtitleCount {
            // External: turn embedded OFF and show cues in our overlay.
            await engine.selectSubtitleTrack(index: -1)
            selectedExternalSubIndex = track.id - embeddedSubtitleCount
            selectedSubtitleTrackIndex = track.id
        } else {
            // Embedded: AVPlayer renders it natively inside the layer.
            await engine.selectSubtitleTrack(index: track.id)
            selectedExternalSubIndex = nil
            selectedSubtitleTrackIndex = track.id
        }
        updateSubtitleText()
        TJFLog("subtitles select id=\(track.id) external=\(track.isExternal)")
    }

    /// Cue lookup for the overlay — called on every timer tick.
    private func updateSubtitleText() {
        guard let idx = selectedExternalSubIndex, idx < externalSubs.count else {
            subtitleText = nil
            return
        }
        subtitleText = SRTParser.cue(at: currentTime, in: externalSubs[idx].cues)?.text
    }

    // MARK: - Timer

    func startUpdating() {
        // Handoff races must never stack timers — a leaked timer keeps
        // reporting stale progress forever.
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isSeeking {
                    // A seek holds `currentTime` at its target, but duration and
                    // play state don't depend on it — freezing the whole snapshot
                    // made the UI look hung for the entire seek window.
                    self.duration = self.engine.duration
                    self.isPlaying = self.engine.isPlaying
                } else {
                    self.currentTime = self.engine.currentTime
                    self.duration = self.engine.duration
                    self.isPlaying = self.engine.isPlaying
                    self.updateSubtitleText()
                }

                // Lock screen: elapsed/duration/rate refresh.
                NowPlayingController.shared.update(
                    time: self.currentTime,
                    duration: self.duration,
                    rate: self.isPlaying ? self.playbackRate : Float(0)
                )

                // Native video aspect (diagnostics + fit/fill logging)
                let vs = self.engine.videoSize
                if vs.width > 0, vs.height > 0 {
                    let aspect = vs.width / vs.height
                    if abs(aspect - (self.videoAspect ?? 0)) > 0.001 {
                        self.videoAspect = aspect
                        TJFLog("videoAspect=\(aspect) videoSize=\(vs.width)x\(vs.height)")
                    }
                } else if self.videoAspect == nil && self.timerTickCount <= 6 {
                    TJFLog("videoAspect PENDING videoSize=\(vs.width)x\(vs.height)")
                }

                // Diagnostic log (first 10 ticks only)
                self.timerTickCount += 1
                if self.timerTickCount <= 10 {
                    TJFLog("timer tick=\(self.timerTickCount) isPlaying=\(self.isPlaying) reportingConfigured=\(self.reportingConfigured) hasReported=\(self.hasReportedPlaying) time=\(self.currentTime) dur=\(self.duration)")
                }

                #if os(iOS)
                // Keep the system auto-start gate in sync with the policy:
                // a user-paused player must not float away on background.
                PipCoordinator.shared.setAutoStartEnabled(self.canAutoHandoffToPiP)
                #endif

                // Determine if playback is active — time advancement as fallback.
                let playbackActive = self.isPlaying || (self.currentTime > 0 && self.currentTime < self.duration)

                // Report "playing" once when playback starts.
                if self.reportingConfigured, playbackActive, !self.hasReportedPlaying {
                    self.hasReportedPlaying = true
                    self.reportPlayStarted()
                }

                // Report progress every 10 seconds.
                if self.reportingConfigured {
                    if playbackActive, let last = self.lastProgressReport,
                       Date().timeIntervalSince(last) >= 10 {
                        self.reportProgress()
                    } else if self.lastProgressReport == nil, self.currentTime > 0 {
                        self.reportProgress()
                    }
                }

                // Tracks are loaded during prepare (AVFoundation loads media
                // selection groups eagerly) — retry a few ticks only for HLS
                // playlists whose groups land later.
                if !self.tracksLoaded {
                    self.trackLoadAttempts += 1
                    if self.trackLoadAttempts <= 10 {
                        await self.loadTracks()
                    } else {
                        self.tracksLoaded = true
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
            // Scrubbing INTO a segment is deliberate: offer the skip button
            // instead of hijacking playback a few seconds later.
            if lastSeekAt.map({ Date().timeIntervalSince($0) > 8 }) ?? true {
                Task { await performSkip(marker) }
            }
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
        let embedded = await engine.availableSubtitleTracks
        availableAudioTracks = displayAudio(await engine.availableAudioTracks)
        embeddedSubtitleCount = embedded.count
        availableSubtitleTracks = displaySubtitles(embedded) + displayExternalSubs()

        TJFLog("loadTracks audio=\(availableAudioTracks.count) subs=\(availableSubtitleTracks.count) embedded=\(embedded.count) ext=\(externalSubs.count) attempt=\(trackLoadAttempts)")

        if !availableAudioTracks.isEmpty || !embedded.isEmpty {
            tracksLoaded = true
        }

        await addExternalSubtitlesIfNeeded()
        await applyLanguagePreferences()
    }

    // MARK: - Track display names

    /// Enrich engine-reported audio tracks with server metadata so the
    /// picker shows "Inglés" instead of "Track 1". Selection ids and the
    /// raw ISO `language` (preference matching) stay untouched.
    private func displayAudio(_ tracks: [AudioTrack]) -> [AudioTrack] {
        let matched = pairServerStreams(to: tracks, server: serverStreams(type: "Audio")) { $0.language }

        return tracks.enumerated().map { i, track in
            let stream = matched[i]
            let display = TrackNaming.display(
                rawName: track.name,
                languageCode: stream?.language ?? track.language,
                serverTitle: stream?.displayTitle ?? stream?.title,
                index: i,
                fallbackPrefix: "Audio"
            )
            return AudioTrack(
                id: track.id,
                name: display.title,
                language: track.language ?? stream?.language,
                languageName: display.caption
            )
        }
    }

    /// Enrich embedded subtitle tracks with server metadata.
    private func displaySubtitles(_ tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let matched = pairServerStreams(
            to: tracks,
            server: serverStreams(type: "Subtitle").filter { $0.isExternal != true }
        ) { $0.language }

        return tracks.enumerated().map { i, track in
            let stream = matched[i]
            let display = TrackNaming.display(
                rawName: track.name,
                languageCode: stream?.language ?? track.language,
                serverTitle: stream?.displayTitle ?? stream?.title,
                index: i
            )
            return SubtitleTrack(
                id: track.id,
                name: display.title,
                language: track.language ?? stream?.language,
                languageName: display.caption,
                isExternal: false
            )
        }
    }

    /// External tracks get sequential ids after the embedded ones (the id
    /// space is what the selection mapping splits on).
    private func displayExternalSubs() -> [SubtitleTrack] {
        externalSubs.enumerated().map { i, entry in
            SubtitleTrack(
                id: embeddedSubtitleCount + i,
                name: entry.track.name,
                language: entry.track.language,
                languageName: entry.track.languageName,
                isExternal: true
            )
        }
    }

    /// Server streams of one type in embedding order: embedded tracks
    /// (container/index order) first, external files after.
    private func serverStreams(type: String) -> [MediaStream] {
        let streams = serverMediaStreams.filter { $0.type == type }
        let embedded = streams.filter { $0.isExternal != true }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        let external = streams.filter { $0.isExternal == true }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        return embedded + external
    }

    /// Pair each engine track with its server stream: exact position when the
    /// counts agree, otherwise by language first and position for the rest.
    /// Result may contain nils (display-only fallback → "Subtítulo N"/"Audio N").
    private func pairServerStreams<T>(
        to tracks: [T],
        server: [MediaStream],
        language: (T) -> String?
    ) -> [MediaStream?] {
        if server.count == tracks.count { return server }

        var result = [MediaStream?](repeating: nil, count: tracks.count)
        var used = Set<Int>()

        // Language match first (engine and server usually agree on ISO codes).
        var byLanguage: [String: [Int]] = [:]
        for (j, stream) in server.enumerated() {
            if let code = stream.language?.lowercased() {
                byLanguage[code, default: []].append(j)
            }
        }
        for (i, track) in tracks.enumerated() {
            guard let code = language(track)?.lowercased(),
                  let candidates = byLanguage[code],
                  let j = candidates.first(where: { !used.contains($0) }) else { continue }
            result[i] = server[j]
            used.insert(j)
        }

        // Leftovers by position — helps while external files are still
        // loading (counts transiently differ).
        let free = server.indices.filter { !used.contains($0) }
        var next = free.makeIterator()
        for i in result.indices where result[i] == nil {
            guard let j = next.next() else { break }
            result[i] = server[j]
            used.insert(j)
        }
        return result
    }

    /// Apply profile language preferences once per item, only when the user
    /// hasn't manually picked a track yet.
    private func applyLanguagePreferences() async {
        let prefs = LanguagePreferences.current()
        // Never configured (`nil`) → follow the system language.
        let preferredAudio = prefs.preferredAudio ?? LanguagePreferences.systemDefault
        let preferredSubtitles = prefs.preferredSubtitles ?? LanguagePreferences.systemDefault

        if selectedAudioTrackIndex == nil,
           let audio = LanguagePreferences.selectTrack(
               in: availableAudioTracks,
               preferred: preferredAudio,
               language: { $0.language }
           ) {
            TJFLog("langPref audio -> id=\(audio.id) lang=\(audio.language ?? "-")")
            await engine.selectAudioTrack(index: audio.id)
            selectedAudioTrackIndex = audio.id
        }

        if !subtitleSelectionLocked, selectedSubtitleTrackIndex == nil,
           let sub = LanguagePreferences.selectTrack(
               in: availableSubtitleTracks,
               preferred: preferredSubtitles,
               language: { $0.language }
           ) {
            TJFLog("langPref subtitles -> id=\(sub.id) lang=\(sub.language ?? "-")")
            await applySubtitleSelection(sub)
        }
    }

    /// Server-side external subtitle files (.srt next to the video) are NOT
    /// inside the container AVPlayer parses. Download them, parse locally and
    /// render through the SwiftUI overlay — the server converts any text
    /// format to SRT on request (`/Subtitles/{i}/Stream.srt`).
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
            // Always ask for SRT: the server converts ASS/SSA/VTT on the fly
            // and SRTParser only speaks SRT.
            let urlString = "\(serverURL.absoluteString)/Videos/\(itemId)/\(itemId)/Subtitles/\(idx)/Stream.srt?api_key=\(token)"
            guard let url = URL(string: urlString) else { continue }
            TJFLog("extSubs load idx=\(idx) codec=\(stream.codec ?? "-") lang=\(stream.language ?? "-") title=\(stream.title ?? "-")")
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    TJFLog("extSubs idx=\(idx) HTTP \(http.statusCode)")
                    continue
                }
                guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                else { continue }
                let cues = SRTParser.parse(text)
                guard !cues.isEmpty else {
                    TJFLog("extSubs idx=\(idx) parsed 0 cues — skipped")
                    continue
                }
                let track = SubtitleTrack(
                    id: -1, // assigned by displayExternalSubs()
                    name: stream.title ?? stream.displayTitle ?? "Subtítulo \(idx)",
                    language: stream.language,
                    languageName: nil,
                    isExternal: true
                )
                externalSubs.append((track: track, cues: cues))
                TJFLog("extSubs idx=\(idx) cues=\(cues.count)")
            } catch {
                TJFLog("extSubs idx=\(idx) failed: \(error)")
            }
        }
        // Rebuild the combined list (ids shift for external tracks) and let
        // preference auto-selection see them.
        if !externalSubs.isEmpty {
            availableSubtitleTracks = displaySubtitles(Array(availableSubtitleTracks.prefix(embeddedSubtitleCount))) + displayExternalSubs()
            await applyLanguagePreferences()
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
        // Never report below an unfulfilled resume target, and never report 0:
        // the server treats any reported position as authoritative and would
        // overwrite the saved resume point (seen in device logs).
        let effective = max(position, pendingResumePosition ?? 0)
        let ticks = Int64(effective * 10_000_000) // 1 tick = 100ns
        guard ticks > 0 else {
            TJFLog("reportProgress SKIPPED: position=0 (preserves saved resume)")
            return
        }
        lastProgressReport = Date()
        // Release the resume pin ONLY once real playback reached it.
        if let target = pendingResumePosition, position >= target - 2.0 {
            pendingResumePosition = nil
        }
        TJFLog("reportProgress itemId=\(itemId) ticks=\(ticks)")
        Task {
            await reporter.reportProgress(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, mediaSourceId: itemId,
                positionTicks: ticks, isPaused: !isPlaying
            )
        }
    }

    /// - Returns: true when a stop report was actually queued.
    @discardableResult
    private func reportStopped() -> Bool {
        guard let userId, let serverURL, let token, let itemId else {
            TJFLog("reportStopped SKIPPED: userId=\(userId != nil) serverURL=\(serverURL != nil) token=\(token != nil) itemId=\(itemId != nil)")
            return false
        }
        // Same rule as progress: an exit during a stalled open must not send
        // PositionTicks:0 — it wipes the server's saved resume position.
        let effective = max(currentTime, pendingResumePosition ?? 0)
        let ticks = Int64(effective * 10_000_000)
        guard ticks > 0 else {
            TJFLog("reportStopped SKIPPED: position=0 (preserves saved resume)")
            return false
        }
        TJFLog("reportStopped itemId=\(itemId) ticks=\(ticks)")
        Task {
            await reporter.reportStopped(
                userId: userId, serverURL: serverURL, token: token,
                itemId: itemId, mediaSourceId: itemId,
                positionTicks: ticks
            )
        }
        return true
    }

    func stop() async {
        reportStopped()
        stopReported = true
        engine.stop()
        stopUpdating()
    }

    /// Synchronous stop — call from onDisappear to guarantee the engine stops
    /// before the view is deallocated.
    /// - Parameter reportStop: false when playback continues in the floating
    ///   PiP window — this view model keeps reporting progress on its own.
    func stopSync(reportStop: Bool = true) {
        if reportStop && !stopReported {
            // Only latch when a stop was actually sent — reportStopped skips
            // the POST at position 0 (to preserve the saved resume), and that
            // case must not block a later, real stop.
            stopReported = reportStopped()
        }
        engine.stopSync()
        stopUpdating()
        engineStopped = true
        // Playback is over (not a PiP handoff — that never reaches stopSync):
        // clear the lock screen and stop answering remote commands.
        if nowPlayingActive {
            nowPlayingActive = false
            NowPlayingController.shared.deactivate(session: nowPlayingSession)
            nowPlayingSession = nil
        }
    }

    // MARK: - Picture in Picture (iOS)

    #if os(iOS)
    /// The system window is up (or starting).
    var isPipWindowActive: Bool { PipCoordinator.shared.isWindowActive }
    /// PlayerView sets this so a user-closed PiP window dismisses fullscreen UI.
    var onPiPClosed: (() -> Void)?

    /// Context for the root view to rebuild the fullscreen player while this
    /// VM floats. nil → float is refused (nothing to restore).
    func makePipContext() -> PipContext? {
        guard let itemId, let serverURL, let token, let userId,
              let streamURL = currentStreamURL
        else { return nil }
        return PipContext(
            itemId: itemId,
            serverURL: serverURL,
            token: token,
            userId: userId,
            playSessionId: reportingSessionId,
            streamURL: streamURL,
            title: playbackTitle,
            mediaStreams: serverMediaStreams
        )
    }

    /// Manual PiP start (controls button) / safety-net start.
    func startPictureInPicture() async -> Bool {
        guard !engineStopped else { return false }
        PipCoordinator.shared.configure(engine: engine)
        PipCoordinator.shared.start()
        return PipCoordinator.shared.isActive
    }

    /// Take playback back from the window (pip.exit button) — same player,
    /// no re-prepare: the window just closes and fullscreen keeps playing.
    func resumeFromPictureInPicture() async {
        guard PipCoordinator.shared.isWindowActive else { return }
        TJFLog("pip: exit button → closing window")
        PipCoordinator.shared.stop()
    }

    /// Wire this VM as the on-screen player for window-close events.
    func attachPipHandlers() {
        PipCoordinator.shared.liveVM = self
    }

    /// Unregister — the float path keeps ownership via `floatingVM`.
    func detachPipHandlers() {
        if PipCoordinator.shared.liveVM === self {
            PipCoordinator.shared.liveVM = nil
        }
    }
    #endif

    /// The fullscreen view disappeared. Playback must NOT die with it: hand
    /// the running item to the floating window when possible, otherwise stop.
    func handleViewExit(handoffAllowed: Bool = true) {
        #if os(iOS)
        if errorMessage != nil {
            // An error path tore this player down: a floating window over an
            // error screen keeps a broken session alive with nobody watching.
            TJFLog("pip: exit after error → stop with report, no handoff")
            stopSync(reportStop: true)
            return
        }
        if handoffAllowed, canAutoHandoffToPiP, reportingConfigured, itemId != nil,
           // The user CLOSED the floating window before: that ended playback.
           !stopReported
        {
            if PipCoordinator.shared.float(self) {
                TJFLog("pip: view exit → floating (reporting continues)")
                // onDisappear stopped the timer before us — the floating VM
                // must keep reporting progress.
                startUpdating()
                return
            }
            TJFLog("pip: float refused → stopping with report")
        }
        #endif
        stopSync(reportStop: true)
    }
}
