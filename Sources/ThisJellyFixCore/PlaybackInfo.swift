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
    /// Total source size in bytes. nil when the server omits it (e.g. transcoding-only answers).
    public let size: Int64?
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    public let mediaStreams: [MediaStream]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case size = "Size"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        self.size = try container.decodeIfPresent(Int64.self, forKey: .size)
        self.directStreamUrl = try container.decodeIfPresent(String.self, forKey: .directStreamUrl)
        self.transcodingUrl = try container.decodeIfPresent(String.self, forKey: .transcodingUrl)
        self.mediaStreams = (try? container.decodeIfPresent([MediaStream].self, forKey: .mediaStreams)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var keyedContainer = encoder.container(keyedBy: CodingKeys.self)
        try keyedContainer.encode(id, forKey: .id)
        try keyedContainer.encode(name, forKey: .name)
        try keyedContainer.encodeIfPresent(self.container, forKey: .container)
        try keyedContainer.encodeIfPresent(size, forKey: .size)
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
    public let width: Int?
    public let height: Int?
    /// Bitrate in bits per second. Jellyfin versions disagree on the key casing
    /// (`BitRate` vs `Bitrate`), so decoding accepts both.
    public let bitRate: Int64?
    /// Frames per second of the video stream.
    public let realFrameRate: Double?
    /// `SDR`, `HDR10`, `DOVI`, … — nil when the server omits it.
    public let videoRange: String?

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
        case width = "Width"
        case height = "Height"
        case bitRate = "BitRate"
        case bitRateAlias = "Bitrate"
        case realFrameRate = "RealFrameRate"
        case videoRange = "VideoRange"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.index = try container.decodeIfPresent(Int.self, forKey: .index)
        self.isExternal = try container.decodeIfPresent(Bool.self, forKey: .isExternal)
        self.codec = try container.decodeIfPresent(String.self, forKey: .codec)
        self.displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        self.isForced = try container.decodeIfPresent(Bool.self, forKey: .isForced)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.width = try container.decodeIfPresent(Int.self, forKey: .width)
        self.height = try container.decodeIfPresent(Int.self, forKey: .height)
        self.bitRate =
            try container.decodeIfPresent(Int64.self, forKey: .bitRate)
            ?? container.decodeIfPresent(Int64.self, forKey: .bitRateAlias)
        self.realFrameRate = try container.decodeIfPresent(Double.self, forKey: .realFrameRate)
        self.videoRange = try container.decodeIfPresent(String.self, forKey: .videoRange)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(index, forKey: .index)
        try container.encodeIfPresent(isExternal, forKey: .isExternal)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(isForced, forKey: .isForced)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(bitRate, forKey: .bitRate)
        try container.encodeIfPresent(realFrameRate, forKey: .realFrameRate)
        try container.encodeIfPresent(videoRange, forKey: .videoRange)
    }
}
