#if os(iOS)
import AVFoundation
import AVKit
import Observation
import ThisJellyFixCore
import ThisJellyFixPlayback
import UIKit

/// Everything the root view needs to rebuild the fullscreen player for a
/// floating PiP window whose original view is already gone.
struct PipContext {
    let itemId: String
    let serverURL: URL
    let token: String
    let userId: String
    let playSessionId: String?
    let streamURL: URL
    let title: String
    let mediaStreams: [MediaStream]
}

/// Native picture-in-picture orchestration.
///
/// Replaces `PipSession` + `PipPreload` (the VLC→AVPlayer handoff with its
/// HLS pre-resolve, muted preload player, freeze/unfreeze and background
/// watchdogs). There is now ONE AVPlayer: `AVPlaybackEngine.playerLayer` is
/// handed to `AVPictureInPictureController`, and the system starts/stops the
/// window itself (`canStartPictureInPictureAutomaticallyFromInline`).
///
/// The only real job left is lifetime: the fullscreen view model must keep
/// living (progress reporting!) while its view is gone and the window floats.
/// The view model is retained here until restore (re-presented by the root)
/// or close (stopped + reported once).
///
/// `@Observable` so the root's `PipLayerHostView(isActive:)` re-renders when a
/// session floats (the layer must be embedded the render it becomes active).
@MainActor
@Observable
final class PipCoordinator: NSObject {
    static let shared = PipCoordinator()

    /// Root's always-alive layer host — the floating layer lives here once
    /// the fullscreen player view is dismissed. (Not observable: it never
    /// changes while the host exists.)
    @ObservationIgnored
    weak var hostView: UIView?

    /// Engine whose layer feeds the window (configured once per engine).
    private var controller: AVPictureInPictureController?
    private var configuredEngine: AVPlaybackEngine?

    /// Retained while floating: owns the engine, the timer and reporting.
    private(set) var floatingVM: PlayerViewModel?
    private(set) var floatingContext: PipContext?

    /// The on-screen player (set while its view is attached).
    @ObservationIgnored
    weak var liveVM: PlayerViewModel?

    /// The system window is up (or about to be — delegate lags the call).
    private(set) var windowStarted = false

    private var autoStartEnabled = true
    private var restoring = false
    private var programmaticStop = false

    private var restoreHandlers: [UUID: (Double) -> Bool] = [:]
    private var closedHandlers: [UUID: () -> Void] = [:]

    var isFloating: Bool { floatingVM != nil }
    var isActive: Bool { windowStarted || isFloating }
    var isWindowActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Layer the root host should embed while floating.
    var currentLayer: CALayer? { floatingVM?.engine.renderingLayer }

    static let liveHandlerPriority: Int = 100

    // MARK: - Configuration

