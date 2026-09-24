import Foundation

public struct JellyfinItemDetail: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let overview: String?
    public let year: Int?
    public let officialRating: String?
    public let communityRating: Double?
    public let genres: [String]?
    public let runTimeTicks: Int64?
    public let premiereDate: String?
    public let seriesName: String?
    public let seriesId: String?
    public let parentIndexNumber: Int?
    public let indexNumber: Int?
    public let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case year = "Year"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case genres = "Genres"
        case runTimeTicks = "RunTimeTicks"
        case premiereDate = "PremiereDate"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case imageTags = "ImageTags"
    }

    public var hasBackdrop: Bool {
        imageTags?["Backdrop"] != nil
    }

    public var hasPoster: Bool {
        imageTags?["Primary"] != nil
    }

    public var durationMinutes: Int? {
        guard let runTimeTicks else { return nil }
        return Int(runTimeTicks / 10_000_000 / 60)
    }

    public var formattedRating: String? {
        guard let communityRating else { return nil }
        return String(format: "%.1f", communityRating)
    }
}
