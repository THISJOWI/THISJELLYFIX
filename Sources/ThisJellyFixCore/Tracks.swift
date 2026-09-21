import Foundation

/// Represents an audio track available in the current media.
public struct AudioTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let language: String?

    public init(id: Int, name: String, language: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
    }
}

/// Represents a subtitle track available in the current media.
public struct SubtitleTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let language: String?
    public let isExternal: Bool

    public init(id: Int, name: String, language: String? = nil, isExternal: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.isExternal = isExternal
    }
}