    /// Create the controller for the engine's layer. Idempotent.
    func configure(engine: AVPlaybackEngine) {
        guard configuredEngine !== engine else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            TJFLog("pip: not supported on this device")
            return
        }
        let controller = AVPictureInPictureController(
            contentSource: .init(playerLayer: engine.playerLayer)
        )
        controller.canStartPictureInPictureAutomaticallyFromInline = autoStartEnabled
        controller.delegate = self
        self.controller = controller
        configuredEngine = engine
        TJFLog("pip: configured (autoStart=\(autoStartEnabled))")
    }

    /// Gate the system auto-start on the handoff policy: a player the user
    /// paused (or one with an error) must not float itself away on background.
    /// Read by iOS at the background transition, so updating it on every
    /// policy change is enough.
    func setAutoStartEnabled(_ enabled: Bool) {
        autoStartEnabled = enabled
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    // MARK: - Start / stop

    /// Manual start (controls button) or safety-net start after background.
    func start() {
        guard let controller else {
            TJFLog("pip: start refused — no controller")
            return
        }
        guard controller.isPictureInPicturePossible else {
            TJFLog("pip: start refused — not possible (playing=\(liveVM?.isPlaying ?? false))")
            return
        }
        guard !controller.isPictureInPictureActive else { return }
        TJFLog("pip: startPictureInPicture")
        controller.startPictureInPicture()
    }

    /// Programmatic stop (user returned to the app / new playback starting).
    /// `didStop` skips its close logic for this one.
    func stop() {
        guard controller?.isPictureInPictureActive == true else { return }
        TJFLog("pip: programmatic stop")
        programmaticStop = true
        controller?.stopPictureInPicture()
    }

    // MARK: - Floating (fullscreen view gone)

    /// Take ownership of `vm` for the floating window: pin its layer into the
    /// root host and open the window if it isn't already open.
    /// The VM keeps its timer running — progress reporting must not pause
    /// just because the cover was dismissed.
    /// - Returns: true when the session is floating (window active or start
    ///   issued); false → caller must stop playback itself.
    func float(_ vm: PlayerViewModel) -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let ctx = vm.makePipContext()
        else {
            TJFLog("pip: float refused — supported=false ctx=\(vm.makePipContext() != nil)")
            return false
        }
        guard controller != nil else { return false }

        attachLayerToHost(vm.engine)
        floatingVM = vm
        floatingContext = ctx

        if controller?.isPictureInPictureActive == true {
            TJFLog("pip: float with window already active item=\(ctx.itemId)")
            windowStarted = true
            return true
        }
        TJFLog("pip: float → start window item=\(ctx.itemId) pos=\(String(format: "%.1f", vm.currentTime))s")
        start()
        return true
    }

    /// Drop the floating session WITHOUT stopping playback — the fullscreen
    /// view took the item back (its view re-hosts the layer).
    func releaseFloating() {
        guard isFloating else { return }
        TJFLog("pip: floating session released to fullscreen")
        floatingVM = nil
        floatingContext = nil
        windowStarted = false
    }

    /// Close the floating session AND stop its playback with a stop report.
    /// Called when a new fullscreen playback starts over it (never two live
    /// sessions for the same/other item) — programmatic: no closed handlers.
    func closeFloating() {
        guard let vm = floatingVM else { return }
        TJFLog("pip: closing floating session item=\(floatingContext?.itemId ?? "nil")")
        floatingVM = nil
        floatingContext = nil
        windowStarted = false
        programmaticStop = true
        controller?.stopPictureInPicture()
        vm.stopSync(reportStop: true)
        detachLayerFromHost()
    }

    // MARK: - Root layer host

    /// Pin `engine`'s layer into the root's always-alive host view so the
    /// system window keeps a layer inside the window hierarchy. Synchronous:
    /// the host registers itself at app start, so it exists by now.
    private func attachLayerToHost(_ engine: AVPlaybackEngine) {
        let layer = engine.renderingLayer
        guard let host = hostView, let layer else { return }
        if layer.superlayer !== host.layer {
            layer.removeFromSuperlayer()
            layer.frame = host.bounds
            host.layer.addSublayer(layer)
        }
    }

    /// Detach a floating layer nobody hosts anymore (session ended without a
    /// fullscreen view taking it back). No-op when the bridge already moved it.
    private func detachLayerFromHost() {
        guard let host = hostView else { return }
        // The root host only ever embeds the player's AVPlayerLayer.
        host.layer.sublayers?.forEach { sub in
            if sub is AVPlayerLayer { sub.removeFromSuperlayer() }
        }
    }

    // MARK: - Handler registry (root view)

    /// - Parameter handler: receives the position, returns true when it took
    ///   the restore (re-presented fullscreen UI).
    @discardableResult
    func addRestoreHandler(_ handler: @escaping (Double) -> Bool) -> UUID {
        let id = UUID()
        restoreHandlers[id] = handler
        return id
    }

    func removeRestoreHandler(_ id: UUID) {
        restoreHandlers[id] = nil
    }

    func addClosedHandler(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        closedHandlers[id] = handler
        return id
    }

    func removeClosedHandler(_ id: UUID) {
        closedHandlers[id] = nil
    }

    @discardableResult
    private func fireRestore(at position: Double) -> Bool {
        // Highest priority first so the live player (when registered) wins
        // over the root's re-present path.
        let ordered = restoreHandlers.sorted { lhs, rhs in
            // Stable order by insertion is not tracked; the live handler is
            // the only one that registers dynamically and claims via its own
            // guard — evaluate all until one takes it.
            lhs.key.uuidString < rhs.key.uuidString
        }
        for (_, handler) in ordered where handler(position) {
            return true
        }
        return false
    }

    private func fireClosed() {
        for handler in closedHandlers.values {
            handler()
        }
    }

    /// Last known position of the floating item (for restore presentation).
    var floatingPosition: Double { floatingVM?.currentTime ?? 0 }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        windowStarted = true
        TJFLog("pip: window started")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        TJFLog("pip: failed to start — \(error.localizedDescription)")
        if let vm = floatingVM {
            // The view already left: nothing is playing now. Stop WITH report
            // so the episode's progress is not lost (old watchdog path).
            releaseFloating()
            vm.stopSync(reportStop: true)
            detachLayerFromHost()
            fireClosed()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // NOTE: the ObjC block is `void (^)(BOOL restored)` — declaring this
        // parameter as `() -> Void` fails the optional requirement ("nearly
        // matches" warning) and the system never calls it: the window just
        // closed and didStop treated it as a user-close (episode killed).
        restoring = true
        if isFloating {
            let position = floatingPosition
            TJFLog("pip: restore requested at \(String(format: "%.1f", position))s")
            if fireRestore(at: position) {
                completionHandler(true)
                return
            }
            // Nobody could take playback back (another player owns the
            // screen): close instead — a refused restore must not leave a
            // window with nothing behind it.
            TJFLog("pip: restore refused by all handlers → closing")
            let vm = floatingVM
            releaseFloating()
            vm?.stopSync(reportStop: true)
            detachLayerFromHost()
            fireClosed()
            completionHandler(false)
            return
        }
        // Fullscreen view already on screen (inline PiP): nothing to rebuild.
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        windowStarted = false
        if restoring {
            restoring = false
            TJFLog("pip: stopped after restore")
            return
        }
        if programmaticStop {
            programmaticStop = false
            TJFLog("pip: stopped programmatically")
            return
        }
        if let vm = floatingVM {
            // User closed the FLOATING window → playback ended.
            TJFLog("pip: floating window closed by user")
            releaseFloating()
            vm.stopSync(reportStop: true)
            detachLayerFromHost()
            fireClosed()
        } else if let vm = liveVM {
            // User closed PiP while the fullscreen view is on screen →
            // ended playback, dismiss fullscreen (old live-handler behavior).
            TJFLog("pip: window closed by user (live view)")
            vm.stopSync(reportStop: true)
            vm.onPiPClosed?()
        }
    }
}
#endif
