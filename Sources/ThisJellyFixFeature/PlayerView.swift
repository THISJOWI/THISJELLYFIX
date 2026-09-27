import SwiftUI
import ThisJellyFixCore
import ThisJellyFixPlayback
import VLCKitSPM
#if os(iOS)
import UIKit
#endif

/// Why the fullscreen player is being torn down.
///
/// Parents (DetailView, DirectPlayer) unmount `PlayerView` themselves when a
/// stream fails, and they cannot reach its view model. They set this flag
/// synchronously right before removing the player; `onDisappear` consumes it
/// at disappearance time. A plain `Bool` parameter would NOT work: SwiftUI
/// coalesces the error write and the unmount into a single render, so the view
/// would still carry the pre-error value and hand a broken episode off to PiP
/// (floating window over the error screen + ghost audio).
enum PlayerTeardown {
    nonisolated(unsafe) private static var errorFlag = false

    /// The parent is removing the player BECAUSE of a failure.
    static func noteError() { errorFlag = true }
    /// A new playback session starts — drop anything a previous one left.
    static func reset() { errorFlag = false }
    /// Returns the flag and clears it (every read consumes).
    static func consumeErrorFlag() -> Bool {
        defer { errorFlag = false }
        return errorFlag
    }
}

struct PlayerView: View {
    let streamURL: URL
    let title: String
    var allowStop: Bool = true
    var startPosition: Double? = nil
    var onDismiss: (() -> Void)?
    // Playback reporting (optional — if nil, reporting is skipped)
    var itemId: String? = nil
    var serverURL: URL? = nil
    var token: String? = nil
    var userId: String? = nil
    var playSessionId: String? = nil
    // Server media streams — needed to load external subtitle files
    var mediaStreams: [MediaStream] = []
    // Next episode wiring — when provided, the credits overlay offers it
    var nextEpisode: JellyfinEpisode? = nil
    var onPlayNextEpisode: ((JellyfinEpisode) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var viewModel = PlayerViewModel()
    @State private var seekIndicator: SeekIndicator?
    @State private var controlsTimer: Timer?
    @State private var wasPlaying = false
    /// In-flight playback work. Untracked tasks kept running after the player
    /// was dismissed and called `engine.play()` on a stopped engine — audio with
    /// no UI. Cancelled in `onDisappear`.
    @State private var playbackTask: Task<Void, Never>?
    @State private var episodeSwapTask: Task<Void, Never>?

    // MARK: - Fit / fill pinch
    @State private var isPinching = false
    @State private var lastPinchEnd: Date = .distantPast
    #if os(iOS)
    /// True from the moment the user starts leaving the app (scenePhase
    /// → .inactive/.background) until they come back — gates the deferred
    /// PiP handoff so a slow playlist resolve never pops the window AFTER
    /// the user returned to fullscreen.
    @State private var leavingApp = false
    /// The warm/resolve chain launched by a scenePhase change — cancelled on
    /// disappear so it can never start PiP from a view that is gone.
    @State private var pipLeaveTask: Task<Void, Never>?
    /// Stage-1 chain (warm + stage the PiP apparatus) launched on the way
    /// OUT (.inactive with .active before it). The background chain awaits
    /// it instead of cancelling it.
    @State private var pipStagingTask: Task<Void, Never>?
    /// Fullscreen players currently on screen. The root's restore handler
    /// consults it so a restore can never present a SECOND player over a
    /// cover that already owns the UI (presentation fails silently and the
    /// floating window dies with nothing playing).
    nonisolated(unsafe) static var presentedCount = 0
    #endif

    private func dismissPlayer() {
        onDismiss?() ?? dismiss()
    }

    /// Wire the CURRENT item into the view model: reporting, server streams and
    /// PiP prefetch. Called once, when the player mounts.
    private func configureEpisode() {
        if let itemId, let serverURL, let token, let userId {
            viewModel.configureReporting(userId: userId, serverURL: serverURL, token: token, itemId: itemId, playSessionId: playSessionId)
        } else {
            TJFLog("onAppear: reporting NOT configured itemId=\(itemId != nil) serverURL=\(serverURL != nil) token=\(token != nil) userId=\(userId != nil)")
        }
        viewModel.configureMediaStreams(mediaStreams)
        #if os(iOS)
        // Warm the HLS playlist for PiP — non-blocking.
        viewModel.resolvePipSupport()
        #endif
        wireNextEpisode()
    }

    /// Credits overlay action for the CURRENT next episode (re-run whenever
    /// `nextEpisode` changes, including after a swap).
    private func wireNextEpisode() {
        if let nextEpisode, let onPlayNextEpisode {
            viewModel.hasNextEpisode = true
            viewModel.onPlayNextEpisode = { onPlayNextEpisode(nextEpisode) }
        } else {
            viewModel.hasNextEpisode = false
            viewModel.onPlayNextEpisode = nil
        }
    }

    /// Open the media and start playback for the first mount.
    private func startPlayback() {
        playbackTask = Task {
            await viewModel.prepareStream(url: streamURL, startPosition: startPosition)
            // Wait for VLCPlayerBridge to attach drawable before playing
            try? await Task.sleep(for: .milliseconds(500))
            // Cancel must actually stop the chain: `try? await Task.sleep`
            // swallows CancellationError, and during the exit-handoff window
            // (engineStopped still false) a cancelled task could pause/resume
            // VLC underneath the floating window.
            guard !Task.isCancelled else { return }
            await viewModel.togglePlayPause()
            // Resume from saved position — the media opens at 0 (no
            // `:start-time`, see VLCPlaybackEngine.prepare), so seek explicitly.
            if let start = startPosition, start > 0 {
                await viewModel.seek(to: start)
            }
            guard !Task.isCancelled else { return }
            #if os(iOS)
            // Warm the PiP pipeline immediately so swipe-up opens near-instantly:
            Task {
                await viewModel.warmPictureInPicture()
            }
            #endif
        }
    }

    var body: some View {
        // Use .overlay() instead of ZStack so ControlsOverlay is always the
        // topmost AppKit hosting view — critical after toggleFullScreen restructures
        // the window hierarchy and can reorder ZStack children.
        // Fit/fill is applied INSIDE VLC (videoFitMode): a SwiftUI scaleEffect
        // here would crop VLC's subtitle layer off-screen in fill mode.
        VLCPlayerBridge(viewModel: viewModel)
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())

            // Episode swap — the player stays mounted, so cover VLC's black
            // loading gap with an in-player indicator instead of dropping back
            // out to the episode list.
            // NOTE: an active PiP session's AVPlayerLayer is hosted by
            // ThisJellyFixRootView (always alive) — hosting it here would rip
            // the layer out of the hierarchy the moment this cover closes.
            .overlay {
                if viewModel.isSwitchingEpisode {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text(title.isEmpty ? "Cargando…" : title)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Siguiente episodio")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }

            // Tap catcher — below controls, above video
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Double-tap: toggle fit ↔ fill
                        viewModel.setFill(!viewModel.isFill)
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.showControls.toggle()
                        }
                        if viewModel.showControls {
                            resetControlsTimer()
                        } else {
                            controlsTimer?.invalidate()
                        }
                    }
            }

