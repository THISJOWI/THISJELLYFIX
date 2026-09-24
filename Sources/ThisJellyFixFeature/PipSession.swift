#if os(iOS)
import AVFoundation
import AVKit
import Foundation
import ThisJellyFixCore
import ThisJellyFixNetworking

/// Owns the AVPlayer + system Picture-in-Picture window on iOS.
///
/// Lives outside any view hierarchy (`static let shared`) so the floating
/// window survives scenePhase changes and PlayerView state churn during the
/// VLC ↔ AVPlayer handoff:
///
/// - **start**: takes over playback at `position` with an HLS playlist and
///   opens the system PiP window. Returns false when PiP never actually
///   started (not supported / failed) so the caller can fall back to VLC
///   background audio.
/// - **restore** (user taps the floating window): `onRestore(position)` — the
///   owner resumes fullscreen playback; returns false when nobody can take
///   over (player UI gone) and the session closes itself.
/// - **close** (user hits X / swipes): reports playback stopped to Jellyfin
///   and calls `onClosed` so the fullscreen UI (if any) dismisses.
@MainActor
final class PipSession: NSObject {
    static let shared = PipSession()

    struct Context {
        let itemId: String
        let serverURL: URL
        let token: String
        let userId: String
        let playSessionId: String?
    }

    /// Resume fullscreen playback at `position`. Returns false when no owner
    /// can take over — the system then abandons the restore.
    var onRestore: ((Double) -> Bool)?
    /// User closed the floating window while it was the active session.
    var onClosed: (() -> Void)?

    private(set) var isActive = false
    private(set) var activeItemId: String?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var context: Context?
    private var position: Double = 0
    private var timeObserver: Any?
    private var lastProgressReport = Date.distantPast
    private var startTimeoutWork: DispatchWorkItem?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var didStartFlag = false
    private var restoreRequested = false
    private var programmaticStop = false
    private var reporter = JellyfinPlaybackReporter()

    /// Layer to embed in the fullscreen player's view hierarchy while active.
    var currentLayer: AVPlayerLayer? { playerLayer }

    // MARK: - Lifecycle

    /// Hand playback over to AVPlayer and open the floating window.
    /// Returns true only when the system PiP window actually started.
    func start(hlsURL: URL, position: Double, context: Context) async -> Bool {
        guard !isActive else { return false }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            TJFLog("pip: not supported on this device")
            return false
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            TJFLog("pip: audio session error: \(error)")
        }

        self.context = context
        self.activeItemId = context.itemId
        self.position = position
        self.reporter.playSessionId = context.playSessionId
        self.didStartFlag = false
        self.restoreRequested = false
        self.programmaticStop = false
        self.lastProgressReport = Date()

        let avPlayer = AVPlayer(playerItem: AVPlayerItem(url: hlsURL))
        let layer = AVPlayerLayer(player: avPlayer)
        layer.videoGravity = .resizeAspect
        self.player = avPlayer
        self.playerLayer = layer

        let pip = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(playerLayer: layer)
        )
        pip.delegate = self
        self.pipController = pip

        // Track position and report progress every ~10s while floating.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.tick(time: time)
            }
        }

        isActive = true
        TJFLog("pip: starting at \(String(format: "%.1f", position))s url=\(hlsURL.absoluteString)")

        let started: Bool = await withCheckedContinuation { continuation in
            self.startContinuation = continuation

            // If the system never confirms the window (broken PiP, HLS too
            // slow, …) cancel and let the caller fall back to VLC audio.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.didStartFlag else { return }
                TJFLog("pip: didStart never arrived → cancelling")
                self.pipController?.stopPictureInPicture()
                self.cleanup()
                self.resumeStart(false)
            }
            self.startTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)

            let target = CMTime(seconds: position, preferredTimescale: 600)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    guard self.isActive else { return }
                    avPlayer.play()
                    pip.startPictureInPicture()
                }
            }
        }

        TJFLog("pip: start result=\(started)")
        return started
    }

    /// Programmatic stop — restore to fullscreen or teardown.
    /// Returns the captured playback position (AVPlayer's clock).
    @discardableResult
    func stop() -> Double {
        guard isActive else { return position }
        TJFLog("pip: programmatic stop at \(String(format: "%.1f", position))s")
        programmaticStop = true
        let captured = position
        pipController?.stopPictureInPicture()
        cleanup()
        return captured
    }

    /// Close as the user would: report playback stopped to the server first.
    func closeAndReport() {
        guard isActive else { return }
        reportStopped()
        programmaticStop = true
        pipController?.stopPictureInPicture()
        cleanup()
    }

    private func cleanup() {
        startTimeoutWork?.cancel()
        startTimeoutWork = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        playerLayer = nil
        pipController?.delegate = nil
        pipController = nil
        isActive = false
        activeItemId = nil
        context = nil
        restoreRequested = false
        resumeStart(false)
    }

    private func resumeStart(_ value: Bool) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: value)
    }

    // MARK: - Reporting

    private func tick(time: CMTime) {
        guard isActive else { return }
        let seconds = time.seconds
        if seconds.isFinite, seconds > 0 {
            position = seconds
        }
        guard let context, Date().timeIntervalSince(lastProgressReport) >= 10 else { return }
        lastProgressReport = Date()
        let ticks = Int64(position * 10_000_000)
        let isPaused = player?.timeControlStatus != .playing
        let reporter = self.reporter
        Task {
            await reporter.reportProgress(
                userId: context.userId, serverURL: context.serverURL, token: context.token,
                itemId: context.itemId, mediaSourceId: context.itemId,
                positionTicks: ticks, isPaused: isPaused
            )
        }
    }

    private func reportStopped() {
        guard let context else { return }
        let ticks = Int64(position * 10_000_000)
        let reporter = self.reporter
        Task {
            await reporter.reportStopped(
                userId: context.userId, serverURL: context.serverURL, token: context.token,
                itemId: context.itemId, mediaSourceId: context.itemId,
                positionTicks: ticks
            )
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipSession: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        TJFLog("pip: didStart")
        didStartFlag = true
        startTimeoutWork?.cancel()
        startTimeoutWork = nil
        resumeStart(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        TJFLog("pip: failedToStart: \(error.localizedDescription)")
        programmaticStop = true
        pictureInPictureController.stopPictureInPicture()
        cleanup()
        resumeStart(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        restoreRequested = true
        let target = position
        TJFLog("pip: restore requested at \(String(format: "%.1f", target))s")
        player?.pause()

        if let onRestore, onRestore(target) {
            completionHandler(true)
        } else {
            // Nobody can take the playback back (fullscreen UI gone) — end the
            // session instead of leaving a floating window with no target.
            TJFLog("pip: no restore owner → closing session")
            reportStopped()
            completionHandler(false)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        TJFLog("pip: didStop restore=\(restoreRequested) programmatic=\(programmaticStop)")

        if programmaticStop {
            // stop()/closeAndReport()/timeout already ran the cleanup.
            programmaticStop = false
            if isActive { cleanup() }
            return
        }

        if restoreRequested {
            // Restore path: VM resume (or closeAndReport) owns the teardown.
            if isActive { cleanup() }
            restoreRequested = false
            return
        }

        // User closed the floating window (X / swipe).
        reportStopped()
        cleanup()
        onClosed?()
    }
}
#endif
