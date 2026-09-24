import Foundation

/// Pure state machine that decides what to show/do on each playback tick.
/// No I/O, no timers — the caller feeds `tick(...)` with the current playback
/// time and interprets the returned `Outcome`.
public struct SegmentDetector: Sendable, Equatable {
    public enum Outcome: Equatable {
        /// No active segment — hide the skip UI.
        case none
        /// User may skip manually now. `countdown` = seconds until auto-skip
        /// fires (nil when auto-skip is disabled).
        case show(SegmentMarker, countdown: Double?)
        /// Auto-skip threshold reached — caller must skip and then call
        /// `markSkipped(_:)` (which it should do immediately).
        case triggerSkip(SegmentMarker)
    }

    /// The segment the playhead is currently inside (even if auto-skip was
    /// already dismissed for it), for button rendering.
    public private(set) var activeMarker: SegmentMarker?

    private var dwell: Double = 0
    private var dismissed: Set<String> = []

    public init() {}

    /// Feed the current playback position. `delta` = elapsed seconds since the
    /// previous tick (pass 0 to freeze the countdown, e.g. while paused).
    public mutating func tick(
        time: Double,
        delta: Double,
        markers: [SegmentMarker],
        settings: SkipSettings
    ) -> Outcome {
        let candidates = markers
            .filter { $0.isValid && settings.isEnabled($0.type) && !dismissed.contains($0.id) && $0.contains(time) }
            .sorted { $0.start < $1.start }
        let current = candidates.first

        if current != activeMarker {
            activeMarker = current
            dwell = 0
        }

        guard let marker = activeMarker else { return .none }

        dwell += max(0, delta)

        if settings.autoSkip {
            let remaining = settings.autoSkipDelay - dwell
            if remaining <= 0 {
                return .triggerSkip(marker)
            }
            return .show(marker, countdown: remaining)
        }
        return .show(marker, countdown: nil)
    }

    /// Remember that a segment was skipped (manual or automatic) so the
    /// overlay never reappears inside it during this playback session.
    public mutating func markSkipped(_ marker: SegmentMarker) {
        dismissed.insert(marker.id)
        if activeMarker == marker {
            activeMarker = nil
            dwell = 0
        }
    }

    public mutating func reset() {
        activeMarker = nil
        dwell = 0
        dismissed = []
    }
}
