import Foundation
import MediaPlayer

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Lock screen / Control Center metadata (`MPNowPlayingInfoCenter`) plus
/// remote commands (lock screen, headphones, CarPlay-style controls).
///
/// Owned by the player view model: `activate` when a session starts,
/// `update` on the playback timer, `deactivate` when playback really stops.
/// Remote-command callbacks hop to the main actor before touching the VM.
public final class NowPlayingController: @unchecked Sendable {
    public static let shared = NowPlayingController()

    // MARK: Remote command handlers (set by the view model)

    public var onPlay: (@MainActor () -> Void)?
    public var onPause: (@MainActor () -> Void)?
    public var onTogglePlayPause: (@MainActor () -> Void)?
    public var onSkipBackward: (@MainActor () -> Void)?
    public var onSkipForward: (@MainActor () -> Void)?
    public var onSeek: (@MainActor (Double) -> Void)?

    private let commands = MPRemoteCommandCenter.shared()
    private var commandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var active = false
    /// Bumped on every `activate` — lets a STALE session deactivate without
    /// wiping a newer session's lock screen (dismiss/present ordering).
    private var sessionCounter = 0

    private init() {}

    // MARK: Lifecycle

    /// Publish "what is playing". Safe to call before duration is known —
    /// the timer refreshes elapsed/duration continuously. Returns the session
    /// token to pass to `deactivate(session:)`.
    @discardableResult
    public func activate(title: String, subtitle: String? = nil, duration: Double = 0) -> Int {
        sessionCounter += 1
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 0,
        ]
        if let subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        active = true
        enableCommands()
        return sessionCounter
    }

    /// Elapsed/duration/rate refresh — called from the playback timer.
    public func update(time: Double, duration: Double, rate: Float) {
        guard active else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate > 0 ? rate : Float(0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Fetch poster art for the lock screen (no-op on failure — text still shows).
    public func setArtworkURL(_ url: URL?) {
        #if canImport(UIKit)
        guard active, let url else { return }
        Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status), let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    guard let self, self.active else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            } catch {
                // Artwork is cosmetic — never surface a failure for it.
            }
        }
        #endif
    }

    /// Playback really stopped (not a PiP handoff): clear the lock screen and
    /// stop answering remote commands. Handlers are intentionally KEPT — a
    /// newly created VM may have already registered its own; stale closures
    /// capture the old VM weakly and the commands are disabled anyway.
    /// - Parameter session: token from `activate`. A mismatch means a newer
    ///   session owns the lock screen now → no-op.
    public func deactivate(session: Int? = nil) {
        if let session, session != sessionCounter { return }
        active = false
        disableCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Commands

    private func enableCommands() {
        guard commandTokens.isEmpty else { return }

        commandTokens.append((commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }))
        commandTokens.append((commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }))
        commandTokens.append((commands.togglePlayPauseCommand, commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onTogglePlayPause?() }
            return .success
        }))

        commands.skipBackwardCommand.preferredIntervals = [15]
        commandTokens.append((commands.skipBackwardCommand, commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onSkipBackward?() }
            return .success
        }))

        commands.skipForwardCommand.preferredIntervals = [15]
        commandTokens.append((commands.skipForwardCommand, commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onSkipForward?() }
            return .success
        }))

        commandTokens.append((commands.changePlaybackPositionCommand, commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.onSeek?(position) }
            return .success
        }))
    }

    private func disableCommands() {
        for entry in commandTokens {
            entry.command.removeTarget(entry.token)
        }
        commandTokens.removeAll()
    }
}
