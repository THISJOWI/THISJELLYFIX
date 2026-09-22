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
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = PlayerViewModel()
    @State private var seekIndicator: SeekIndicator?
    @State private var controlsTimer: Timer?
    @State private var wasPlaying = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCPlayerBridge(viewModel: viewModel)
                .ignoresSafeArea()

            // Transparent tap catcher — always active
            Color.clear
                .contentShape(Rectangle())
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

            // Controls overlay — buttons only active when visible
            if viewModel.showControls {
                ControlsOverlay(
                    title: title,
                    viewModel: viewModel,
                    onDismiss: { onDismiss?() ?? dismiss() },
                    onToggleFullscreen: {
                        #if os(macOS)
                        if let nsWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isKeyWindow }) {
                            nsWindow.toggleFullScreen(nil)
                        }
                        #endif
                    }
                )
                .transition(.opacity)
                .onTapGesture { } // absorb taps — don't fall through
            }

            if let seek = seekIndicator {
                SeekHUD(text: seek.text)
                    .transition(.opacity)
            }

            if let error = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                    Button("Cerrar") { onDismiss?() ?? dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    handleSwipe(value)
                }
        )
        .onAppear {
            Task {
                await viewModel.prepareStream(url: streamURL)
                // Wait for VLCPlayerBridge to attach drawable before playing
                try? await Task.sleep(for: .milliseconds(500))
                await viewModel.togglePlayPause()
                // Resume from saved position if available
                if let start = startPosition, start > 0 {
                    await viewModel.seek(to: start)
                }
                viewModel.startUpdating()
            }
            resetControlsTimer()
        }
        .onDisappear {
            controlsTimer?.invalidate()
            viewModel.stopUpdating()
            if allowStop {
                Task { await viewModel.stop() }
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
}

// MARK: - VLC Player Bridge (Cross-platform)

#if os(macOS)
private struct VLCPlayerBridge: NSViewRepresentable {
    let viewModel: PlayerViewModel

    func makeNSView(context: Context) -> VLCVideoView {
        let videoView = VLCVideoView()
        videoView.fillScreen = true
        return videoView
    }

    func updateNSView(_ nsView: VLCVideoView, context: Context) {
        viewModel.attachDrawable(nsView)
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
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button(action: onToggleFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            Button(action: { Task { await viewModel.togglePlayPause() } }) {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
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
