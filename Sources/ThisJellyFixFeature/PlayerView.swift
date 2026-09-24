import SwiftUI
import ThisJellyFixCore
import ThisJellyFixPlayback
import VLCKitSPM

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

    // MARK: - Fit / fill pinch
    @State private var isPinching = false
    @State private var lastPinchEnd: Date = .distantPast

    private func dismissPlayer() {
        onDismiss?() ?? dismiss()
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

            #if os(iOS)
            // Hosts the AVPlayerLayer of the active PiP session so the system
            // floating window has a layer inside the view hierarchy.
            .overlay {
                PipLayerHostView(isActive: viewModel.pipState == .active)
                    .allowsHitTesting(false)
            }
            #endif

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
        .onAppear {
            #if os(iOS)
            // Force landscape orientation for playback
            forceLandscape()
            // Closing PiP (X) while floating dismisses this fullscreen UI.
            viewModel.onPiPClosed = { dismissPlayer() }
            #endif
            // Configure playback reporting if credentials provided
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
            // Next-episode action for the credits overlay
            if let nextEpisode, let onPlayNextEpisode {
                viewModel.hasNextEpisode = true
                viewModel.onPlayNextEpisode = { onPlayNextEpisode(nextEpisode) }
            } else {
                viewModel.hasNextEpisode = false
                viewModel.onPlayNextEpisode = nil
            }
            // Start the track/report timer FIRST — before any async work — so a
            // slow stream prepare can never leave us without polls.
            viewModel.startUpdating()
            Task {
                await viewModel.prepareStream(url: streamURL, startPosition: startPosition)
                // Wait for VLCPlayerBridge to attach drawable before playing
                try? await Task.sleep(for: .milliseconds(500))
                await viewModel.togglePlayPause()
                // Resume from saved position if available — media may already be
                // opened there via start-time; verify before re-seeking
                if let start = startPosition, start > 0 {
                    await viewModel.verifyResume(at: start)
                }
            }
            resetControlsTimer()
        }
        .onDisappear {
            #if os(iOS)
            // Restore auto-rotation when leaving player
            restoreOrientation()
            #endif
            controlsTimer?.invalidate()
            viewModel.stopUpdating()
            if allowStop {
                // Stop VLC synchronously on main thread BEFORE the view is deallocated.
                // Detach drawable first so VLC's render thread stops accessing the view,
                // then stop playback. This prevents the vlc_gl_filter_ApplyOutputSize crash.
                // While PiP is floating the play session must stay open — the
                // AVPlayer session keeps reporting progress on its own.
                viewModel.detachDrawable()
                viewModel.stopSync(reportStop: !viewModel.isPiPPlaybackContinuing)
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
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Auto-PiP: leaving the app hands the episode to the floating
                // window (skipped when paused or HLS is unavailable — VLC then
                // simply keeps playing audio in the background).
                Task { await viewModel.startPictureInPicture() }
            } else if newPhase == .active, viewModel.pipState == .active {
                // Foregrounded without tapping the window (app switcher) —
                // pull playback back into fullscreen. The tap path is driven
                // by the PiP delegate instead.
                Task { await viewModel.resumeFromPictureInPicture() }
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
#elseif os(iOS)
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
                if viewModel.pipAvailable && viewModel.pipState == .idle {
                    Button {
                        Task { await viewModel.startPictureInPicture() }
                    } label: {
                        Image(systemName: "pip")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
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
                            if let lang = track.language {
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
                                if let lang = track.language {
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
/// Embeds the `AVPlayerLayer` of the active `PipSession` into the fullscreen
/// player's view hierarchy. The system PiP window takes over rendering once it
/// starts; while the app is foregrounded the layer mirrors the floating
/// window's content (the fullscreen VLC frame underneath is paused).
private struct PipLayerHostView: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
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
