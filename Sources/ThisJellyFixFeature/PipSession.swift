#if os(iOS)
import AVFoundation
import AVKit
import Foundation
import Observation
import UIKit
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
/// - **restore** (user taps the floating window): registered restore handlers
///   are asked in LIFO order — the live player resumes fullscreen, or the ROOT
///   view re-presents a new one. Nobody available → the session closes itself.
/// - **close** (user hits X / swipes): reports playback stopped to Jellyfin
///   and notifies the registered closed handlers (dismiss fullscreen UI).
@MainActor
@Observable
final class PipSession: NSObject {
    static let shared = PipSession()

    struct Context {
        let itemId: String
        let serverURL: URL
        let token: String
        let userId: String
        let playSessionId: String?
        /// Everything a fresh fullscreen player needs to take playback back
        /// after the original one was dismissed (root-level restore).
        var streamURL: URL?
        var title: String = ""
        var mediaStreams: [MediaStream] = []
    }

    /// Restore target captured when the system asks for the UI back.
    struct RestoreRequest {
        let context: Context
        let position: Double
    }

    /// Resume fullscreen playback at `position`. Returns false when no owner
    /// can take over — the system then abandons the restore.
    ///
    /// Handlers are kept OUTSIDE any single view model: the live player
    /// registers while it is on screen and unregisters on disappear; the ROOT
    /// view keeps a permanent one that re-presents the player. Losing the
    /// closure used to kill the PiP window as soon as the cover was dismissed.
    private var restoreHandlers: [(id: UUID, priority: Int, handler: (Double) -> Bool)] = []
    private var closedHandlers: [(id: UUID, handler: () -> Void)] = []

    /// Priority of the LIVE player's restore handler — always above the root's.
    static let liveHandlerPriority = 10

    /// Registers a restore owner. Returns an id for `removeRestoreHandler`.
    ///
    /// Ownership is decided by **priority**, not registration order: with the
    /// old LIFO walk, root re-registering in `onAppear` moved it to the front
    /// of the reversed list and a second fullscreen player could be stacked on
    /// top of a live one.
    func addRestoreHandler(priority: Int = 0, _ handler: @escaping (Double) -> Bool) -> UUID {
        let id = UUID()
        restoreHandlers.append((id, priority, handler))
        return id
    }

    func removeRestoreHandler(_ id: UUID) {
        restoreHandlers.removeAll { $0.id == id }
    }

    /// Registers a "user closed the floating window" observer (all run).
    func addClosedHandler(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        closedHandlers.append((id, handler))
        return id
    }

    func removeClosedHandler(_ id: UUID) {
        closedHandlers.removeAll { $0.id == id }
    }

    private func claimRestore(at position: Double) -> Bool {
        // Highest priority first (LIFO inside a tier), so the live player beats
        // the root no matter who registered last.
        guard let top = restoreHandlers.map(\.priority).max() else { return false }
        for entry in restoreHandlers.reversed() where entry.priority == top {
            if entry.handler(position) { return true }
        }
        return false
    }

    private func notifyClosed() {
        for entry in closedHandlers { entry.handler() }
    }

    /// Set while the system requests the UI back — lets the restore owner
    /// rebuild the fullscreen player (stream, title, media streams).
    private(set) var restoreRequest: RestoreRequest?
    /// Set per start: AVPlayer's item reached `readyToPlay` — the caller
    /// should pause the primary player NOW (VLC kept the audio alive until
    /// this moment, so the handoff has no silence gap).
    var onVideoReady: (() -> Void)?
    /// Set per start: the handoff died AFTER the window opened (HLS item
    /// failed, session killed). Without this the owner's `pipState` stayed
    /// `.active` forever — PiP could never start again for that player and a
    /// view-exit handoff would stop VLC with NO stop report (lost progress).
    var onAborted: (() -> Void)?

    /// The root view's layer host. `AVPictureInPictureController` only accepts
    /// a layer that already belongs to the view hierarchy when
    /// `startPictureInPicture()` is called, and SwiftUI attaches it on the NEXT
    /// render (~16 ms later) — so `start` attaches synchronously through this
    /// reference instead of waiting for `updateUIView`.
    weak var hostView: UIView?

