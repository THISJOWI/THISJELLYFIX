import Foundation
import ThisJellyFixCore
import ThisJellyFixNetworking

// MARK: - Protocol

/// Metadata source for the discovery UI. Implementations are swappable:
/// adding a provider means adding a type, not touching the UI.
public protocol MetadataProvider: Sendable {
    /// Trending shelf for one media kind: series and movies get their own
    /// row instead of one mixed list.
    func trending(kind: CatalogItem.Kind) async throws -> [CatalogItem]
    func recommendations(tmdbId: String, kind: CatalogItem.Kind) async throws -> [CatalogItem]
    func search(query: String) async throws -> [CatalogItem]
}

// MARK: - Errors

public enum MetadataProviderError: LocalizedError, Equatable {
    case unauthorized
    case serverError(Int)
    case invalidResponse
    case missingConfiguration

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "API key rechazada por el proveedor de metadatos."
        case .serverError(let code): "El proveedor devolvió un error (código \(code))."
        case .invalidResponse: "Respuesta inválida del proveedor de metadatos."
        case .missingConfiguration: "Falta la API key del proveedor de metadatos."
        }
    }
}

// MARK: - TMDB

/// TMDB v3 client. Read-only metadata: trending, recommendations, search.
public struct TMDBMetadataProvider: MetadataProvider {
    public static let imageBase = URL(string: "https://image.tmdb.org/t/p")!

    private let apiKey: String
    private let baseURL: URL
    private let session: any JellyfinNetworkSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.themoviedb.org")!,
        session: any JellyfinNetworkSession = URLSession.shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func trending(kind: CatalogItem.Kind) async throws -> [CatalogItem] {
        let media = kind == .movie ? "movie" : "tv"
        let response: PagedResults = try await get("/3/trending/\(media)/day")
        // The kind comes from the endpoint; media_type is just a cross-check.
        return response.results.compactMap { entry in
            guard let entryKind = entry.kind(mediaType: entry.mediaType ?? media) else { return nil }
            return entry.catalogItem(kind: entryKind)
        }
    }

    public func recommendations(tmdbId: String, kind: CatalogItem.Kind) async throws -> [CatalogItem] {
        let path = kind == .movie ? "/3/movie/\(tmdbId)/recommendations" : "/3/tv/\(tmdbId)/recommendations"
        // The recommendations payload has no media_type: kind comes from the endpoint.
        let response: PagedResults = try await get(path)
        return response.results.map { $0.catalogItem(kind: kind) }
    }

    public func search(query: String) async throws -> [CatalogItem] {
        let response: PagedResults = try await get("/3/search/multi", query: [
            URLQueryItem(name: "query", value: query),
        ])
        return response.results.compactMap { entry in
            guard let kind = entry.kind(mediaType: entry.mediaType) else { return nil }
            return entry.catalogItem(kind: kind)
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard !apiKey.isEmpty else { throw MetadataProviderError.missingConfiguration }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query

        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MetadataProviderError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw MetadataProviderError.unauthorized
        default:
            throw MetadataProviderError.serverError(http.statusCode)
        }
    }
}

// MARK: - TMDB payloads

private struct PagedResults: Decodable {
    let results: [TMDBEntry]
}

private struct TMDBEntry: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIds: [Int]?
    let originalLanguage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case mediaType = "media_type"
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
    }

    /// media_type comes from trending/search; callers with no media_type
    /// (recommendations) pass the endpoint's kind explicitly.
    func kind(mediaType: String?) -> CatalogItem.Kind? {
        switch mediaType {
        case "movie": return .movie
        case "tv": return .series
        default: return nil
        }
    }

    func catalogItem(kind: CatalogItem.Kind) -> CatalogItem {
        let rawDate = releaseDate ?? firstAirDate
        return CatalogItem(
            id: String(id),
            kind: kind,
            title: title ?? name ?? "",
            year: Self.year(from: rawDate),
            overview: overview,
            posterURL: Self.imageURL(path: posterPath, size: "w500"),
            backdropURL: Self.imageURL(path: backdropPath, size: "w780"),
            tmdbId: String(id),
            imdbId: nil,
            genreIds: genreIds ?? [],
            originalLanguage: originalLanguage
        )
    }

    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    static func imageURL(path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return TMDBMetadataProvider.imageBase
            .appendingPathComponent(size)
            .appendingPathComponent(path)
    }
}
