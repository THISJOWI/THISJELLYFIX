import Foundation
import ThisJellyFixCore
import ThisJellyFixNetworking

// MARK: - Errors

public enum ArrError: LocalizedError, Equatable {
    /// Endpoint reachable but the API key was rejected.
    case unauthorized
    /// Service did not answer (LAN/túnel caído, URL mal, timeout).
    case unreachable
    case serverError(Int)
    case invalidResponse
    /// Lookup returned nothing for this id.
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "API key rechazada por el servicio."
        case .unreachable: "No se pudo contactar con el servicio. Revisa la URL."
        case .serverError(let code): "El servicio devolvió un error (código \(code))."
        case .invalidResponse: "Respuesta inválida del servicio."
        case .notFound: "No se encontró el título en el servicio."
        }
    }
}

// MARK: - Shared types

public struct ArrQualityProfile: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
}

public struct ArrRootFolder: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let path: String
}

/// How many seasons to monitor when adding a series.
public enum SeriesMonitor: String, Sendable, Codable {
    case all
    case first = "firstSeason"
    case latest = "latestSeason"
    case none
    case future = "futureSeasons"
}

/// What the add request should do right after creating the entry.
public struct AddOptions: Sendable, Equatable {
    public let qualityProfileId: Int
    public let rootFolderPath: String
    public let monitored: Bool
    /// Fire an automatic search immediately instead of waiting for a grab.
    public let searchNow: Bool

    public init(qualityProfileId: Int, rootFolderPath: String, monitored: Bool = true, searchNow: Bool = true) {
        self.qualityProfileId = qualityProfileId
        self.rootFolderPath = rootFolderPath
        self.monitored = monitored
        self.searchNow = searchNow
    }
}

// MARK: - Base client

/// Shared HTTP plumbing for Radarr/Sonarr v3 APIs: base URL + `X-Api-Key`.
struct ArrHTTPClient {
    let baseURL: URL
    let apiKey: String
    let service: String
    let session: any JellyfinNetworkSession

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(path: path, method: "GET", query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await send(path: path, method: "POST", query: [], body: body)
    }

    /// DELETE returns an empty body on success (200...299).
    func delete(_ path: String) async throws {
        _ = try await sendRaw(path: path, method: "DELETE", body: nil)
    }

    /// POST returning the raw JSON object (id extraction and similar).
    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try await sendRaw(path: path, method: "POST", body: body)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw ArrError.invalidResponse }
        return dictionary
    }

    private func send<T: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: [String: Any]?
    ) async throws -> T {
        let data = try await sendRaw(path: path, method: method, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendRaw(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: Any]?
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v3/\(path)"),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            TJFLog("\(service) \(method) \(path) unreachable: \(error)")
            throw ArrError.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw ArrError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            TJFLog("\(service) \(method) \(path) status=\(http.statusCode)")
            throw ArrError.unauthorized
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? "binary"
            TJFLog("\(service) \(method) \(path) status=\(http.statusCode) body=\(bodyStr.prefix(300))")
            throw ArrError.serverError(http.statusCode)
        }
    }
}

// MARK: - Radarr

public struct RadarrMovieLookup: Decodable, Sendable, Equatable {
    public let id: Int?
    public let title: String
    public let year: Int?
    /// TMDB ids arrive as JSON numbers; normalized to string to match `CatalogItem`.
    public let tmdbId: String
    public let hasFile: Bool?
    public let monitored: Bool?
    public let status: String?
    public let images: [ArrImage]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, tmdbId, hasFile, monitored, status, images
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        tmdbId = try container.decodeLossyString(Int.self, forKey: .tmdbId)
        hasFile = try container.decodeIfPresent(Bool.self, forKey: .hasFile)
        monitored = try container.decodeIfPresent(Bool.self, forKey: .monitored)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        images = try container.decodeIfPresent([ArrImage].self, forKey: .images)
    }
}

public struct ArrImage: Decodable, Sendable, Equatable {
    public let coverType: String
    public let url: String?
}

public protocol RadarrProviding: Sendable {
    func lookup(tmdbId: String) async throws -> [RadarrMovieLookup]
    func addMovie(
        tmdbId: String,
        title: String,
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool,
        searchForMovie: Bool
    ) async throws -> Int
    func qualityProfiles() async throws -> [ArrQualityProfile]
    func rootFolders() async throws -> [ArrRootFolder]
    func testConnection() async throws
    func queue() async throws -> [DownloadEntry]
    /// Remove the entry (not the downloaded files) from the service.
    func deleteEntry(id: String) async throws
}

public struct RadarrClient: RadarrProviding {
    private let http: ArrHTTPClient

    public init(baseURL: URL, apiKey: String, session: any JellyfinNetworkSession = URLSession.shared) {
        self.http = ArrHTTPClient(baseURL: baseURL, apiKey: apiKey, service: "Radarr", session: session)
    }

    public func lookup(tmdbId: String) async throws -> [RadarrMovieLookup] {
        try await http.get("movie/lookup", query: [URLQueryItem(name: "term", value: "tmdb:\(tmdbId)")])
    }

    public func addMovie(
        tmdbId: String,
        title: String,
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool,
        searchForMovie: Bool
    ) async throws -> Int {
        let body: [String: Any] = [
            "tmdbId": Int(tmdbId) ?? 0,
            "title": title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": monitored,
            "searchForMovie": searchForMovie,
        ]
        let response: [String: Any] = try await http.post("movie", body: body)
        return response["id"] as? Int ?? 0
    }