            // Controls overlay — always the topmost hosting view
            .overlay {
                if viewModel.showControls {
                    ControlsOverlay(
                        title: title,
                        viewModel: viewModel,
                        onDismiss: { dismissPlayer() },
                        onToggleFullscreen: {
                            #if os(macOS)
                            if let nsWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isKeyWindow }) {
                                nsWindow.toggleFullScreen(nil)
                            }
                            #endif
                        }
                    )
                    .transition(.opacity)
                }
            }

            // Seek HUD
            .overlay {
                if let seek = seekIndicator {
                    SeekHUD(text: seek.text)
                        .transition(.opacity)
                }
            }

            // Seek/buffering feedback — the transport is working even though
            // the picture hasn't caught up yet.
            .overlay {
                if viewModel.isSeeking {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .transition(.opacity)
                }
            }

            // Skip segment overlay (intro / recap / credits) — visible even
            // when the controls are hidden, like Netflix's skip button.
            .overlay(alignment: .bottomTrailing) {
                if let segment = viewModel.activeSegment {
                    SkipSegmentOverlay(
                        segment: segment,
                        countdown: viewModel.segmentCountdown,
                        hasNextEpisode: viewModel.hasNextEpisode,
                        onSkip: { viewModel.skipActiveSegment() },
                        onPlayNext: { viewModel.playNextEpisode() }
                    )
                    .transition(.opacity)
                    .padding(.trailing, 24)
                    .padding(.bottom, viewModel.showControls ? 140 : 32)
                }
            }

            // Error message
            .overlay {
                if let error = viewModel.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                        Button("Cerrar") { dismissPlayer() }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                    }
                }
            }

            // macOS: separate floating window for close button.
            // toggleFullScreen restructures the view hierarchy and SwiftUI overlay
            // buttons lose hit testing. A separate NSWindow bypasses this entirely.
            #if os(macOS)
            .overlay {
                CloseButtonWindowRepresentable(
                    isVisible: viewModel.showControls,
                    onClose: { dismissPlayer() }
                )
                .allowsHitTesting(false)
            }
            #endif

            .onKeyPress(.escape) {
                dismissPlayer()
                return .handled
            }
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard !isPinching, Date().timeIntervalSince(lastPinchEnd) >= 0.4 else { return }
                        handleSwipe(value)
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in handleMagnifyChanged(value) }
                    .onEnded { value in handleMagnifyEnded(value) }
            )
            #endif
        .onAppear {
            #if os(iOS)
            // Force landscape orientation for playback
            forceLandscape()
            // Closing PiP (X) while floating dismisses this fullscreen UI.
            viewModel.onPiPClosed = { dismissPlayer() }
            viewModel.playbackTitle = title
            // Restore/close observers for THIS mount — detached on disappear.
            viewModel.attachPipHandlers()
            Self.presentedCount += 1
            #endif
            PlayerTeardown.reset()
            configureEpisode()
            // Start the track/report timer FIRST — before any async work — so a
            // slow stream prepare can never leave us without polls.
            viewModel.startUpdating()
            startPlayback()
            resetControlsTimer()
        }
        .onChange(of: streamURL) { _, newURL in
            // Episode swap: stay mounted and hand VLC the new stream — the
            // player never drops back out to the episode list.
            wireNextEpisode()
            episodeSwapTask = Task {
                await viewModel.switchToEpisode(
                    url: newURL,
                    startPosition: startPosition,
                    itemId: itemId,
                    serverURL: serverURL,
                    token: token,
                    userId: userId,
                    playSessionId: playSessionId,
                    mediaStreams: mediaStreams
                )
            }
        }
        .onChange(of: nextEpisode) { _, _ in
            // The credits list can resolve AFTER mount — keep the overlay wired.
            wireNextEpisode()
        }
        .onDisappear {
            #if os(iOS)
            // Restore auto-rotation when leaving player
            restoreOrientation()
            // This mount's PiP observers are dead weight now — the root view
            // keeps its own permanent pair for restore/close.
            viewModel.detachPipHandlers()
            Self.presentedCount = max(0, Self.presentedCount - 1)
            // A warm/resolve chain launched by scenePhase must not outlive the
            // view (it could start a floating window nobody owns).
            pipLeaveTask?.cancel()
            pipLeaveTask = nil
            pipStagingTask?.cancel()
            pipStagingTask = nil
            #endif
            // Drop any playback work still in flight BEFORE stopping: a task
            // resuming after teardown would call play()/seek() on a dead engine.
            playbackTask?.cancel()
            playbackTask = nil
            episodeSwapTask?.cancel()
            episodeSwapTask = nil
            controlsTimer?.invalidate()
            viewModel.stopUpdating()
            if allowStop {
                // Detach drawable first so VLC's render thread stops accessing
                // the view (prevents the vlc_gl_filter_ApplyOutputSize crash).
                // Leaving the player must NOT cut playback: handleViewExit
                // hands the running item to the floating PiP window when
                // possible and only stops VLC when nothing can carry it.
                viewModel.detachDrawable()
                // Read the teardown reason AT disappearance time: a plain Bool
                // parameter would carry the value of the last render, which
                // pre-dates a failure written in the same update (SwiftUI
                // coalesces them) — that is how a failed swap still handed
                // playback off to PiP over the error screen.
                viewModel.handleViewExit(handoffAllowed: !PlayerTeardown.consumeErrorFlag())
            }
        }
        .onChange(of: viewModel.isPlaying) { _, playing in
            // Show controls when playback pauses/stops unexpectedly (buffering, error)
            if wasPlaying && !playing {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showControls = true
                }
                resetControlsTimer()
            }
            wasPlaying = playing
        }
        // Handoff: publish the current playback state so the user can resume on
        // another Apple device. Only published when we have a full session
        // (itemId + serverURL + userId present); the token is deliberately
        // omitted — the receiving device reads its own from the shared Keychain.
        .userActivity(
            HandoffActivity.playing,
            isActive: itemId != nil && serverURL != nil && userId != nil
        ) { activity in
            guard let itemId, let serverURL, let userId else { return }
            let handoffItem = HandoffMediaItem(id: itemId, name: title, type: "")
            let built = HandoffActivity.playingActivity(
                item: handoffItem,
                serverURL: serverURL,
                userId: userId,
                position: viewModel.currentTime
            )
            activity.title              = built.title
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch  = false
            activity.userInfo           = built.userInfo
        }
        #if os(iOS)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Every transition is evidence: the swipe-up handoff used to fail
            // with ZERO log output, so a device repro told us nothing.
            TJFLog("pip: scenePhase → \(newPhase) appState=\(UIApplication.shared.applicationState.rawValue)")
            if newPhase == .active {
                leavingApp = false
                pipLeaveTask?.cancel()
                pipLeaveTask = nil
                // A staging chain suspended in its resolve would otherwise
                // resume and arm a session on an app the user just came
                // back to (it holds the start latch, so nobody could undo
                // it until it finished).
                pipStagingTask?.cancel()
                pipStagingTask = nil
                if viewModel.pipState == .active {
                    if PipSession.shared.windowStarted {
                        // Foregrounded without tapping the window (app switcher) —
                        // pull playback back into fullscreen. The tap path is driven
                        // by the PiP delegate instead.
                        Task { await viewModel.resumeFromPictureInPicture() }
                    } else {
                        // Staged on the way out but the system never opened a
                        // window (Control Centre / switcher peek): drop it and
                        // keep watching fullscreen.
                        viewModel.cancelPreparedPictureInPicture()
                    }
                }
            } else if newPhase == .inactive {
                // iOS also reports .inactive for notification centre, Control
                // Centre, screenshots, incoming calls and the app switcher peek
                // — so this phase NEVER opens the window itself (that regression
                // popped it over the video the user was still watching).
                if oldPhase == .active {
                    // First half of leaving: STAGE the whole apparatus now,
                    // while the scene is still alive. iOS opens PiP itself at
                    // the background transition
                    // (`canStartPictureInPictureAutomaticallyFromInline`) —
                    // a manual startPictureInPicture() issued after the scene
                    // is backgrounded was rejected on device (failedToStart).
                    guard viewModel.canAutoHandoffToPiP else {
                        TJFLog("pip: staging skipped — playing=\(viewModel.isPlaying) pausedByUser=\(viewModel.userPaused) pos=\(String(format: "%.1f", viewModel.currentTime))s err=\(viewModel.errorMessage != nil)")
                        return
                    }
                    pipStagingTask?.cancel()
                    pipStagingTask = Task {
                        await viewModel.warmPictureInPicture()
                        guard !Task.isCancelled else {
                            TJFLog("pip: staging cancelled at warm")
                            return
                        }
                        await viewModel.preparePictureInPicture()
                    }
                } else {
                    // background → inactive: the user is coming BACK — abort
                    // the pending handoff before it can open over them.
                    leavingApp = false
                    pipLeaveTask?.cancel()
                    pipLeaveTask = nil
                    pipStagingTask?.cancel()
                    pipStagingTask = nil
                }
            } else if newPhase == .background {
                // The definitive "user left" signal — and only when playback
                // may hand off: a player the USER paused must not float itself
                // away, but VLCKit's `isPlaying` lie (false while time still
                // advances) must not silently skip a playing item either —
                // that was the swipe-up "no me persigue" bug.
                guard viewModel.canAutoHandoffToPiP else {
                    TJFLog("pip: background handoff skipped — playing=\(viewModel.isPlaying) pausedByUser=\(viewModel.userPaused) pos=\(String(format: "%.1f", viewModel.currentTime))s/\(String(format: "%.1f", viewModel.duration))s err=\(viewModel.errorMessage != nil)")
                    // A staged apparatus must not outlive this gate: with the
                    // auto-start flag armed, iOS would float it away anyway.
                    viewModel.cancelPreparedPictureInPicture()
                    return
                }
                leavingApp = true
                let staging = pipStagingTask
                pipStagingTask = nil
                pipLeaveTask?.cancel()
                pipLeaveTask = Task {
                    // Keep the process alive past suspension: a cold playlist
                    // resolve (PlaybackInfo + 3 playlist GETs) can outlast the
                    // transition, and iOS suspending us mid-chain is why the
                    // window never appeared.
                    let app = UIApplication.shared
                    var bgTask: UIBackgroundTaskIdentifier = .invalid
                    bgTask = app.beginBackgroundTask(withName: "tjf.pipHandoff") {
                        // Out of time: abandon the handoff instead of risking
                        // termination for a task left running (the `defer`
                        // below may never execute while suspended).
                        TJFLog("pip: background time expired → abandoning handoff")
                        leavingApp = false
                        if bgTask != .invalid {
                            app.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }
                    defer {
                        if bgTask != .invalid { app.endBackgroundTask(bgTask) }
                        bgTask = .invalid
                    }
                    // The staging chain (warm + stage 1) must finish first:
                    // it owns the apparatus the system may auto-start at any
                    // moment, and it holds the start latch while resolving.
                    await staging?.value
                    guard leavingApp, !Task.isCancelled else {
                        TJFLog("pip: background start aborted after staging — leavingApp=\(leavingApp) cancelled=\(Task.isCancelled)")
                        return
                    }
                    // No-op when the system already opened the window itself;
                    // safety net (manual start + retries) when it did not.
                    await viewModel.startPictureInPicture()
                }
            }
        }
        #endif
        .sheet(isPresented: $viewModel.showAudioPicker) {
            AudioPickerSheet(
                tracks: viewModel.availableAudioTracks,
                selected: viewModel.selectedAudioTrackIndex
            ) { track in
                Task { await viewModel.selectAudioTrack(track) }
            }
        }
        .sheet(isPresented: $viewModel.showSubtitlePicker) {
            SubtitlePickerSheet(
                tracks: viewModel.availableSubtitleTracks,
                selected: viewModel.selectedSubtitleTrackIndex
            ) { track in
                Task { await viewModel.selectSubtitleTrack(track) }
            }
        }
        .sheet(isPresented: $viewModel.showSpeedPicker) {
            SpeedPickerSheet(
                currentRate: viewModel.playbackRate
            ) { rate in
                Task { await viewModel.setPlaybackRate(rate) }
            }
        }
    }

    // MARK: - Fit / fill gestures

    #if !os(tvOS)
    /// Pinch out → fill the whole screen (crop overflow).
    /// Pinch in → fit the whole video (letterbox, no crop).
    private func handleMagnifyChanged(_ value: MagnifyGesture.Value) {
        isPinching = true
        let fill = value.magnification >= 1
        if viewModel.isFill != fill {
            viewModel.setFill(fill)
        }
    }

    private func handleMagnifyEnded(_ value: MagnifyGesture.Value) {
        isPinching = false
        lastPinchEnd = Date()
        viewModel.setFill(value.magnification >= 1)
    }

    private func handleSwipe(_ value: DragGesture.Value) {
        let horizontal = value.translation.width
        let vertical = value.translation.height

        if abs(horizontal) > abs(vertical) {
            let delta = horizontal > 0 ? 15.0 : -15.0
            Task {
                await viewModel.seekRelative(delta)
                withAnimation { seekIndicator = SeekIndicator(text: delta > 0 ? "+15s" : "-15s") }
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation { seekIndicator = nil }
            }
        }
    }
    #endif

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.showControls = false
                }
            }
        }
    }

    #if os(iOS)
    private func forceLandscape() {
        // Lock to landscape FIRST — supportedInterfaceOrientationsFor returns this,
        // forcing iOS to rotate away from portrait.
        UIApplication.shared.tjf_orientationLock = [.landscapeLeft, .landscapeRight]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            .first

            if let windowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }

            // Fallback: force via UIDevice (works on all iOS versions)
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }

    private func restoreOrientation() {
        // Unlock immediately
        UIApplication.shared.tjf_orientationLock = .all

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Primary: request portrait via geometry
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))

            // Fallback: force via UIDevice
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }

        // Safety: ensure unlocked after transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIApplication.shared.tjf_orientationLock = .all
        }
    }
    #endif
}