    private(set) var isActive = false
    private(set) var activeItemId: String?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var context: Context?
    private var position: Double = 0
    private var timeObserver: Any?
    private var readyObserver: NSKeyValueObservation?
    private var lastProgressReport = Date.distantPast
    private var startTimeoutWork: DispatchWorkItem?
    private var readyWatchdogWork: DispatchWorkItem?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    /// Keeps the process alive from the system call until the handoff is
    /// complete (window confirmed + item playing): ending the PlayerView's
    /// task at `didStart` left the HLS load unprotected when VLC was not the
    /// component producing audio, and iOS suspending us there is a black tile.
    private var handoffBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var didStartFlag = false
    /// Item reached `readyToPlay` and the handoff seek finished — together
    /// with `didStartFlag` these gate `maybeHandoffOver()`.
    private var itemReadyFlag = false
    private var seekDoneFlag = false
    private var restoreRequested = false
    private var programmaticStop = false
    private var reporter = JellyfinPlaybackReporter()

    /// Layer to embed in the fullscreen player's view hierarchy while active.
    var currentLayer: AVPlayerLayer? { playerLayer }

    // MARK: - Lifecycle

    /// Hand playback over to AVPlayer and open the floating window.
    ///
    /// The system window opens **immediately** — the HLS handoff (manifest +
    /// transcode + buffer) fills it in as soon as it is ready, and
    /// `onVideoReady` tells the caller when to pause the primary player.
    /// Returns true only when the system PiP window actually started.
    func start(
        hlsURL: URL,
        position: Double,
        context: Context,
        preload: PipPreload? = nil,
        onVideoReady: (() -> Void)? = nil,
        onAborted: (() -> Void)? = nil
    ) async -> Bool {
        guard !isActive else { return false }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            TJFLog("pip: not supported on this device")
            return false
        }
        beginHandoffBackgroundTask()

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
        self.onVideoReady = onVideoReady
        self.onAborted = onAborted
        self.reporter.playSessionId = context.playSessionId
        self.didStartFlag = false
        self.itemReadyFlag = false
        self.seekDoneFlag = false
        self.restoreRequested = false
        self.programmaticStop = false
        self.lastProgressReport = Date()

        // A pipeline preloaded during fullscreen playback (same URL) is
        // adopted as-is: its item is already ready, so the system reports
        // `isPictureInPicturePossible == true` IMMEDIATELY and the window
        // opens without waiting for a cold HLS load.
        let adopted = ((preload?.matches(url: hlsURL)) ?? false) ? preload?.adopt() : nil
        let avPlayer: AVPlayer
        let layer: AVPlayerLayer
        if let adopted {
            avPlayer = adopted.player
            layer = adopted.layer
            TJFLog("pip: adopted preloaded pipeline status=\(avPlayer.currentItem?.status.rawValue ?? -1) tcs=\(avPlayer.timeControlStatus.rawValue)")
        } else {
            let item = AVPlayerItem(url: hlsURL)
            // Bias toward a fast first frame — PiP prefers startup latency over
            // a deep buffer (HLS segments are ~3s anyway).
            item.preferredForwardBufferDuration = 4
            let fresh = AVPlayer(playerItem: item)
            fresh.automaticallyWaitsToMinimizeStalling = true
            avPlayer = fresh
            layer = AVPlayerLayer(player: fresh)
            layer.videoGravity = .resizeAspect
        }
        // Muted until the system confirms the window (`maybeHandoffOver`
        // unmutes): an adopted player may still be running from the preload,
        // and hearing it before the window exists would double with VLC.
        avPlayer.isMuted = true
        self.player = avPlayer
        self.playerLayer = layer
        // Attach NOW, not on the next SwiftUI render: starting PiP with
        // `layer.superlayer == nil` is what turned into "window never appears
        // → 8s watchdog → ghost audio" on device.
        attachLayerToHost()

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