    public func qualityProfiles() async throws -> [ArrQualityProfile] {
        try await http.get("qualityprofile")
    }

    public func rootFolders() async throws -> [ArrRootFolder] {
        try await http.get("rootfolder")
    }

    public func testConnection() async throws {
        let _: [ArrQualityProfile] = try await http.get("qualityprofile")
    }

    public func queue() async throws -> [DownloadEntry] {
        let response: QueueResponse = try await http.get("queue")
        return response.records.compactMap { $0.entry(service: .radarr) }
    }

    public func deleteEntry(id: String) async throws {
        try await http.delete("movie/\(id)")
    }
}

// MARK: - Sonarr

public struct SonarrSeason: Decodable, Sendable, Equatable {
    public let seasonNumber: Int
    public let monitored: Bool?
}

public struct SonarrSeriesLookup: Decodable, Sendable, Equatable {
    public let id: Int?
    public let title: String
    public let year: Int?
    public let tvdbId: Int
    /// TMDB ids arrive as JSON numbers; normalized to string to match `CatalogItem`.
    public let tmdbId: String?
    public let status: String?
    public let network: String?
    public let seasonCount: Int?
    public let images: [ArrImage]?
    public let seasons: [SonarrSeason]

    enum CodingKeys: String, CodingKey {
        case id, title, year, tvdbId, tmdbId, status, network, seasonCount, images, seasons
    }

    public init(
        id: Int?, title: String, year: Int?, tvdbId: Int, tmdbId: String?,
        status: String?, network: String?, seasonCount: Int?,
        images: [ArrImage]?, seasons: [SonarrSeason]
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.tvdbId = tvdbId
        self.tmdbId = tmdbId
        self.status = status
        self.network = network
        self.seasonCount = seasonCount
        self.images = images
        self.seasons = seasons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        tvdbId = try container.decode(Int.self, forKey: .tvdbId)
        tmdbId = try container.decodeLossyStringIfPresent(Int.self, forKey: .tmdbId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        network = try container.decodeIfPresent(String.self, forKey: .network)
        seasonCount = try container.decodeIfPresent(Int.self, forKey: .seasonCount)
        images = try container.decodeIfPresent([ArrImage].self, forKey: .images)
        seasons = try container.decodeIfPresent([SonarrSeason].self, forKey: .seasons) ?? []
    }
}

extension KeyedDecodingContainer {
    /// Decode a number or string as a string (`335984` and `"335984"` both work).
    func decodeLossyString<T: LossyStringConvertible>(_ type: T.Type, forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let number = try? decode(T.self, forKey: key) { return number.description }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath, debugDescription: "Missing string/number for \(key.stringValue)")
        )
    }

    func decodeLossyStringIfPresent<T: LossyStringConvertible>(_ type: T.Type, forKey key: Key) throws -> String? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        return try? decodeLossyString(T.self, forKey: key)
    }
}

public protocol LossyStringConvertible: Decodable, CustomStringConvertible {}
extension Int: LossyStringConvertible {}
extension Double: LossyStringConvertible {}

public protocol SonarrProviding: Sendable {
    func lookup(tmdbId: String) async throws -> [SonarrSeriesLookup]
    func addSeries(
        tvdbId: Int,
        title: String,
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool,
        monitor: SeriesMonitor,
        seasons: [Int],
        searchForMissing: Bool
    ) async throws -> Int
    func qualityProfiles() async throws -> [ArrQualityProfile]
    func rootFolders() async throws -> [ArrRootFolder]
    func testConnection() async throws
    func queue() async throws -> [DownloadEntry]
    /// Remove the entry (not the downloaded files) from the service.
    func deleteEntry(id: String) async throws
}

public struct SonarrClient: SonarrProviding {
    private let http: ArrHTTPClient

    public init(baseURL: URL, apiKey: String, session: any JellyfinNetworkSession = URLSession.shared) {
        self.http = ArrHTTPClient(baseURL: baseURL, apiKey: apiKey, service: "Sonarr", session: session)
    }

    public func lookup(tmdbId: String) async throws -> [SonarrSeriesLookup] {
        try await http.get("series/lookup", query: [URLQueryItem(name: "term", value: "tmdb:\(tmdbId)")])
    }

    public func addSeries(
        tvdbId: Int,
        title: String,
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool,
        monitor: SeriesMonitor,
        seasons: [Int],
        searchForMissing: Bool
    ) async throws -> Int {
        let body: [String: Any] = [
            "tvdbId": tvdbId,
            "title": title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": monitored,
            "monitor": monitor.rawValue,
            "seasons": seasons,
            "searchForMissingEpisodes": searchForMissing,
        ]
        let response: [String: Any] = try await http.post("series", body: body)
        return response["id"] as? Int ?? 0
    }

    public func qualityProfiles() async throws -> [ArrQualityProfile] {
        try await http.get("qualityprofile")
    }

    public func rootFolders() async throws -> [ArrRootFolder] {
        try await http.get("rootfolder")
    }

    public func testConnection() async throws {
        let _: [ArrQualityProfile] = try await http.get("qualityprofile")
    }

    public func queue() async throws -> [DownloadEntry] {
        let response: QueueResponse = try await http.get("queue")
        return response.records.compactMap { $0.entry(service: .sonarr) }
    }

    public func deleteEntry(id: String) async throws {
        try await http.delete("series/\(id)")
    }
}