#if os(iOS)
// MARK: - Orientation Lock

extension UIApplication {
    private struct Keys {
        static var orientationLock: UInt8 = 0
    }

    public var tjf_orientationLock: UIInterfaceOrientationMask {
        get {
            (objc_getAssociatedObject(self, &Keys.orientationLock) as? UIInterfaceOrientationMask) ?? .all
        }
        set {
            objc_setAssociatedObject(self, &Keys.orientationLock, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

// App Delegate must implement this to support orientation lock:
// func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
//     return orientationLock
// }
#endif

// MARK: - VLC Player Bridge (Cross-platform)

#if os(macOS)
private struct VLCPlayerBridge: NSViewRepresentable {
    let viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PassThroughContainer {
        PassThroughContainer()
    }

    func updateNSView(_ nsView: PassThroughContainer, context: Context) {
        viewModel.attachDrawable(nsView.videoView)
    }
}

/// Container that wraps VLCVideoView and blocks ALL hit testing.
/// The key: returning nil from the container's hitTest prevents AppKit from
/// ever traversing into descendant subviews (VLC's internal rendering views).
/// Without this, VLC's internal NSViews capture mouse events through AppKit's
/// native event dispatch, bypassing SwiftUI's gesture system entirely.
private class PassThroughContainer: NSView {
    let videoView: VLCVideoView

    override init(frame frameRect: NSRect) {
        videoView = VLCVideoView()
        super.init(frame: frameRect)
        setupVideoView()
    }

    required init?(coder: NSCoder) {
        videoView = VLCVideoView()
        super.init(coder: coder)
        setupVideoView()
    }

    private func setupVideoView() {
        // Aspect is driven by mediaPlayer.videoFitMode (fit/fill toggle);
        // fillScreen here would force-fill and break fit mode.
        videoView.fillScreen = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so ALL mouse events pass through to SwiftUI views on top.
        // This prevents VLC's internal rendering subviews from capturing events.
        nil
    }
}
#elseif os(iOS) || os(tvOS)
private struct VLCPlayerBridge: UIViewRepresentable {
    let viewModel: PlayerViewModel

    func makeUIView(context: Context) -> VLCPlayerUIView {
        let view = VLCPlayerUIView()
        return view
    }

    func updateUIView(_ uiView: VLCPlayerUIView, context: Context) {
        viewModel.attachDrawable(uiView)
    }
}

private class VLCPlayerUIView: UIView {}
#endif

// MARK: - Controls Overlay

private struct ControlsOverlay: View {
    let title: String
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    let onToggleFullscreen: () -> Void
    #if os(iOS)
    /// The PiP button is resolving the HLS playlist before it can open the
    /// window — show progress instead of a dead-looking tap.
    @State private var pipStarting = false
    #endif

    var body: some View {
        VStack {
            HStack {
                #if os(iOS)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
                #endif
                Spacer()
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                #if os(macOS)
                Button(action: onToggleFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                #endif
                #if os(iOS)
                if viewModel.pipState == .active {
                    // Floating already — pull playback back into fullscreen.
                    Button {
                        Task { await viewModel.resumeFromPictureInPicture() }
                    } label: {
                        Image(systemName: "pip.exit")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                } else {
                    // Always offered (4.9): a slow or failed HLS prefetch is
                    // retried ON TAP instead of hiding the control, and the
                    // button shows progress while the playlist resolves so the
                    // wait is visible instead of looking like a dead tap.
                    Button {
                        Task {
                            pipStarting = true
                            await viewModel.startPictureInPicture()
                            pipStarting = false
                        }
                    } label: {
                        Group {
                            if pipStarting {
                                ProgressView().tint(.white).scaleEffect(0.7)
                            } else {
                                Image(systemName: "pip")
                            }
                        }
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.5), in: Circle())
                    }
                    // Enable as soon as playback has a position: VLCKit can
                    // report `isPlaying == false` while time advances, and that
                    // lie kept the control disabled until the user "waited".
                    .disabled(!viewModel.isPlaying && viewModel.currentTime <= 0)
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 50) {
                Button(action: {
                    let target = max(0, viewModel.currentTime - 15)
                    Task { await viewModel.seek(to: target) }
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.3), in: Circle())
                }

                Button(action: { Task { await viewModel.togglePlayPause() } }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }

                Button(action: {
                    let target = min(viewModel.duration, viewModel.currentTime + 15)
                    Task { await viewModel.seek(to: target) }
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.3), in: Circle())
                }
            }

            Spacer()

            VStack(spacing: 8) {
                SeekBar(
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration
                ) { newTime in
                    Task { await viewModel.seek(to: newTime) }
                }

                HStack {
                    Text(formatTime(viewModel.currentTime))
                    Spacer()
                    Text(formatTime(viewModel.duration))
                }
                .font(.caption)
                .foregroundStyle(.white)

                HStack(spacing: 24) {
                    ActionButton(
                        icon: "speaker.wave.2",
                        label: "Audio",
                        disabled: viewModel.availableAudioTracks.isEmpty
                    ) {
                        viewModel.showAudioPicker = true
                    }
                    ActionButton(
                        icon: "captions.bubble",
                        label: "Subtítulos",
                        disabled: viewModel.availableSubtitleTracks.isEmpty
                    ) {
                        viewModel.showSubtitlePicker = true
                    }
                    ActionButton(icon: "speedometer", label: String(format: "%.1fx", viewModel.playbackRate)) {
                        viewModel.showSpeedPicker = true
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Seek Bar

private struct SeekBar: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var scrubTime: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.3))
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(.cyan)
                    .frame(width: progressWidth(total: geo.size.width), height: 6)

                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: progressWidth(total: geo.size.width) - 7)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        scrubTime = fraction * duration
                    }
                    .onEnded { _ in
                        if let scrubTime {
                            onSeek(scrubTime)
                        }
                        scrubTime = nil
                    }
            )
            #endif
        }
        .frame(height: 20)
    }

    private func progressWidth(total: CGFloat) -> CGFloat {
        let time = scrubTime ?? currentTime
        guard duration > 0 else { return 0 }
        return total * CGFloat(time / duration)
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let icon: String
    let label: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(disabled ? .gray : .white)
        }
        .disabled(disabled)
    }
}

