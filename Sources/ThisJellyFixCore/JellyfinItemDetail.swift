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
    /// Series carry their artwork in this array; only movies (and some
    /// episodes) put a `Backdrop` entry in `imageTags`.
    public let backdropImageTags: [String]?
    /// Server-side per-user state: favorite flag, played flag, resume position.
    public let userData: UserData?

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
        case backdropImageTags = "BackdropImageTags"
        case userData = "UserData"
    }

    /// True when the server sent any backdrop artwork, in either shape:
    /// `ImageTags.Backdrop` (movies) or `BackdropImageTags` (series/seasons).
    public var hasBackdrop: Bool {
        imageTags?["Backdrop"] != nil || (backdropImageTags?.isEmpty == false)
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

    public var isFavorite: Bool { userData?.isFavorite ?? false }

    public var isPlayed: Bool { userData?.played ?? false }

    public var resumePositionSeconds: Double? { userData?.resumePositionSeconds }
}
