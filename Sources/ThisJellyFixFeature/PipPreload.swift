import AVFoundation
import AVKit
import ThisJellyFixCore

/// Pre-loads the PiP pipeline **while the user is still watching fullscreen**,
/// so leaving the app can open the floating window immediately.
///
/// Why this exists: the system refuses `startPictureInPicture()` until
/// `isPictureInPicturePossible == true`, and with a freshly created AVPlayer
/// that only happens once the HLS item is ready — seconds warm, ~10s cold.
/// Waiting for that *after* the swipe-up is exactly the reported behaviour:
/// "salgo de la app y solo sigue el audio".
///
/// So two seconds into playback (the trigger the old HTTP warm used) the real
/// pipeline is created: muted `AVPlayer` + layer + the same HLS URL the
/// handoff will use. When the item is ready the player is **paused** — the
/// buffer is retained, no second audio is heard, and no transcode is drained
/// while the user watches. Device logs prove `isPictureInPicturePossible`
/// holds while paused (it went true with a player that had never played).
///
/// At handoff, `PipSession` adopts this player: `possible` is already true →
/// the window opens at once; audio is unmuted only once the system confirms
/// the window (`maybeHandoffOver`).
@MainActor
final class PipPreload {
    /// The pipeline handed over to a starting session (that session owns it).
    struct Adopted {
        let player: AVPlayer
        let layer: AVPlayerLayer
    }

    private var url: URL?
    private var player: AVPlayer?
    private var layer: AVPlayerLayer?
    private var statusObserver: NSKeyValueObservation?
    /// A session is using the pipeline right now. Ownership is NOT
    /// transferred (old `adopt()` did, and an aborted start destroyed the
    /// preload — the NEXT handoff then had to load cold: device log attempt
    /// 2). The session pauses it on cleanup; the preload just must not
    /// interfere while it is in use.
    private var borrowed = false

    /// Starts loading `url`, muted. Returns false when PiP preparation can't
    /// run here — the caller then falls back to the plain HTTP warm.
    func begin(url: URL) -> Bool {
        // Already loading/loaded this very stream → nothing to do.
        if self.url == url, player != nil { return true }
        reset()
        borrowed = false
        #if os(iOS)
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4
        let preloaded = AVPlayer(playerItem: item)
        preloaded.automaticallyWaitsToMinimizeStalling = true
        // Muted: a second audio source over VLC must never be heard, and it
        // also lets us keep the pipeline running silently during the handoff.
        preloaded.isMuted = true
        let preloadedLayer = AVPlayerLayer(player: preloaded)
        preloadedLayer.videoGravity = .resizeAspect

        self.url = url
        self.player = preloaded
        self.layer = preloadedLayer
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged() }
        }
        preloaded.play()
        TJFLog("pip: preload started (muted) url=\(url.absoluteString.prefix(90))")
        return true
        #else
        return false
        #endif
    }

    private func statusChanged() {
        guard let player, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            statusObserver?.invalidate()
            statusObserver = nil
            if borrowed {
                // In use by a live session: pausing here would fight its
                // playback — the session owns pause/resume from now on.
                TJFLog("pip: preloaded item ready (in use by session)")
                return
            }
            player.pause()
            TJFLog("pip: preload ready → paused (window can open instantly)")
        case .failed:
            TJFLog("pip: preload failed — \(item.error?.localizedDescription ?? "unknown")")
            reset()
        default:
            break
        }
    }

    /// Whether this exact stream is loaded (or loading) and available.
    func matches(url: URL) -> Bool {
        self.url == url && player != nil
    }

    /// Hands the pipeline to a starting session WITHOUT giving up ownership:
    /// if the start is aborted, the next attempt re-borrows the very same
    /// (ready) player instead of loading cold from scratch.
    func borrow() -> Adopted? {
        guard let player, let layer else { return nil }
        borrowed = true
        return Adopted(player: player, layer: layer)
    }

    /// Drops everything (new item, teardown). Safe to call repeatedly.
    func reset() {
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        player = nil
        layer = nil
        url = nil
        borrowed = false
    }
}
