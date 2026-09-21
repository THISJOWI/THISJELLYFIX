import Foundation

public struct JellyfinMediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let overview: String?
    public let seriesName: String?
    public let year: Int?
    public let imageTags: [String: String]?
    public let officialRating: String?
    public let communityRating: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case seriesName = "SeriesName"
        case year = "Year"
        case imageTags = "ImageTags"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
    }

    public var hasImage: Bool {
        imageTags?["Primary"] != nil
    }
}

public struct LibraryView: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }
}