// MARK: - HUD Indicators

private struct SeekHUD: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SeekIndicator: Equatable {
    let text: String
}

// MARK: - Skip Segment Overlay

/// Netflix-style skip button(s) shown when the playhead is inside an
/// intro / recap / credits segment.
private struct SkipSegmentOverlay: View {
    let segment: SegmentMarker
    let countdown: Double?
    let hasNextEpisode: Bool
    let onSkip: () -> Void
    let onPlayNext: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if segment.type == .credits {
                // Ending: two choices — skip to the end, or jump to next episode.
                if hasNextEpisode {
                    skipButton(label: "Siguiente episodio", icon: "forward.end.fill", action: onPlayNext)
                }
                skipButton(label: "Saltar ending", icon: "arrow.right.to.line", action: onSkip)
            } else {
                skipButton(label: label, icon: "fastforward", action: onSkip)
            }

            if let countdown {
                Text("Auto en \(Int(countdown.rounded(.up)))s")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var label: String {
        switch segment.type {
        case .intro: "Saltar intro"
        case .recap: "Saltar resumen"
        case .credits: "Saltar ending"
        }
    }

    private func skipButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheets

private struct AudioPickerSheet: View {
    let tracks: [AudioTrack]
    let selected: Int?
    let onSelect: (AudioTrack?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tracks) { track in
                Button {
                    onSelect(track)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(track.name)
                            if let lang = track.languageName ?? track.language {
                                Text(lang).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if track.id == selected {
                            Image(systemName: "checkmark").foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .navigationTitle("Pista de audio")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

private struct SubtitlePickerSheet: View {
    let tracks: [SubtitleTrack]
    let selected: Int?
    let onSelect: (SubtitleTrack?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Desactivados")
                        Spacer()
                        if selected == nil {
                            Image(systemName: "checkmark").foregroundStyle(.cyan)
                        }
                    }
                }

                ForEach(tracks) { track in
                    Button {
                        onSelect(track)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.name)
                                if let lang = track.languageName ?? track.language {
                                    Text(lang).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if track.id == selected {
                                Image(systemName: "checkmark").foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Subtítulos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

private struct SpeedPickerSheet: View {
    let currentRate: Float
    let onSelect: (Float) -> Void
    @Environment(\.dismiss) private var dismiss

    private let speeds: [(label: String, rate: Float)] = [
        ("0.5x", 0.5),
        ("0.75x", 0.75),
        ("Normal", 1.0),
        ("1.25x", 1.25),
        ("1.5x", 1.5),
        ("2x", 2.0),
    ]

    var body: some View {
        NavigationStack {
            List(speeds, id: \.rate) { speed in
                Button {
                    onSelect(speed.rate)
                    dismiss()
                } label: {
                    HStack {
                        Text(speed.label)
                        Spacer()
                        if speed.rate == currentRate {
                            Image(systemName: "checkmark").foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .navigationTitle("Velocidad")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

// MARK: - macOS Floating Close Button Window

#if os(macOS)
/// A SwiftUI-friendly wrapper that manages a floating NSPanel for the close button.
/// After toggleFullScreen, SwiftUI overlay buttons lose hit testing. This bypasses
/// the issue by placing the close button in its own window above the player.
private struct CloseButtonWindowRepresentable: NSViewRepresentable {
    let isVisible: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let hostView = NSView()
        DispatchQueue.main.async {
            context.coordinator.createWindow(hostView: hostView, onClose: onClose)
            if isVisible {
                context.coordinator.show()
            }
        }
        return hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isVisible {
            context.coordinator.show()
        } else {
            context.coordinator.hide()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        private var panel: NSPanel?
        private var onClose: (() -> Void)?
        private var playerWindowObserver: NSObjectProtocol?
        private var frameObservation: NSKeyValueObservation?
        private weak var playerWindow: NSWindow?
        private var closed = false

        func createWindow(hostView: NSView, onClose: @escaping () -> Void) {
            self.onClose = onClose

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .utilityWindow

            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
            button.bezelStyle = .circular
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
            button.contentTintColor = .white
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(closeClicked)
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
            button.layer?.cornerRadius = 18

            panel.contentView = button
            self.panel = panel
        }

        func show() {
            guard let panel else { return }

            // Don't re-show after user clicked close
            if closed { return }

            // Find or re-find the player window (handles fullscreen window changes)
            if let pw = playerWindow, !pw.isVisible {
                // Player window changed (e.g. fullscreen transition) — find the new one
                self.playerWindow = findPlayerWindow()
            } else if playerWindow == nil {
                self.playerWindow = findPlayerWindow()
            }

            guard let playerWindow else { return }

            // Observe frame changes to reposition panel when window moves/resizes/fullscreens
            frameObservation?.invalidate()
            frameObservation = playerWindow.observe(\.frame) { [weak self] window, _ in
                Task { @MainActor in
                    self?.repositionPanel()
                }
            }

            // Also listen for fullscreen transitions which may change the window
            if playerWindowObserver == nil {
                playerWindowObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    if let window = notification.object as? NSWindow,
                       window.title == playerWindow.title || window === playerWindow {
                        self?.playerWindow = window
                        self?.frameObservation?.invalidate()
                        self?.frameObservation = window.observe(\.frame) { [weak self] _, _ in
                            Task { @MainActor in
                                self?.repositionPanel()
                            }
                        }
                        // Reposition after a brief delay to let fullscreen animation settle
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            self?.repositionPanel()
                        }
                    }
                }
            }

            repositionPanel()
            panel.orderFront(nil)
        }

        func hide() {
            panel?.orderOut(nil)
        }

        func close() {
            frameObservation?.invalidate()
            frameObservation = nil
            if let obs = playerWindowObserver {
                NotificationCenter.default.removeObserver(obs)
                playerWindowObserver = nil
            }
            panel?.orderOut(nil)
            panel = nil
            playerWindow = nil
        }

        @objc private func closeClicked() {
            onClose?()
            panel?.orderOut(nil)
        }

        private func repositionPanel() {
            guard let panel, let playerWindow else { return }
            let origin = NSPoint(
                x: playerWindow.frame.origin.x + 16,
                y: playerWindow.frame.origin.y + playerWindow.frame.height - 52
            )
            panel.setFrameOrigin(origin)
        }

        /// Find the window that contains the VLC video player.
        /// During fullscreen, the window may be a different NSWindow instance.
        private func findPlayerWindow() -> NSWindow? {
            // Prefer the key window if it's playing video
            if let key = NSApp.keyWindow, key.contentView?.superview != nil {
                return key
            }
            // Fallback: find any visible window that could be the player
            return NSApp.windows.first {
                $0.isVisible && $0.level == .normal
            }
        }
    }
}
#endif

// MARK: - PiP Layer Host (iOS)

#if os(iOS)
/// Embeds the `AVPlayerLayer` of the active `PipSession` into the ROOT view's
/// hierarchy (always alive) so the system PiP window keeps a layer inside the
/// window even after the fullscreen player was dismissed. The system window
/// takes over rendering once it starts; while the app is foregrounded the layer
/// mirrors the floating window's content (the fullscreen VLC frame is paused).
struct PipLayerHostView: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Registered up front: PipSession attaches the layer synchronously when
        // a session starts, so the host must already be known by then.
        PipSession.shared.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        PipSession.shared.hostView = uiView
        guard isActive, let layer = PipSession.shared.currentLayer else {
            uiView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }
        if layer.superlayer !== uiView.layer {
            uiView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.frame = uiView.bounds
            uiView.layer.addSublayer(layer)
        } else {
            layer.frame = uiView.bounds
        }
    }
}
#endif
