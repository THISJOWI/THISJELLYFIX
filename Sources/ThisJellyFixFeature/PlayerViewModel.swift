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
    /// True while playback is stopped **because the user asked for it**
    /// (play/pause control). VLCKit's `isPlaying` also reads false while it is
    /// buffering or just lying about it, so it cannot tell "paused on purpose"
    /// from "flaky read" — the automatic PiP handoff needs that distinction.
    var userPaused = false
    /// Whether an automatic PiP handoff (swipe-up / view exit) may run.
    ///
    /// `isPlaying` alone is not enough: the VLCKit lie silently skipped the
    /// swipe-up handoff for a item that WAS playing, while a plain
    /// position check would float away a player the user had paused.
    var canAutoHandoffToPiP: Bool {
        // The rule lives in Core (`PiPHandoffPolicy`) so it is unit-tested:
        // this gate decides both the swipe-up handoff and the exit handoff.
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
    /// Reset together with `selectedSubtitleTrackIndex` on every new item.
    var subtitleSelectionLocked = false

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
    /// true while a next-episode swap is loading — the view covers the black
    /// VLC gap with a "still in the player" indicator.
    var isSwitchingEpisode = false

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
        // E2: VLC reports errors ONLY through its (weak) delegate. Without
        // this the player would sit frozen on the spinner with no message.
        engine.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleEngineState(state)
            }
        }
    }

    /// E2: surface VLC state transitions — `.error` stops the timer UI and
    /// shows a user-visible message instead of an eternal spinner.
    private func handleEngineState(_ state: VLCMediaPlayerState) {
        switch state {
        case .error:
            // VLCKit exposes no "ended" state: a natural EndReached can arrive
            // as `.error`. When playback already reached the end, surfacing the
            // error overlay would cover the credits / next-episode UI of a
            // SUCCESSFUL playback — treat it as the natural end instead.
            if duration > 0, currentTime >= duration - 1.5 {
                TJFLog("VLC state=ERROR at end (\(Int(currentTime))/\(Int(duration))s) → natural end")
                isPlaying = false
                break
            }
            TJFLog("VLC state=ERROR item=\(itemId ?? "nil")")
            isPlaying = false
            if errorMessage == nil {
                errorMessage = "La reproducción ha fallado. Revisa la conexión con el servidor."
            }
        default:
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
    /// The HLS pipeline (transcode session) was already pre-flighted.
    private var pipWarmed = false
    /// Pre-loaded PiP pipeline (muted AVPlayer + layer) for the current item:
    /// loading it while the user still watches makes the handoff adopt a
    /// READY player, which is what opens the window instantly on swipe-up.
    private var pipPreload = PipPreload()
    /// A `startPictureInPicture()` call is between its guards and the system
    /// start — blocks a second concurrent caller (see the latch inside it).
    private var pipStartInFlight = false
    /// VLC is paused waiting for the floating window to take the audio. Only
    /// a frozen player may be un-paused by a failed handoff: the staged
    /// (windowless) path never froze anything, and "resuming" there would
    /// override a pause the user made while the start was pending.
    private var pipVLCFrozen = false
    /// Resume target not yet reached. Progress/stop reports never send a
    /// lower position while it is pending, so exiting before the resume seek
    /// lands cannot overwrite the server's saved resume point with 0.
    private var pendingResumePosition: Double?
    /// Last time a seek landed — used to tell "user scrubbed here on purpose"
    /// from "playback drifted into an auto-skippable segment".
    private var lastSeekAt: Date?

    func prepareStream(url: URL, startPosition: Double? = nil) async {
        do {
            // Fresh attempt: a stale error must not block the exit handoff later.
            errorMessage = nil
            // A floating PiP must not keep playing (and reporting) over a new
            // fullscreen playback — same item included: reopening the episode
            // that is currently floating produced TWO players and two live
            // Jellyfin sessions for it.
            #if os(iOS)
            if PipSession.shared.isActive {
                TJFLog("pip: closing active session item=\(PipSession.shared.activeItemId ?? "nil") for new playback item=\(itemId ?? "nil")")
                // Programmatic close: no closed handlers fire (they only run
                // for a USER close), so the observers can stay registered.
                PipSession.shared.closeAndReport()
            }
            #endif
            // Track the resume target from here so reports can never fall
            // below it until the post-play seek actually lands.
            pendingResumePosition = (startPosition ?? 0) > 0 ? startPosition : nil
            let request = PlaybackRequest(itemID: "", streamURL: url, startTime: startPosition)
            try await engine.prepare(request)
            // The view can vanish mid-prepare (task cancelled in onDisappear):
            // re-arming `engineStopped = false` here would let a zombie
            // continuation play audio on a player nobody can see.
            guard !Task.isCancelled else { return }
            currentStreamURL = url
            engineStopped = false
            pipSessionReportedStop = false
            pipWarmed = false
            // New stream → the old preloaded pipeline belongs to the previous
            // item (or the closed floating window): drop it.
            pipPreload.reset()
            // Apply the persisted fit/fill mode natively so VLC composes
            // subtitles within the visible region from the start.
            await engine.setVideoFill(isFill)
        } catch {
            errorMessage = error.localizedDescription
            // A failed prepare leaves the OLD pipeline state behind — the next
            // warm must actually run instead of no-op'ing on a stale flag.
            pipWarmed = false
            pipPreload.reset()
        }
    }

    func togglePlayPause() async {
        // Zombie guard: playback work that outlived the player (dismissal
        // during the post-prepare delay) must not restart audio.
        guard !engineStopped else { return }
        if isPlaying {
            await engine.pause()
            userPaused = true
        } else {
            await engine.play()
            userPaused = false
            // The user resumed in THIS mount: reporting is live again, so a
            // later exit may hand off and must be able to report its stop (a
            // stale flag from a closed floating window would block both).
            pipSessionReportedStop = false
        }
        isPlaying.toggle()
    }

    // MARK: - Episode Switching

    /// Swap to another episode WITHOUT tearing the player down.
    ///
    /// Closes the outgoing item's session, forgets every per-item state, then
    /// feeds the new stream to the same VLC instance (drawable stays attached).
    /// The view never unmounts, so there is no return to the episode list, no
    /// orientation flap and no re-attach of the video view.
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

        // Stop the outgoing media on the SAME VLC instance — only then is it
        // safe to swap `media` (the drawable stays attached, so the vout is
        // reused for the next episode instead of being rebuilt).
        await engine.stop()
        // Dismissed mid-swap: the task is cancelled in onDisappear, and a
        // zombie continuation would call play() + startUpdating() on a view
        // that is already gone.
        guard !Task.isCancelled, !engineStopped else { return }

        await prepareStream(url: url, startPosition: startPosition)
        guard !Task.isCancelled else { return }
        await engine.play()
        guard !Task.isCancelled else { return }
        isPlaying = true
        userPaused = false
        startUpdating()
        #if os(iOS)
        // The HLS playlist for PiP belongs to the previous item.
        resolvePipSupport()
        #endif
        if let startPosition, startPosition > 0 {
            await seek(to: startPosition)
        }
    }

    /// Close out the previous item's Jellyfin session so the next episode
    /// starts a fresh one (stop report for VLC, or the PiP window's own stop).
    private func endCurrentItemSession() {
        guard reportingConfigured else { return }
        #if os(iOS)
        if pipState == .active {
            // The floating window owns the session — closing it reports the
            // stop itself. The close is programmatic, so no closed handler
            // fires and the fullscreen player we are about to reuse survives.
            PipSession.shared.closeAndReport()
            pipState = .idle
            return
        }
        #endif
        if !pipSessionReportedStop {
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
        showAudioPicker = false
        showSubtitlePicker = false
        showSpeedPicker = false

        errorMessage = nil
        isSeeking = false
        currentTime = 0
        duration = 0
        playbackRate = 1.0
        // nil → the timer re-applies fit/fill when the new vout reports its size.
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
        pipSessionReportedStop = false
        pendingResumePosition = nil
        lastSeekAt = nil
        #if os(iOS)
        hlsURL = nil
        pipAvailable = false
        #endif
    }

    func seek(to seconds: Double) async {
        // Zombie guard — a dismissed player must not keep positioning VLC.
        guard !engineStopped else { return }
        // Coalesce overlapping triggers (scrub release + auto-skip, double tap
        // ±15s, swipe while scrubbing): each extra position set restarts VLC's
        // rebuffer from scratch. A later request only replaces the target.
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

    /// One seek pass: position the stream, then wait (without re-issuing) for
    /// VLC to actually land there.
    private func performSeek(to seconds: Double) async {
        currentTime = seconds
        // Use VLC's position setter — more reliable than time setter for all formats
        let vlcPlayer = engine.vlcMediaPlayer()

        // Position (0-1) needs the container length, which HLS/partial HTTP
        // streams report late. Waiting up to 10s froze every state update (the
        // timer bails while `isSeeking`) and then silently DROPPED the seek.
        var dur = engine.duration
        var waitedMs = 0
        while dur <= 0 && waitedMs < 1000 {
            try? await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
            dur = engine.duration
        }

        if dur > 0 {
            vlcPlayer.position = seconds / dur
        } else {
            // No length yet: fall back to a RELATIVE jump, which needs none.
            let delta = seconds - engine.currentTime
            TJFLog("seek: duration unknown after \(waitedMs)ms → jump \(Int(delta))s")
            await engine.seekRelative(delta)
        }

        // The player may have been dismissed while we waited for the duration.
        guard !engineStopped else { return }

        // Wait PATIENTLY for the seek to land — HTTP seeks take seconds — but
        // NEVER re-issue it. A blind retry while the first attempt is still
        // buffering restarts the rebuffer and roughly doubles the stall for any
        // seek slower than this timeout.
        var actual = engine.currentTime
        waitedMs = 0
        while abs(actual - seconds) > 2.0 && waitedMs < 5000 {
            try? await Task.sleep(for: .milliseconds(300))
            waitedMs += 300
            actual = engine.currentTime
        }
        if abs(actual - seconds) <= 2.0 {
            // Landed — from here the real playback time is authoritative.
            pendingResumePosition = nil
        }
        lastSeekAt = Date()
        currentTime = actual
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
        // Manual choice — including explicit "Desactivados" — wins over the
        // stored preference for the rest of this item.
        subtitleSelectionLocked = true
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
                if self.isSeeking {
                    // A seek holds `currentTime` at its target, but duration and
                    // play state don't depend on it — freezing the whole snapshot
                    // made the UI look hung for the entire seek window.
                    self.duration = await self.engine.duration
                    self.isPlaying = await self.engine.isPlaying
                } else {
                    self.currentTime = await self.engine.currentTime
                    self.duration = await self.engine.duration
                    self.isPlaying = await self.engine.isPlaying
                }

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
                    } else if self.trackLoadAttempts % 4 == 0,
                              !self.subtitleSelectionLocked,
                              self.selectedSubtitleTrackIndex == nil,
                              !self.availableSubtitleTracks.isEmpty {
                        // Counts unchanged but nothing selected yet: libvlc may
                        // have registered the ES asynchronously, or the matching
                        // track just became resolvable. Retry preference only.
                        await self.applyLanguagePreferences()
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
        availableAudioTracks = displayAudio(await engine.availableAudioTracks)
        availableSubtitleTracks = displaySubtitles(await engine.availableSubtitleTracks)

        TJFLog("loadTracks audio=\(availableAudioTracks.count) subs=\(availableSubtitleTracks.count)")
        snapshotTextTracks("loadTracks")

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

    /// Enrich engine-reported subtitle tracks with server metadata so the
    /// picker shows "Inglés / ToonsHub" instead of "Track 2". Selection ids
    /// and the raw ISO `language` (preference matching) stay untouched.
    private func displaySubtitles(_ tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let matched = pairServerStreams(to: tracks, server: serverStreams(type: "Subtitle")) { $0.language }

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
                // External .srt slaves and und-tagged streams carry no engine
                // language — fall back to the server's MediaStream, which does.
                language: track.language ?? stream?.language,
                languageName: display.caption,
                isExternal: track.isExternal
            )
        }
    }

    /// Server streams of one type in the order VLC reports them: embedded
    /// tracks (container/index order) first, external slaves (load order) after.
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

        // Language match first (VLC and server usually agree on ISO codes).
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

        // Leftovers by position — helps while external slaves are still
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
    /// hasn't manually picked a track yet. No match → leave VLC's default.
    private func applyLanguagePreferences() async {
        let prefs = LanguagePreferences.current()
        // Never configured (`nil`) → follow the system language. Preference
        // seeding lives behind the Profile screen, so most users reach playback
        // with no stored value and subtitles stayed off. Explicit "Sin
        // preferencia" stores `noPreference` ("") and is respected as-is.
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
        // Release the resume pin ONLY once real playback reached it: clearing
        // on the first tick would let an exit before the seek lands report ~1s
        // and wipe the saved 600s resume point (the pin exists exactly for
        // that). `performSeek` clears it when the seek lands; this covers a
        // seek that timed out but playback drifted there anyway.
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
        await engine.stop()
        stopUpdating()
    }

    /// Synchronous stop — call from onDisappear to ensure VLC stops before the view is deallocated.
    /// - Parameter reportStop: false when playback continues in the floating
    ///   PiP window — the session keeps reporting progress on its own.
    func stopSync(reportStop: Bool = true) {
        if reportStop && !pipSessionReportedStop {
            // Only latch when a stop was actually sent — reportStopped skips
            // the POST at position 0 (to preserve the saved resume), and that
            // case must not block a later, real stop.
            pipSessionReportedStop = reportStopped()
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
    #elseif os(iOS) || os(tvOS)
    func attachDrawable(_ view: UIView) {
        Self.drawableAttachCount += 1
        if Self.drawableAttachCount <= 5 || Self.drawableAttachCount % 100 == 0 {
            TJFLog("attachDrawable #\(Self.drawableAttachCount)")
        }
        engine.vlcMediaPlayer().drawable = view
    }
    #endif

    // MARK: - Picture in Picture (iOS)

    #if os(iOS)
    enum PipState { case idle, active }

    /// Handoff state for this player instance.
    private(set) var pipState: PipState = .idle
    /// True when the server offered an HLS playlist — PiP can start.
    private(set) var pipAvailable = false
    /// HLS playlist played by the floating AVPlayer.
    private var hlsURL: URL?
    /// An HLS prefetch is already in flight (deduplicates overlapping calls).
    private var pipResolving = false
    /// PlayerView sets this so a user-closed PiP window dismisses fullscreen UI.
    var onPiPClosed: (() -> Void)?
    /// Display title — carried into the PiP context so the root view can
    /// rebuild the fullscreen player when the original one is already gone.
    var playbackTitle: String = ""
    /// Set while the fullscreen view is disappearing and the handoff to the
    /// floating window is still in flight: VLC is released as soon as AVPlayer
    /// has the audio (and for good if the handoff fails).
    private var exitHandoffPending = false
    /// This view model's PipSession observers — removed when the view goes away.
    private var pipRestoreHandlerId: UUID?
    private var pipClosedHandlerId: UUID?

    /// Prefetch the HLS playlist needed for PiP. Non-blocking — called on
    /// appear so the handoff is instant when the app backgrounds. Re-called
    /// once playback is running: the mount-time attempt can come back empty,
    /// and an empty cache forces a cold resolve DURING backgrounding (the
    /// window then never has time to appear).
    func resolvePipSupport() {
        guard hlsURL == nil, !pipResolving else { return }
        pipResolving = true
        Task {
            _ = await self.resolvePipURL()
            self.pipResolving = false
        }
    }

    /// Resolve (and cache) the HLS playlist for the current item, or reuse
    /// the cached one.
    private func resolvePipURL() async -> URL? {
        if let hlsURL { return hlsURL }
        guard reportingConfigured, let itemId, let serverURL, let token, let userId else {
            return nil
        }
        // Pin the item: an episode swap can reset the cache while this request
        // is in flight, and the OLD playlist must never overwrite the new one
        // (PiP would then play the previous episode under the new item's context).
        let requestedItem = itemId
        let resolved = await HlsStreamResolver().resolveHlsURL(
            userId: userId, serverURL: serverURL, token: token, itemId: requestedItem
        )
        guard self.itemId == requestedItem, hlsURL == nil else {
            TJFLog("pip: discarding stale HLS resolve for item=\(requestedItem)")
            return hlsURL
        }
        hlsURL = resolved
        pipAvailable = resolved != nil
        TJFLog("pip: hls available=\(resolved != nil)")
        return resolved
    }

    /// Pre-flight the HLS pipeline when the user shows intent to leave
    /// (scenePhase → .inactive): fetching the playlists spins Jellyfin's
    /// transcoding session up, so the real handoff loads near-instantly.
    /// Fire-and-forget, once per playback.
    func warmPictureInPicture() async {
        guard !pipWarmed, pipState == .idle else { return }
        guard let url = await resolvePipURL() else { return }
        TJFLog("pip: warming HLS pipeline")
        // Preferred: load the real PiP pipeline NOW (muted AVPlayer), so the
        // handoff can adopt a ready player and open the window instantly.
        // Consider it warmed only when the load actually started — the old
        // flag was set BEFORE the HTTP fetch, so a failed warm froze the
        // session into "already warmed" and every later handoff stayed cold.
        if pipPreload.begin(url: url) {
            pipWarmed = true
            return
        }
        guard let token else { return }
        pipWarmed = await HlsStreamResolver().warmUp(hlsURL: url, token: token)
    }

    /// Stage the WHOLE PiP apparatus while the app is still active — called
    /// from scenePhase .inactive, the first half of leaving. The window is
    /// **not** opened here: iOS starts PiP itself at the background
    /// transition (`canStartPictureInPictureAutomaticallyFromInline`), and a
    /// manual start during a Control Centre / app-switcher peek would pop it
    /// over the video the user is still watching (documented regression),
    /// while a manual start issued AFTER the scene is backgrounded gets
    /// rejected on device (`failedToStart`, state=2).
    func preparePictureInPicture() async {
        guard pipState == .idle, !pipStartInFlight else { return }
        guard canAutoHandoffToPiP else { return }
        pipStartInFlight = true
        defer { pipStartInFlight = false }
        // A slow or failed prefetch must not hide the feature: resolve now.
        var resolvedURL = hlsURL
        if resolvedURL == nil {
            resolvedURL = await resolvePipURL()
        }
        // The view may have torn the chain down mid-resolve — staging a
        // session nobody owns would block the foreground start (latch).
        if Task.isCancelled {
            TJFLog("pip: staging cancelled during resolve")
            return
        }
        let url = resolvedURL
        guard let url, reportingConfigured,
              let itemId, let serverURL, let token, let userId
        else {
            TJFLog("pip: stage skipped — hls=\(url != nil) configured=\(reportingConfigured) item=\(itemId != nil)")
            return
        }
        // Only stage while something is actually playing.
        guard isPlaying || (currentTime > 0 && (duration <= 0 || currentTime < duration)) else {
            TJFLog("pip: stage skipped — not playing")
            return
        }
        // Re-check AFTER the awaits: the foreground start path (button,
        // view exit) can run while we are resolving the playlist, AND the
        // user can come right back to the app or finish the item while we
        // wait. Staging then would arm the auto-start flag (and a muted
        // playing AVPlayer) on a gate that no longer holds.
        guard pipState == .idle, !PipSession.shared.isActive else { return }
        guard canAutoHandoffToPiP else {
            TJFLog("pip: staging dropped after resolve — playing=\(isPlaying) pausedByUser=\(userPaused)")
            return
        }

        let position = max(currentTime, pendingResumePosition ?? 0)
        TJFLog("pip: staging handoff at \(String(format: "%.1f", position))s state=\(UIApplication.shared.applicationState.rawValue)")
        pipState = .active

        let context = PipSession.Context(
            itemId: itemId, serverURL: serverURL, token: token,
            userId: userId, playSessionId: reportingSessionId,
            streamURL: currentStreamURL,
            title: playbackTitle,
            mediaStreams: serverMediaStreams
        )
        let ok = PipSession.shared.prepare(
            hlsURL: url, position: position, context: context,
            preload: pipPreload,
            onVideoReady: makePipOnVideoReady(),
            onAborted: makePipOnAborted()
        )
        if !ok {
            TJFLog("pip: staging failed")
            pipState = .idle
        }
    }

    /// Back in the foreground with a staged-but-never-started session (the
    /// user only pulled down Control Centre / peeked the app switcher):
    /// drop the staging. No window opened, VLC was never frozen — playback
    /// just continues fullscreen.
    func cancelPreparedPictureInPicture() {
        guard pipState == .active, !PipSession.shared.windowStarted else { return }
        TJFLog("pip: staged session cancelled (user back in app)")
        PipSession.shared.cancelStaged()
        pipState = .idle
    }

    /// AVPlayer took over — freeze VLC at the handoff position.
    /// Async on purpose: the session awaits this BEFORE unmuting its own
    /// player, so the two audio sources never overlap.
    private func makePipOnVideoReady() -> (@MainActor () async -> Void)? {
        { @MainActor [weak self] in
            guard let self, self.pipState == .active else { return }
            TJFLog("pip: freezing VLC for handoff")
            self.pipVLCFrozen = true
            self.reportProgress(at: self.currentTime)
            self.stopUpdating()
            await self.engine.pause()
            self.isPlaying = false
            self.finishExitHandoff()
        }
    }

    /// The window opened and then died (HLS item failed): roll the state
    /// back so PiP can be started again, and save progress when this player
    /// already left the screen.
    private func makePipOnAborted() -> () -> Void {
        { [weak self] in
            guard let self, self.pipState == .active else { return }
            TJFLog("pip: session aborted → rolling back pipState")
            self.pipState = .idle
            if self.exitHandoffPending {
                self.exitHandoffPending = false
                self.stopSync(reportStop: true)
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.engine.play()
                    self.isPlaying = true
                    self.startUpdating()
                }
            }
        }
    }

    /// Hand playback over to the floating PiP window — automatically on
    /// background or when the player is dismissed, or manually via the
    /// controls button. On failure falls back to VLC background audio
    /// (playback keeps running without a window).
    /// - Returns: true when the system window actually started.
    @discardableResult
    func startPictureInPicture() async -> Bool {
        // Already staged at scenePhase .inactive — only the window is
        // missing (the system may even have opened it by itself by now).
        if PipSession.shared.isActive {
            guard !pipStartInFlight else {
                TJFLog("pip: start skipped — startWindow in flight")
                return false
            }
            pipStartInFlight = true
            defer { pipStartInFlight = false }
            let started = await PipSession.shared.startWindow()
            return await finishPipStart(started)
        }
        guard pipState == .idle, !pipStartInFlight else {
            TJFLog("pip: start skipped — pipState=\(pipState) inFlight=\(pipStartInFlight)")
            return false
        }
        // Synchronous latch: a background start and the exit handoff can BOTH
        // pass `pipState == .idle` before the first one finishes awaiting the
        // playlist resolve — the loser would reset pipState and stop VLC
        // underneath a handoff that is already running.
        pipStartInFlight = true
        defer { pipStartInFlight = false }
        // A slow or failed prefetch must not hide the feature: resolve now.
        var resolvedURL = hlsURL
        if resolvedURL == nil {
            resolvedURL = await resolvePipURL()
        }
        let url = resolvedURL
        guard let url, reportingConfigured,
              let itemId, let serverURL, let token, let userId
        else {
            TJFLog("pip: start skipped — hls=\(url != nil) configured=\(reportingConfigured) item=\(itemId != nil) server=\(serverURL != nil)")
            return false
        }
        // Only hand off while something is actually playing.
        guard isPlaying || (currentTime > 0 && (duration <= 0 || currentTime < duration)) else {
            TJFLog("pip: skipped — not playing")
            return false
        }
        // Another player instance already owns the floating window.
        guard !PipSession.shared.isActive else {
            TJFLog("pip: start skipped — a session is already active")
            return false
        }

        // Hand off at the furthest known position: right after play starts
        // `currentTime` can still be 0 (VLC seek not landed), while
        // `pendingResumePosition` holds the target the row asked for. A 0
        // handoff would freeze PiP at the episode start and overwrite the
        // saved resume with seconds.
        let position = max(currentTime, pendingResumePosition ?? 0)
        TJFLog("pip: handoff from VLC at \(String(format: "%.1f", position))s (currentTime=\(String(format: "%.1f", currentTime)))")

        pipState = .active

        let context = PipSession.Context(
            itemId: itemId, serverURL: serverURL, token: token,
            userId: userId, playSessionId: reportingSessionId,
            streamURL: currentStreamURL,
            title: playbackTitle,
            mediaStreams: serverMediaStreams
        )
        let prepared = PipSession.shared.prepare(
            hlsURL: url, position: position, context: context,
            preload: pipPreload,
            onVideoReady: makePipOnVideoReady(),
            onAborted: makePipOnAborted()
        )
        if !prepared {
            TJFLog("pip: prepare failed")
            return await finishPipStart(false)
        }
        let started = await PipSession.shared.startWindow()
        return await finishPipStart(started)
    }

    /// Shared post-start handling: log + roll back state + VLC fallback.
    private func finishPipStart(_ started: Bool) async -> Bool {
        if started {
            TJFLog("pip: started item=\(itemId ?? "nil")")
        } else {
            TJFLog("pip: start failed → resuming VLC (background audio fallback)")
            if pipState == .active { pipState = .idle }
            if exitHandoffPending {
                // The view already went away: nothing can play audio with
                // no UI — end the session cleanly instead of ghost audio.
                exitHandoffPending = false
                stopSync(reportStop: true)
            } else if pipVLCFrozen, !PipSession.shared.isActive, !engineStopped {
                // The system window never took playback over and VLC WAS
                // frozen for it: it must not stay frozen — that is the
                // "blocked image" state — and it must do so even when a
                // concurrent resume already flipped `pipState` (playing
                // again is a no-op if it did). An ALREADY STOPPED engine stays
                // stopped: the abort path may have ended it on purpose.
                TJFLog("pip: no window → unfreezing primary player")
                pipVLCFrozen = false
                await engine.play()
                isPlaying = true
                startUpdating()
            }
        }
        return started
    }

    /// VLC can be released now that the floating window owns playback
    /// (only meaningful for an exit handoff in flight).
    private func finishExitHandoff() {
        guard exitHandoffPending else { return }
        exitHandoffPending = false
        TJFLog("pip: handoff complete — releasing VLC")
        engine.stopSync()
        engineStopped = true
        stopUpdating()
    }

    /// Registers this player's PiP observers while its view is on screen.
    /// The root view keeps its own permanent pair, so a restore request always
    /// has an owner even after this view model is gone.
    func attachPipHandlers() {
        #if os(iOS)
        guard pipRestoreHandlerId == nil else { return }
        pipRestoreHandlerId = PipSession.shared.addRestoreHandler(
            priority: PipSession.liveHandlerPriority
        ) { [weak self] position in
            // Claim ONLY when this player can actually take playback back:
            // answering "true" and then bailing tells the system to close the
            // window while nothing ends up playing.
            guard let self, self.itemId != nil,
                  self.itemId == PipSession.shared.activeItemId,
                  self.currentStreamURL != nil
            else { return false }
            TJFLog("pip: restore claimed by live player at \(String(format: "%.1f", position))s")
            Task { await self.resumeFromPictureInPicture() }
            return true
        }
        pipClosedHandlerId = PipSession.shared.addClosedHandler { [weak self] in
            guard let self else { return }
            TJFLog("pip: closed by user — dismissing fullscreen")
            // Session already reported playback stopped to the server.
            self.pipSessionReportedStop = true
            self.pipState = .idle
            // The user ENDED playback. Without this the fullscreen view that
            // is now disappearing still sees isPlaying == true and re-opens
            // the very window they just closed.
            self.isPlaying = false
            self.stopUpdating()
            self.onPiPClosed?()
        }
        #endif
    }

    /// Unregister — called from PlayerView.onDisappear so dead closures can
    /// never claim (and then fail) a restore request.
    func detachPipHandlers() {
        #if os(iOS)
        if let pipRestoreHandlerId {
            PipSession.shared.removeRestoreHandler(pipRestoreHandlerId)
            self.pipRestoreHandlerId = nil
        }
        if let pipClosedHandlerId {
            PipSession.shared.removeClosedHandler(pipClosedHandlerId)
            self.pipClosedHandlerId = nil
        }
        #endif
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
            userPaused = false
            if position > 0 { await seek(to: position) }
        } else {
            // Media still loaded (just paused) — seek to the PiP position.
            if position > 0 { await seek(to: position) }
            await engine.play()
            isPlaying = true
            userPaused = false
        }
        startUpdating()
    }

    #endif

    /// The fullscreen view disappeared. Playback must NOT die with it: hand
    /// the running item to the floating window when possible, otherwise stop.
    /// Defined outside the iOS-only PiP block — every platform calls it.
    func handleViewExit(handoffAllowed: Bool = true) {
        #if os(iOS)
        if pipState == .active {
            if PipSession.shared.windowStarted {
                TJFLog("pip: view exit while floating — VLC released, playback continues")
                stopSync(reportStop: false)
                return
            }
            if !PipSession.shared.isActive {
                // pipState was stale (session already gone): skipping the stop
                // report here would silently discard the episode's progress.
                TJFLog("pip: view exit — stale pipState, stopping with report")
                stopSync(reportStop: true)
                return
            }
            // Staged at .inactive but the system never opened a window: nothing
            // floats yet — drop the staging and fall through to the normal exit
            // handoff below (VLC is still playing, so handing off is exactly
            // what the X button is for; stopping instead would kill playback
            // the user only meant to hand over).
            TJFLog("pip: view exit with staged (unstarted) session → cancel staging, re-run handoff")
            PipSession.shared.cancelStaged()
            pipState = .idle
        }
        if errorMessage != nil {
            // An error path tore this player down (failed prepare/swap/engine):
            // a floating window over an error screen keeps a broken session —
            // and ghost audio — alive with nobody watching. Save progress.
            TJFLog("pip: exit after error → stop with report, no handoff")
            stopSync(reportStop: true)
            return
        }
        if handoffAllowed, canAutoHandoffToPiP, reportingConfigured, itemId != nil,
           // The user CLOSED the floating window: that ended playback (the
           // session already reported the stop). Re-floating it here is the
           // "I closed it and it came back" bug — `isPlaying == false` used to
           // be the only thing preventing it, and the position-based gate
           // would happily hand a finished item off again.
           !pipSessionReportedStop
        {
            TJFLog("pip: view exit → auto handoff to PiP")
            exitHandoffPending = true
            Task {
                let started = await self.startPictureInPicture()
                if started {
                    // AVPlayer owns the audio as soon as it is ready; give it
                    // up to 10s before releasing VLC (bounded, no ghost audio).
                    for _ in 0..<100 {
                        if !self.exitHandoffPending { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if self.exitHandoffPending {
                        // The window never took playback over (item failed or
                        // never became ready): NOTHING is playing now, so stop
                        // WITH the stop report — a silent stop here is exactly
                        // how the episode's progress got lost.
                        TJFLog("pip: handoff never became ready → stopping with report")
                        self.exitHandoffPending = false
                        self.stopSync(reportStop: true)
                    } else {
                        self.engine.stopSync()
                        self.engineStopped = true
                        self.stopUpdating()
                    }
                } else {
                    self.exitHandoffPending = false
                    self.stopSync(reportStop: true)
                }
            }
            return
        }
        #endif
        stopSync(reportStop: true)
    }
}
