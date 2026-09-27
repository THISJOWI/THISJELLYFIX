import Foundation
import ThisJellyFixCore
import ThisJellyFixNetworking

// MARK: - Errors

public enum ArrError: LocalizedError, Equatable {
    /// Endpoint reachable but the API key was rejected.
    case unauthorized
    /// Service did not answer (LAN/túnel caído, URL mal, timeout).
    case unreachable
    /// Transport failure carrying the system's own wording, so a refused
    /// connection, a blocked LAN address and a dead tunnel don't look alike.
    case connectionFailed(String)
    /// App Transport Security refused the request (plain HTTP outside LAN).
    case transportSecurityBlocked
    /// Non-2xx with the service's own explanation (nil = empty body).
    case serverError(Int, String?)
    case invalidResponse
    /// Lookup returned nothing for this id.
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "API key rechazada por el servicio."
        case .unreachable: "No se pudo contactar con el servicio. Revisa la URL."
        case .connectionFailed(let detail): "No se pudo conectar con el servicio. \(detail)"
        case .transportSecurityBlocked:
            "iOS bloqueó la conexión: los servicios *arr solo pueden usarse en HTTP plano dentro de la red local."
        case .serverError(let code, let message):
            if let message, !message.isEmpty {
                "El servicio devolvió un error (código \(code)): \(message)"
            } else {
                "El servicio devolvió un error (código \(code))."
            }
        case .invalidResponse: "Respuesta inválida del servicio."
        case .notFound: "No se encontró el título en el servicio."
        }
    }

    /// Pull the human-readable part out of an *arr error body: JSON array
    /// of {errorMessage}, {message}, or plain text.
    static func serverMessage(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: body) {
            if let array = object as? [[String: Any]] {
                let messages = array.compactMap {
                    ($0["errorMessage"] as? String) ?? ($0["message"] as? String)
                }
                let joined = messages.joined(separator: "; ")
                if !joined.isEmpty { return String(joined.prefix(300)) }
            } else if let dictionary = object as? [String: Any],
                      let message = dictionary["message"] as? String ?? dictionary["errorMessage"] as? String {
                return String(message.prefix(300))
            } else if let string = object as? String, !string.isEmpty {
                return String(string.prefix(300))
            }
            return nil
        }
        // Not JSON (plain-text error page): show a short prefix.
        return String(raw.prefix(300))
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
            throw Self.classify(error, host: request.url?.host)
        }

        guard let http = response as? HTTPURLResponse else { throw ArrError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            TJFLog("\(service) \(method) \(path) status=\(http.statusCode)")
            throw ArrError.unauthorized
        default:
            let message = ArrError.serverMessage(from: data)
            TJFLog("\(service) \(method) \(path) status=\(http.statusCode) message=\(message ?? "-")")
            throw ArrError.serverError(http.statusCode, message)
        }
    }

    /// Turn a transport error into something the user can act on. Local
    /// network addresses get the Red local hint: on iOS that permission is
    /// the difference between "works" and a silent connection refusal.
    private static func classify(_ error: Error, host: String?) -> ArrError {
        guard let urlError = error as? URLError else { return .unreachable }
        if urlError.code == .appTransportSecurityRequiresSecureConnection {
            return .transportSecurityBlocked
        }
        let hint = isLocalNetworkHost(host)
            ? " Comprueba que el permiso de Red local esté activado en Ajustes."
            : ""
        return .connectionFailed(urlError.localizedDescription + hint)
    }

    /// Private IPv4 ranges, IPv6 loopback/link-local and `.local` names.
    private static func isLocalNetworkHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host == "::1" || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
        else { return false }
        let octets = parts.compactMap { Int($0) }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 169, octets[1] == 254 { return true }
        return false
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

    public init(
        id: Int?, title: String, year: Int?, tmdbId: String,
        hasFile: Bool?, monitored: Bool?, status: String?, images: [ArrImage]?
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.tmdbId = tmdbId
        self.hasFile = hasFile
        self.monitored = monitored
        self.status = status
        self.images = images
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
    /// Run the search for an already-added movie.
    func triggerSearch(movieId: Int) async throws
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
            // Radarr reads the search flag from addOptions only: a top-level
            // copy is ignored and the movie lands without a search.
            "addOptions": ["searchForMovie": searchForMovie],
        ]
        let response: [String: Any] = try await http.post("movie", body: body)
        return response["id"] as? Int ?? 0
    }

    /// The search kicked off by `addOptions` runs with a non-Manual trigger,
    /// so Radarr only looks at `Monitored && IsAvailable()` movies and drops
    /// the rest ("Performing search for 0 movies"). POSTing the command
    /// through the API marks it Manual — the same path as clicking search in
    /// Radarr's UI — which bypasses the availability and delay filters.
    public func triggerSearch(movieId: Int) async throws {
        let _: [String: Any] = try await http.post("command", body: [
            "name": "MoviesSearch",
            "movieIds": [movieId],
        ])
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
    /// Run the search for an already-added series.
    func triggerSearch(seriesId: Int) async throws
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
            "seasonFolder": true,
            // seasons must be SeasonResource objects: bare ints make Sonarr's
            // JSON parser reject the whole request with 400.
            "seasons": seasons.map { ["seasonNumber": $0, "monitored": true] },
            // monitor + search only exist inside addOptions; Sonarr ignores
            // top-level copies, so no search would ever fire.
            "addOptions": [
                "monitor": monitor.rawValue,
                "searchForMissingEpisodes": searchForMissing,
            ] as [String: Any],
        ]
        let response: [String: Any] = try await http.post("series", body: body)
        return response["id"] as? Int ?? 0
    }

    /// Manual trigger (API commands always get it): skips delay profiles and
    /// aired/availability checks the add-time, non-Manual search would apply.
    public func triggerSearch(seriesId: Int) async throws {
        let _: [String: Any] = try await http.post("command", body: [
            "name": "SeriesSearch",
            "seriesId": seriesId,
        ])
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
