import Foundation

/// Decision rule for the AUTOMATIC Picture-in-Picture handoff (swipe-up out of
/// the app, or the fullscreen player leaving the screen).
///
/// Isolated from the view model so the rule is unit-testable: the swipe-up
/// handoff used to be gated on VLCKit's raw `isPlaying`, which can read `false`
/// while the clock is still advancing — the guard failed silently and the
/// floating window simply never opened.
public enum PiPHandoffPolicy {
    /// - Parameters:
    ///   - isPlaying: engine-reported playing state (unreliable on its own).
    ///   - userPaused: playback is stopped BECAUSE the user asked for it.
    ///   - position: current playback position in seconds.
    ///   - duration: total duration in seconds; `<= 0` means unknown/live.
    ///   - engineStopped: the engine was torn down (nothing can be handed off).
    ///   - hasError: the player is showing an error instead of video.
    public static func canAutoStart(
        isPlaying: Bool,
        userPaused: Bool,
        position: Double,
        duration: Double,
        engineStopped: Bool = false,
        hasError: Bool = false
    ) -> Bool {
        guard !engineStopped, !hasError else { return false }
        // Trust an explicit user pause over everything: the timer refreshes
        // `isPlaying` from the engine every 0.5s, so it can still read true
        // for a beat after the pause tap.
        guard !userPaused else { return false }
        // Finished (or inside the last 1.5s — the same threshold the player
        // uses to turn EndReached into "finished" instead of an error): a
        // completed episode must never float away replaying its last second.
        if duration > 0, position >= duration - 1.5 { return false }
        // Trust the positive report: an actively playing item may hand off.
        if isPlaying { return true }
        // Engine says "not playing" but the clock is between the start and the
        // end — that is VLCKit's lie (buffering / transient read), still a
        // playing item. Position 0 means nothing was watched yet.
        return position > 0
    }
}
