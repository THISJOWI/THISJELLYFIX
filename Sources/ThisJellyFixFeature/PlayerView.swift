import SwiftUI
import ThisJellyFixCore
import ThisJellyFixPlayback
import AVKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    #if os(iOS)
    /// The floating PiP session's live view model: restore hands it back so
    /// playback continues uninterrupted (same AVPlayer — no re-prepare, no
    /// re-buffer). nil = fresh playback session.
    var restoredViewModel: PlayerViewModel? = nil
    #endif

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel
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
    /// Fullscreen players currently on screen. The root's restore handler
    /// consults it so a restore can never present a SECOND player over a
    /// cover that already owns the UI (presentation fails silently and the
    /// floating window dies with nothing playing).
    nonisolated(unsafe) static var presentedCount = 0
    #endif

    init(
        streamURL: URL,
        title: String,
        allowStop: Bool = true,
        startPosition: Double? = nil,
        onDismiss: (() -> Void)? = nil,
        itemId: String? = nil,
        serverURL: URL? = nil,
        token: String? = nil,
        userId: String? = nil,
        playSessionId: String? = nil,
        mediaStreams: [MediaStream] = [],
        nextEpisode: JellyfinEpisode? = nil,
        onPlayNextEpisode: ((JellyfinEpisode) -> Void)? = nil,
        restoredViewModel: PlayerViewModel? = nil
    ) {
        self.streamURL = streamURL
        self.title = title
        self.allowStop = allowStop
        self.startPosition = startPosition
        self.onDismiss = onDismiss
        self.itemId = itemId
        self.serverURL = serverURL
        self.token = token
        self.userId = userId
        self.playSessionId = playSessionId
        self.mediaStreams = mediaStreams
        self.nextEpisode = nextEpisode
        self.onPlayNextEpisode = onPlayNextEpisode
        #if os(iOS)
        self.restoredViewModel = restoredViewModel
        _viewModel = State(initialValue: restoredViewModel ?? PlayerViewModel())
        #else
        _viewModel = State(initialValue: PlayerViewModel())
        #endif
    }

    /// Restore-from-PiP mount: the item is already playing in the adopted VM.
    private var isRestoring: Bool {
        #if os(iOS)
        restoredViewModel != nil
        #else
        false
        #endif
    }

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
        viewModel.configureNowPlaying(title: title)
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
            // AVPlayer presents the layer itself — no drawable to attach, no
            // warm/resolve chain (native PiP uses the same AVPlayerLayer).
            guard !Task.isCancelled else { return }
            await viewModel.togglePlayPause()
            // Resume from saved position — the media opens at 0, so seek
            // explicitly after play() (AVPlayer cannot seek on a nil item).
            if let start = startPosition, start > 0 {
                await viewModel.seek(to: start)
            }
            guard !Task.isCancelled else { return }
        }
    }

    var body: some View {
        // Use .overlay() instead of ZStack so ControlsOverlay is always the
        // topmost AppKit hosting view — critical after toggleFullScreen restructures
        // the window hierarchy and can reorder ZStack children.
        // Fit/fill is applied on the layer (videoGravity): no SwiftUI
        // scaleEffect, so native embedded subtitles are never cropped.
        PlayerLayerBridge(viewModel: viewModel)
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())

            // Episode swap — the player stays mounted, so cover the black
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

            // External subtitles (SRT composed client-side) — embedded ones are
            // painted by AVPlayerLayer itself via the legible media selection.
            .overlay(alignment: .bottom) {
                if let text = viewModel.subtitleText {
                    Text(text)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, viewModel.showControls ? 150 : 40)
                        .allowsHitTesting(false)
                        .transition(.opacity)
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
                        },
                        onAirPlayPresenting: { presenting in
                            if presenting {
                                // System route sheet up: freeze auto-hide so
                                // this overlay (the picker's host view) can't
                                // unmount mid-presentation — that left the
                                // AVRoutePickerView dead: later taps no-op.
                                controlsTimer?.invalidate()
                                viewModel.showControls = true
                            } else if viewModel.showControls {
                                resetControlsTimer()
                            }
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
            #if os(tvOS)
            // E8: tvOS has no close control — the Menu button was a dead end.
            .onExitCommand { dismissPlayer() }
            #endif
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
            if isRestoring {
                // Adopted the floating VM: its engine already plays and its
                // reporting is configured — release the session so the root
                // stops hosting the layer (this bridge takes it over).
                PipCoordinator.shared.releaseFloating()
            }
            #endif
            PlayerTeardown.reset()
            configureEpisode()
            // Start the track/report timer FIRST — before any async work — so a
            // slow stream prepare can never leave us without polls.
            viewModel.startUpdating()
            // Restored sessions are already playing at their position: a second
            // prepareStream would tear down the item the PiP window just closed.
            if !isRestoring {
                startPlayback()
            }
            resetControlsTimer()
        }
        .onChange(of: streamURL) { _, newURL in
            // Episode swap: stay mounted and hand the engine the new stream — the
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
                // Leaving the player must NOT cut playback: handleViewExit
                // hands the running item to the floating PiP window when
                // possible and only stops the engine when nothing can carry it.
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

            // Supported API only: the old UIDevice.setValue(_, forKey:
            // "orientation") KVC hack is rejected (E17) — geometry update +
            // rotation re-evaluation is the sanctioned path.
            if let windowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }

    private func restoreOrientation() {
        // Unlock immediately
        UIApplication.shared.tjf_orientationLock = .all

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
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

// MARK: - AVPlayer Layer Bridge (Cross-platform)

// The engine owns one AVPlayerLayer; these containers only parent it while a
// fullscreen mount exists. CALayers never intercept pointer events, so no
// hit-testing pass-through tricks are needed (that was a VLC drawable thing).

#if os(macOS)
private struct PlayerLayerBridge: NSViewRepresentable {
    let viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerLayerContainer {
        PlayerLayerContainer()
    }

    func updateNSView(_ nsView: PlayerLayerContainer, context: Context) {
        nsView.host(viewModel.engine.renderingLayer)
    }
}

private class PlayerLayerContainer: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so ALL mouse events pass through to SwiftUI views on top.
        nil
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }

    func host(_ layer: CALayer?) {
        guard let layer else { return }
        if layer.superlayer !== self.layer {
            layer.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
        }
        layer.frame = bounds
    }
}
#else
private struct PlayerLayerBridge: UIViewRepresentable {
    let viewModel: PlayerViewModel

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        PlayerLayerContainerView()
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        uiView.host(viewModel.engine.renderingLayer)
    }
}

