import Foundation

public struct PlaybackInfo: Codable, Sendable, Equatable {
    public let mediaSources: [MediaSource]

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

public struct MediaSource: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let container: String?
    public let directStreamUrl: String?
    public let transcodingUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
    }

    public var bestURL: String? {
        directStreamUrl ?? transcodingUrl
    }
}
