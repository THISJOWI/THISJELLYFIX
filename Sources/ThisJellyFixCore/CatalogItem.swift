import Foundation

/// Origin-agnostic catalogue entry: whatever the metadata provider returned
/// (TMDB today, another provider tomorrow), normalized for UI + downloads.
public struct CatalogItem: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case movie
        case series
    }

    /// Stable id within the source that produced the item (TMDB id today).
    public let id: String
    public let kind: Kind
    public let title: String
    public let year: Int?
    public let overview: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let tmdbId: String?
    public let imdbId: String?
    /// Jellyfin item id when this title already exists in the library.
    public let jellyfinId: String?
    /// TMDB genre ids — used to shelf like with like (anime vs plain rows).
    public let genreIds: [Int]
    /// TMDB original language ("ja" + Animation = anime).
    public let originalLanguage: String?

    public init(
        id: String,
        kind: Kind,
        title: String,
        year: Int?,
        overview: String?,
        posterURL: URL?,
        backdropURL: URL?,
        tmdbId: String?,
        imdbId: String?,
        jellyfinId: String? = nil,
        genreIds: [Int] = [],
        originalLanguage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.jellyfinId = jellyfinId
        self.genreIds = genreIds
        self.originalLanguage = originalLanguage
    }

    public var isInLibrary: Bool { jellyfinId != nil }

    /// Japanese animation: TMDB's Animation genre (16) in a Japanese-origin
    /// title. English-language animation (Pixar…) stays in the plain rows.
    public var isAnime: Bool {
        genreIds.contains(16) && originalLanguage == "ja"
    }

    /// Which *arr service handles downloads for this kind of item.
    public var downloadService: DownloadService {
        kind == .movie ? .radarr : .sonarr
    }

    /// Match against a TMDB id coming from another source (Jellyfin `ProviderIds`).
    public func matches(tmdbId: String?) -> Bool {
        guard let tmdbId, let mine = self.tmdbId else { return false }
        return mine.caseInsensitiveCompare(tmdbId) == .orderedSame
    }
}

/// Download backend for a catalogue item.
public enum DownloadService: String, Sendable, Codable, CaseIterable {
    case radarr
    case sonarr
}