private class PlayerLayerContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }

    func host(_ layer: CALayer?) {
        guard let layer else { return }
        if layer.superlayer !== self.layer {
            layer.removeFromSuperlayer()
            self.layer.addSublayer(layer)
        }
        layer.frame = bounds
    }
}
#endif

// MARK: - Controls Overlay

/// System AirPlay route picker (AVKit). Native glyph, opens the receiver
/// list — picking an Apple TV hands video+audio over through AVPlayer's
/// built-in external playback.
#if os(iOS)
private struct AirPlayRoutePicker: UIViewRepresentable {
    /// true when the system route sheet is up — the caller must keep the
    /// controls alive (unmounting this view mid-presentation kills the
    /// picker: every later tap does nothing).
    var onPresentingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentingChanged: onPresentingChanged)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        context.coordinator.onPresentingChanged = onPresentingChanged
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentingChanged: (Bool) -> Void

        init(onPresentingChanged: @escaping (Bool) -> Void) {
            self.onPresentingChanged = onPresentingChanged
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onPresentingChanged(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onPresentingChanged(false)
        }
    }
}
#endif

#if os(macOS)
private struct AirPlayRoutePicker: NSViewRepresentable {
    var onPresentingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentingChanged: onPresentingChanged)
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // macOS has no tintColor — per-state button colors instead.
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.systemBlue, for: .active)
        view.setRoutePickerButtonColor(.systemBlue, for: .activeHighlighted)
        view.isRoutePickerButtonBordered = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.onPresentingChanged = onPresentingChanged
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentingChanged: (Bool) -> Void

        init(onPresentingChanged: @escaping (Bool) -> Void) {
            self.onPresentingChanged = onPresentingChanged
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onPresentingChanged(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onPresentingChanged(false)
        }
    }
}
#endif

private struct ControlsOverlay: View {
    let title: String
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    let onToggleFullscreen: () -> Void
    /// AirPlay route sheet presentation state — the caller freezes the
    /// controls auto-hide while it's up.
    let onAirPlayPresenting: (Bool) -> Void

    var body: some View {
        VStack {
            HStack {
                #if !os(macOS)
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
                if viewModel.isPipWindowActive {
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
                    // Native PiP: no playlist resolve — startPictureInPicture is
                    // a thin call over the shared AVPlayerLayer, so the control
                    // never needs a warm-up state.
                    Button {
                        Task { await viewModel.startPictureInPicture() }
                    } label: {
                        Image(systemName: "pip")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .disabled(!viewModel.isPlaying && viewModel.currentTime <= 0)
                }
                #endif
                #if os(iOS) || os(macOS)
                // AirPlay route picker — sends video/audio to Apple TV and
                // other receivers (previously no UI entry point at all).
                AirPlayRoutePicker(onPresentingChanged: onAirPlayPresenting)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
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
/// Embeds the `AVPlayerLayer` of the active `PipCoordinator` session into the
/// ROOT view's hierarchy (always alive) so the system PiP window keeps a layer
/// inside the window even after the fullscreen player was dismissed. The system
/// window takes over rendering once it starts; while the app is foregrounded the
/// layer mirrors the floating window's content (same AVPlayer — nothing is
/// paused or re-prepared).
struct PipLayerHostView: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Registered up front: the coordinator attaches the layer synchronously
        // when a session floats, so the host must already be known by then.
        PipCoordinator.shared.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        PipCoordinator.shared.hostView = uiView
        guard isActive, let layer = PipCoordinator.shared.currentLayer else {
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
