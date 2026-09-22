import Foundation

public struct JellyfinMediaItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let type: String
    public let overview: String?
    public let seriesName: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let year: Int?
    public let imageTags: [String: String]?
    public let officialRating: String?
    public let communityRating: Double?
    public let userData: UserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case year = "Year"
        case imageTags = "ImageTags"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case userData = "UserData"
    }

    public var hasImage: Bool {
        imageTags?["Primary"] != nil
    }

    /// Percentage watched (0–100). nil if no resume data.
    public var playedPercentage: Double? {
        userData?.playedPercentage
    }

    /// Resume position in seconds. nil if no resume data.
    public var resumePositionSeconds: Double? {
        userData?.playbackPositionTicks.map { Double($0) / 10_000_000.0 }
    }

    /// Episode label like "T1 E3" for episodes, nil for movies/series.
    public var episodeLabel: String? {
        guard type == "Episode" else { return nil }
        if let s = parentIndexNumber, let e = indexNumber {
            return "T\(s) E\(e)"
        }
        if let e = indexNumber {
            return "Ep \(e)"
        }
        return nil
    }

    /// Display name: series name + episode label for episodes, otherwise just name.
    public var displayName: String {
        if type == "Episode", let seriesName {
            if let label = episodeLabel {
                return "\(seriesName) · \(label)"
            }
            return seriesName
        }
        return name
    }
}

public struct UserData: Codable, Sendable, Equatable, Hashable {
    public let playbackPositionTicks: Int64?
    public let playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playedPercentage = "PlayedPercentage"
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

// MARK: - Seasons & Episodes

public struct JellyfinSeason: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let indexNumber: Int?
    public let seriesId: String?
    public let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case indexNumber = "IndexNumber"
        case seriesId = "SeriesId"
        case imageTags = "ImageTags"
    }

    public var displayName: String {
        if let indexNumber {
            return "Temporada \(indexNumber)"
        }
        return name
    }
}

public struct JellyfinEpisode: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let overview: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let runTimeTicks: Int64?
    public let seriesId: String?
    public let seriesName: String?
    public let seasonName: String?
    public let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case overview = "Overview"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case imageTags = "ImageTags"
    }

    public var episodeLabel: String {
        if let s = parentIndexNumber, let e = indexNumber {
            return "T\(s) E\(e)"
        }
        if let e = indexNumber {
            return "Episodio \(e)"
        }
        return name
    }

    public var durationMinutes: Int? {
        guard let runTimeTicks else { return nil }
        return Int(runTimeTicks / 10_000_000 / 60)
    }

    public var hasImage: Bool {
        imageTags?["Primary"] != nil
    }
}
