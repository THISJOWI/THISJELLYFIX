import Foundation

public struct PlaybackInfo: Codable, Sendable, Equatable {
    public let mediaSources: [MediaSource]
    /// Server-issued session id — must be echoed on Sessions/Playing* reports
    /// so Jellyfin persists progress to the right playback session.
    public let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

public struct MediaSource: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let container: String?
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    public let mediaStreams: [MediaStream]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        self.directStreamUrl = try container.decodeIfPresent(String.self, forKey: .directStreamUrl)
        self.transcodingUrl = try container.decodeIfPresent(String.self, forKey: .transcodingUrl)
        self.mediaStreams = (try? container.decodeIfPresent([MediaStream].self, forKey: .mediaStreams)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var keyedContainer = encoder.container(keyedBy: CodingKeys.self)
        try keyedContainer.encode(id, forKey: .id)
        try keyedContainer.encode(name, forKey: .name)
        try keyedContainer.encodeIfPresent(self.container, forKey: .container)
        try keyedContainer.encodeIfPresent(directStreamUrl, forKey: .directStreamUrl)
        try keyedContainer.encodeIfPresent(transcodingUrl, forKey: .transcodingUrl)
        if !mediaStreams.isEmpty {
            try keyedContainer.encode(mediaStreams, forKey: .mediaStreams)
        }
    }

    public var bestURL: String? {
        directStreamUrl ?? transcodingUrl
    }
}

/// A single media stream (audio, subtitle, or video) from the server.
public struct MediaStream: Codable, Sendable, Equatable {
    public let type: String
    public let language: String?
    public let title: String?
    public let index: Int?
    public let isExternal: Bool?
    public let codec: String?
    public let displayTitle: String?
    public let isForced: Bool?
    public let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case language = "Language"
        case title = "Title"
        case index = "Index"
        case isExternal = "IsExternal"
        case codec = "Codec"
        case displayTitle = "DisplayTitle"
        case isForced = "IsForced"
        case isDefault = "IsDefault"
    }
}
