import Foundation

/// Represents an audio track available in the current media.
public struct AudioTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    /// Raw ISO-639 code as reported by the engine — used for language
    /// preference matching. Never display this directly.
    public let language: String?
    /// Human-readable language for display (e.g. "Inglés"), derived by
    /// `TrackNaming` from server/engine metadata.
    public let languageName: String?

    public init(id: Int, name: String, language: String? = nil, languageName: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.languageName = languageName
    }
}

/// Represents a subtitle track available in the current media.
public struct SubtitleTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    /// Raw ISO-639 code as reported by the engine — used for language
    /// preference matching. Never display this directly.
    public let language: String?
    /// Human-readable language for display (e.g. "Inglés"), derived by
    /// `TrackNaming` from server/engine metadata.
    public let languageName: String?
    public let isExternal: Bool

    public init(
        id: Int,
        name: String,
        language: String? = nil,
        languageName: String? = nil,
        isExternal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.languageName = languageName
        self.isExternal = isExternal
    }
}