        // Observe the item: on ready → caller pauses VLC, we seek to the
        // handoff position and start playing. On failure → cancel the whole
        // handoff (VLC was never paused, playback continues seamlessly).
        readyObserver = avPlayer.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatus(avPlayer)
            }
        }

        isActive = true
        TJFLog("pip: starting at \(String(format: "%.1f", position))s url=\(hlsURL.absoluteString)")
        if adopted != nil {
            // The preload can have gone ready BEFORE this KVO observer was
            // registered (`.new` never fires for a status that won't change):
            // kick the ready → seek → handoff chain once, then keep the
            // pipeline silently re-buffering (muted) while we wait for the
            // system to consider the controller possible.
            handleItemStatus(avPlayer)
            avPlayer.play()
        }

        // `startPictureInPicture()` is a SILENT NO-OP while
        // `isPictureInPicturePossible == false`: no error, no delegate call,
        // no retry. On device (cold HLS) `possible` only flips true seconds
        // later, when the item becomes ready — device log evidence:
        // "possible=false waited=1500ms" → call → "didStart never arrived
        // (possible=true)" → no window. The foreground button works because
        // there `possible` turns true within the old 1.5s budget. So WAIT for
        // the system's own readiness signal — up to 15s, covered by the
        // handoff background lease — and only then start, exactly like the
        // button does. Caller cancellation still wins instantly: the user
        // returning to the app aborts this wait.
        var waitedMs = 0
        while !pip.isPictureInPicturePossible, isActive, !Task.isCancelled, waitedMs < 15_000 {
            if waitedMs > 0, waitedMs % 2_000 == 0 {
                TJFLog("pip: waiting for isPictureInPicturePossible… \(waitedMs)ms state=\(UIApplication.shared.applicationState.rawValue)")
            }
            try? await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
        }
        // The session can be torn down while we wait (user closed it): no
        // continuation exists yet, so proceeding would hang `start()` forever.
        guard isActive else {
            TJFLog("pip: start aborted while waiting for isPictureInPicturePossible")
            return false
        }
        // The caller gave up (user came back to the app, view gone): opening
        // the window NOW would pop it over the fullscreen player.
        guard !Task.isCancelled else {
            TJFLog("pip: start cancelled by caller → aborting")
            cleanup()
            return false
        }
        TJFLog("pip: system possible=\(pip.isPictureInPicturePossible) waited=\(waitedMs)ms state=\(UIApplication.shared.applicationState.rawValue) layer=\(String(describing: layer.frame.size))")

        let started: Bool = await withCheckedContinuation { continuation in
            self.startContinuation = continuation

            // If the system never confirms the window (broken PiP, …) cancel
            // and let the caller fall back to VLC background audio.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.didStartFlag else { return }
                TJFLog("pip: didStart never arrived → cancelling (possible=\(self.pipController?.isPictureInPicturePossible ?? false))")
                self.pipController?.stopPictureInPicture()
                self.cleanup()
                self.resumeStart(false)
            }
            self.startTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)

            // Evidence: a window that opened but whose HLS item never became
            // ready (black/frozen tile) must still say so in the log. Stored
            // so `cleanup()` can cancel it (a restart inside 12s would
            // otherwise log a false alarm about the NEW session).
            let readyWatchdog = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, !self.itemReadyFlag else { return }
                TJFLog("pip: window up but item NOT ready after 12s — status=\(self.player?.currentItem?.status.rawValue ?? -1) tcs=\(self.player?.timeControlStatus.rawValue ?? -1)")
            }
            self.readyWatchdogWork = readyWatchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: readyWatchdog)

            // Open the floating window NOW — do not gate it on the HLS
            // handoff (manifest + transcode spin-up can take seconds).
            pip.startPictureInPicture()
        }

        TJFLog("pip: start result=\(started)")
        return started
    }

    /// Item KVO: `.readyToPlay` hands audio over; `.failed` cancels.
    private func handleItemStatus(_ avPlayer: AVPlayer) {
        guard isActive, let item = avPlayer.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            readyObserver?.invalidate()
            readyObserver = nil
            itemReadyFlag = true
            TJFLog("pip: item ready (window started=\(didStartFlag))")
            let target = CMTime(seconds: position, preferredTimescale: 600)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    guard self.isActive else { return }
                    self.seekDoneFlag = true
                    self.maybeHandoffOver()
                }
            }
        case .failed:
            TJFLog("pip: item failed: \(item.error?.localizedDescription ?? "unknown")")
            readyObserver?.invalidate()
            readyObserver = nil
            itemReadyFlag = false
            seekDoneFlag = false
            onVideoReady = nil
            programmaticStop = true
            pipController?.stopPictureInPicture()
            // Notify BEFORE cleanup clears it: the owner must roll back its
            // pipState (and save progress when it already left the screen).
            let aborted = onAborted
            cleanup()
            aborted?()
            resumeStart(false)
        default:
            // `.unknown` while the cold transcode spins up: the pipeline used
            // to go silent after "starting at …", so a stalled handoff looked
            // exactly like a healthy one in the log.
            TJFLog("pip: item not ready yet — status=.unknown transcode/buffering")
            break
        }
    }

    /// Hand audio over to AVPlayer **only once the system window exists**.
    ///
    /// Freezing the fullscreen player on item-ready alone is what produced the
    /// "blocked image": VLC paused (and the AVPlayer seeking) for a window that
    /// then failed to open, leaving a frozen picture while playback state was
    /// already handed to nobody.
    private func maybeHandoffOver() {
        guard isActive, itemReadyFlag, seekDoneFlag, didStartFlag else { return }
        // Capture + clear first: a nil callback must not keep the window from
        // playing (the window is proven at this point either way).
        let notify = onVideoReady
        onVideoReady = nil
        TJFLog("pip: window confirmed + item ready → handing audio over")
        notify?()
        if let player {
            // Preloaded pipelines run MUTED until this exact moment — from
            // here the AVPlayer is the audible source of the session.
            player.isMuted = false
            if player.timeControlStatus != .playing {
                player.play()
            }
        }
        // AVPlayer now carries the audio: the background lease is not needed
        // anymore (the audio session keeps the process alive from here).
        endHandoffBackgroundTask()
    }

    /// Lease that keeps iOS from suspending us between the system PiP call and
    /// a playing AVPlayer. Released the moment playback is really carried, or
    /// when the session dies — never left dangling (iOS terminates the app for
    /// un-ended background tasks).
    private func beginHandoffBackgroundTask() {
        guard handoffBackgroundTask == .invalid else { return }
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "tjf.pipSession") {
            TJFLog("pip: handoff background time expired → releasing lease")
            self.handoffBackgroundTask = .invalid
            if task != .invalid {
                app.endBackgroundTask(task)
                task = .invalid
            }
        }
        handoffBackgroundTask = task
    }

    private func endHandoffBackgroundTask() {
        guard handoffBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffBackgroundTask)
        handoffBackgroundTask = .invalid
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
        readyWatchdogWork?.cancel()
        readyWatchdogWork = nil
        endHandoffBackgroundTask()
        readyObserver?.invalidate()
        readyObserver = nil
        onVideoReady = nil
        onAborted = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        // Detach explicitly: the host view outlives the session, and a layer
        // left behind it would keep painting (a black box) over Home.
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        pipController?.delegate = nil
        pipController = nil
        isActive = false
        activeItemId = nil
        context = nil
        restoreRequest = nil
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
        // Monotonic: an ADOPTED preloaded player starts at its old (lower)
        // clock until the handoff seek lands — taking that value here would
        // let a progress report send a LOWER position than we already know
        // (and the server stores whatever it is told).
        if seconds.isFinite, seconds > 0, seconds >= position - 0.5 {
            position = seconds
        }
        guard let context, Date().timeIntervalSince(lastProgressReport) >= 10 else { return }
        lastProgressReport = Date()
        let ticks = Int64(position * 10_000_000)
        // PositionTicks:0 erases the saved resume server-side (the client now
        // guards this too, but skip here so the skip is visible in the log).
        guard ticks > 0 else {
            TJFLog("pip: progress SKIPPED (position 0 — preserves saved resume)")
            return
        }
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
        // Same rule as the view model: PositionTicks:0 makes Jellyfin DROP the
        // resume entry. An auto-handoff right after play starts can stop at 0,
        // and that one report erased the whole episode's progress.
        guard ticks > 0 else {
            TJFLog("pip: reportStopped SKIPPED (position 0 — preserves saved resume)")
            return
        }
        let reporter = self.reporter
        Task {
            await reporter.reportStopped(
                userId: context.userId, serverURL: context.serverURL, token: context.token,
                itemId: context.itemId, mediaSourceId: context.itemId,
                positionTicks: ticks
            )
        }
    }

    /// Put `playerLayer` into the root host's hierarchy right now — see
    /// `hostView`.
    private func attachLayerToHost() {
        guard let layer = playerLayer else { return }
        guard let host = hostView else {
            // Should be impossible (the host lives for the whole app), but a
            // silent no-op here is exactly the "window never appears" bug —
            // fail loudly instead.
            TJFLog("pip: FATAL — no layer host registered, startPictureInPicture will likely fail")
            return
        }
        guard layer.superlayer !== host.layer else { return }
        layer.removeFromSuperlayer()
        layer.frame = host.bounds
        host.layer.addSublayer(layer)
        // A zero-sized host = a window that can never render anything.
        TJFLog("pip: layer attached to root host bounds=\(host.bounds)")
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
        // If the item was already ready and seeked, THIS is the moment the
        // fullscreen player may freeze (window + content both proven).
        maybeHandoffOver()
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
        TJFLog("pip: restore requested at \(String(format: "%.1f", target))s handlers=\(restoreHandlers.count)")
        player?.pause()

        // Snapshot what a fresh fullscreen player needs BEFORE any handler can
        // tear the session down.
        if let context {
            restoreRequest = RestoreRequest(context: context, position: target)
        }

        if claimRestore(at: target) {
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
        notifyClosed()
    }
}
#endif
