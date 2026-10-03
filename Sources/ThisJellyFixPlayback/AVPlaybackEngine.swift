import AVFoundation
import Foundation
import ThisJellyFixCore

/// AVPlayer-based playback engine — the ONLY engine post-VLCKit.
///
/// One AVPlayer + one AVPlayerLayer for the whole app session: `prepare`
/// swaps the item in place, so episode swaps, PiP and the view's hosting
/// layer all share the same instances (the old VLC→AVPlayer handoff, its
/// preload pipeline and watchdogs are gone).
///
/// Hybrid subtitles:
/// - embedded (mov_text/tx3g/webvtt) → `AVMediaSelection` legible group,
///   rendered natively by AVPlayerLayer (Apple: "Selecting a subtitle …
///   displays the associated text within … AVPlayerLayer").
/// - external SRT → owned by the view model (parse + SwiftUI overlay).
/// - ASS/PGS → burned in server-side (device profile `Encode`).
public final class AVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    /// Shared with the view's hosting layer and the PiP controller.
    public let player: AVPlayer
    public let playerLayer: AVPlayerLayer

    /// Fired on the main actor (VM is @MainActor and subscribes directly).
    public var onStateChanged: ((PlaybackEngineState) -> Void)?

    // MARK: Media selection (embedded tracks)

    private let stateLock = NSLock()
    private var _audioOptions: [AVMediaSelectionOption] = []
    private var _subtitleOptions: [AVMediaSelectionOption] = []
    private var _videoSize: CGSize = .zero
    private var _duration: Double = 0
    private var desiredRate: Float = 1.0

    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    /// The VM's legible choice (-1 = off/external-overlay). Re-asserted when
    /// the item becomes ready: AVPlayerItem can preselect its own default
    /// legible option AFTER our first explicit deselect — that race is what
    /// drew native subs alongside the external-SRT overlay.
    private var desiredSubtitleIndex: Int?
    /// Bumped on every `prepare` — async track loads from a previous item
    /// must not populate the new item's lists.
    private var generation = 0

    public init() {
        player = AVPlayer()
        // Selection is 100% explicit (VM calls selectSubtitleTrack). Left at
        // the default YES, AVPlayer re-enables subtitles per the DEVICE's
        // preferred-language preferences as soon as the item becomes ready —
        // right after our deselect — which is what drew native subs alongside
        // the external-SRT overlay (the "duplicated subtitles" bug).
        player.appliesMediaSelectionCriteriaAutomatically = false
        #if !os(visionOS)
        // AirPlay: video routing to Apple TV / AirPlay receivers. Default is
        // true, set explicitly so nobody "optimizes" it away.
        // (API unavailable on visionOS.)
        player.allowsExternalPlayback = true
        #endif
        playerLayer = AVPlayerLayer(player: player)
        // Fit by default; VM applies the persisted fit/fill right after prepare.
        playerLayer.videoGravity = .resizeAspect
        observePlayer()
    }

    deinit {
        itemObservations.forEach { $0.invalidate() }
        playerObservations.forEach { $0.invalidate() }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - PlaybackEngine

    public func prepare(_ request: PlaybackRequest) async throws {
        generation += 1
        let gen = generation

        clearItemObservations()
        // New item → the previous legible choice doesn't apply (option indices
        // belong to the old asset). VM re-selects after loadTracks.
        withStateLock { desiredSubtitleIndex = nil }
        notify(.loading)

        let item = AVPlayerItem(url: request.streamURL)
        // Keep the previous frame until the new one decodes — no black flash
        // on episode swap.
        item.preferredForwardBufferDuration = 5

        observe(item: item, generation: gen)
        player.replaceCurrentItem(with: item)

        // Fresh asset from the URL: `item.asset` is main-actor isolated in
        // newer SDKs and this method is not.
        await loadTracks(asset: AVURLAsset(url: request.streamURL), generation: gen)
    }

    public func play() {
        player.rate = desiredRate
        notify(.playing)
    }

    public func pause() {
        player.pause()
        notify(.paused)
    }

    public func stop() {
        stopSync()
    }

    public func stopSync() {
        player.pause()
        clearItemObservations()
        generation += 1 // orphan any in-flight track load
        player.replaceCurrentItem(with: nil)
        stateLock.lock()
        _audioOptions = []
        _subtitleOptions = []
        _videoSize = .zero
        _duration = 0
        desiredSubtitleIndex = nil
        stateLock.unlock()
        notify(.idle)
    }

    public func seek(to seconds: Double) async {
        // No item yet: the completion handler may never fire for a nil item
        // (checked continuation would hang).
        guard player.currentItem != nil else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                cont.resume()
            }
        }
    }

    public func seekRelative(_ deltaSeconds: Double) async {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        await seek(to: current + deltaSeconds)
    }

    public func setPlaybackRate(_ rate: Float) {
        desiredRate = rate
        // Only touch the live rate while actually playing — a paused item
        // would start playing just because the user picked 1.5x.
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
    }

    public func setVideoFill(_ fill: Bool) {
        playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    // MARK: Track selection (embedded via AVMediaSelection)

    public var availableAudioTracks: [AudioTrack] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _audioOptions.enumerated().map { idx, option in
            AudioTrack(
                id: idx,
                name: option.displayName,
                language: Self.languageCode(of: option),
                languageName: nil
            )
        }
    }

    public var availableSubtitleTracks: [SubtitleTrack] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _subtitleOptions.enumerated().map { idx, option in
            SubtitleTrack(
                id: idx,
                name: option.displayName,
                language: Self.languageCode(of: option),
                languageName: nil,
                isExternal: false
            )
        }
    }

    public func selectAudioTrack(index: Int) async {
        guard let group = audioGroup else { return }
        let options = withStateLock { _audioOptions }
        guard index >= 0, index < options.count else { return }
        player.currentItem?.select(options[index], in: group)
    }

    public func selectSubtitleTrack(index: Int) async {
        withStateLock { desiredSubtitleIndex = index }
        applySubtitleSelectionNow()
    }

    /// Apply `desiredSubtitleIndex` to the CURRENT item. `nil` desired with a
    /// legible group present → force off: nothing may render until the VM
    /// explicitly picks a track (kills the item-default flash).
    private func applySubtitleSelectionNow() {
        let desired = withStateLock { desiredSubtitleIndex }
        guard let group = withStateLock({ legibleGroup }) else {
            TJFLog("subtitles: apply skipped — no legible group desired=\(String(describing: desired))")
            return
        }
        guard let desired else {
            player.currentItem?.select(nil, in: group)
            return
        }
        if desired >= 0 {
            let options = withStateLock { _subtitleOptions }
            guard desired < options.count else {
                TJFLog("subtitles: desired[\(desired)] out of range (count \(options.count))")
                return
            }
            player.currentItem?.select(options[desired], in: group)
        } else {
            player.currentItem?.select(nil, in: group)
        }
        // Evidence: whatever the item may have preselected must be gone now.
        let current = player.currentItem?.currentMediaSelection
            .selectedMediaOption(in: group)
        TJFLog("subtitles: applied desired=\(desired) nativeNow=\(current?.displayName ?? "off")")
    }

    // MARK: State accessors

    public var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite && t >= 0 ? t : 0
    }

    public var duration: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _duration
    }

    public var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    public var videoSize: CGSize {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _videoSize
    }

    public var renderingLayer: CALayer? { playerLayer }

    // MARK: - Private

    private func observePlayer() {
        playerObservations.append(
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                // Buffering while rate > 0: surface it so the UI can show the
                // spinner instead of a frozen frame with no explanation.
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                   self.player.rate > 0 {
                    self.notify(.buffering)
                }
            }
        )
    }

    private func observe(item: AVPlayerItem, generation gen: Int) {
        itemObservations.append(
            item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
                guard let self else { return }
                // A previous item's callback must not speak for the new one.
                guard self.generation == gen, observedItem === self.player.currentItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let d = observedItem.duration.seconds
                    if d.isFinite, d > 0 {
                        self.stateLock.lock()
                        self._duration = d
                        self.stateLock.unlock()
                    }
                    let size = observedItem.presentationSize
                    if size.width > 0, size.height > 0 {
                        self.stateLock.lock()
                        self._videoSize = size
                        self.stateLock.unlock()
                    }
                    // Re-assert the VM's legible choice AFTER the item's own
                    // default selection has landed (duplicated-subs guard).
                    self.applySubtitleSelectionNow()
                    self.notify(.ready)
                case .failed:
                    let message = observedItem.error?.localizedDescription
                        ?? "El formato no puede reproducirse en este dispositivo."
                    TJFLog("AVPlayer item failed: \(message ?? "?")")
                    self.notify(.failed(message ?? "La reproducción ha fallado."))
                default:
                    break
                }
            }
        )

        // Natural end — real signal, replaces VLC's `duration - 1.5` guess.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.notify(.ended)
        }

        // presentationSize lands on the first decoded frame (KVO-able).
        itemObservations.append(
            item.observe(\.presentationSize, options: [.new]) { [weak self] observedItem, _ in
                guard let self, self.generation == gen else { return }
                let size = observedItem.presentationSize
                guard size.width > 0, size.height > 0 else { return }
                self.stateLock.lock()
                self._videoSize = size
                self.stateLock.unlock()
            }
        )
    }

    /// Load media selection groups (embedded audio/subtitle tracks) for the
    /// fresh item. Runs inside `prepare` — by the time the VM asks, the lists
    /// are there (no VLC-style 10-60s lazy track discovery).
    private func loadTracks(asset: AVURLAsset, generation gen: Int) async {
        do {
            let audible = try await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try await asset.loadMediaSelectionGroup(for: .legible)
            guard generation == gen else {
                TJFLog("tracks: stale load dropped (gen \(gen) != \(generation))")
                return
            }
            let counts = withStateLock { () -> (Int, Int) in
                audioGroup = audible
                legibleGroup = legible
                _audioOptions = audible?.options ?? []
                _subtitleOptions = legible?.options ?? []
                return (_audioOptions.count, _subtitleOptions.count)
            }
            TJFLog("tracks loaded audio=\(counts.0) subs=\(counts.1)")
            // Groups just landed: apply (or force-clear) the legible choice
            // against THIS item, mirroring the re-assert done at .ready.
            applySubtitleSelectionNow()
        } catch {
            TJFLog("tracks load failed: \(error)")
        }
    }

    /// Scoped locking helper — `NSLock.lock()` directly from an `async`
    /// context is rejected (Swift 6 error, warning today).
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func clearItemObservations() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func notify(_ state: PlaybackEngineState) {
        // KVO can fire on any thread; the VM is @MainActor.
        if Thread.isMainThread {
            onStateChanged?(state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStateChanged?(state)
            }
        }
    }

    private static func languageCode(of option: AVMediaSelectionOption) -> String? {
        option.extendedLanguageTag ?? option.locale?.identifier
    }
}
