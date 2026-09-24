import Foundation

// MARK: - Segment Type

/// Kind of skippable segment inside an episode/video.
public enum SegmentType: String, Codable, Sendable, CaseIterable, Hashable {
    case intro
    case recap
    case credits
}

// MARK: - Segment Marker

/// A time range inside a playing item that the user may want to skip.
public struct SegmentMarker: Sendable, Equatable, Hashable, Identifiable {
    public let type: SegmentType
    /// Start of the segment, in seconds.
    public let start: Double
    /// End of the segment, in seconds. `nil` = until the end of the video
    /// (used for chapter-derived markers with no following chapter).
    public let end: Double?

    public init(type: SegmentType, start: Double, end: Double?) {
        self.type = type
        self.start = start
        self.end = end
    }

    public var id: String {
        "\(type.rawValue)-\(Int(start))-\(end.map { String(Int($0)) } ?? "end")"
    }

    /// Marker sanity: start >= 0 and, when present, end after start.
    public var isValid: Bool {
        start >= 0 && (end.map { $0 > start } ?? true)
    }

    public func contains(_ time: Double) -> Bool {
        guard time >= start else { return false }
        guard let end else { return true }
        return time < end
    }
}

// MARK: - Skip Settings

/// User preferences for the skip feature. Persisted in `UserDefaults`
/// (same store `@AppStorage` writes to), so the player picks up changes live.
public struct SkipSettings: Sendable, Equatable {
    public var introEnabled: Bool
    public var recapEnabled: Bool
    public var creditsEnabled: Bool
    /// When true, segments auto-skip after `autoSkipDelay` seconds inside them.
    public var autoSkip: Bool
    /// Seconds the user has to manually skip before auto-skip kicks in.
    public var autoSkipDelay: Double

    public enum Key {
        public static let intro = "skip.intro"
        public static let recap = "skip.recap"
        public static let credits = "skip.credits"
        public static let autoSkip = "skip.autoSkip"
    }

    public init(
        introEnabled: Bool = true,
        recapEnabled: Bool = true,
        creditsEnabled: Bool = true,
        autoSkip: Bool = true,
        autoSkipDelay: Double = 5.0
    ) {
        self.introEnabled = introEnabled
        self.recapEnabled = recapEnabled
        self.creditsEnabled = creditsEnabled
        self.autoSkip = autoSkip
        self.autoSkipDelay = autoSkipDelay
    }

    public static func current(_ defaults: UserDefaults = .standard) -> SkipSettings {
        SkipSettings(
            introEnabled: defaults.object(forKey: Key.intro) as? Bool ?? true,
            recapEnabled: defaults.object(forKey: Key.recap) as? Bool ?? true,
            creditsEnabled: defaults.object(forKey: Key.credits) as? Bool ?? true,
            autoSkip: defaults.object(forKey: Key.autoSkip) as? Bool ?? true
        )
    }

    public func isEnabled(_ type: SegmentType) -> Bool {
        switch type {
        case .intro: introEnabled
        case .recap: recapEnabled
        case .credits: creditsEnabled
        }
    }
}
