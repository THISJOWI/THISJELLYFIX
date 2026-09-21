import Foundation
import ThisJellyFixCore

// MARK: - Response Wrappers

struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinMediaItem]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinViewsResponse: Decodable {
    let items: [LibraryView]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinSeasonsResponse: Decodable {
    let items: [JellyfinSeason]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinEpisodesResponse: Decodable {
    let items: [JellyfinEpisode]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// MARK: - Protocol

public protocol JellyfinLibraryProviding: Sendable {
    func fetchViews(userId: String, serverURL: URL, token: String) async throws -> [LibraryView]
    func fetchItems(userId: String, serverURL: URL, token: String, parentId: String?, includeTypes: String?, limit: Int, orderBy: String, filters: String?) async throws -> [JellyfinMediaItem]
    func fetchSeasons(userId: String, serverURL: URL, token: String, seriesId: String) async throws -> [JellyfinSeason]
    func fetchEpisodes(userId: String, serverURL: URL, token: String, seriesId: String, seasonId: String) async throws -> [JellyfinEpisode]
    func fetchResumeItems(userId: String, serverURL: URL, token: String, limit: Int) async throws -> [JellyfinMediaItem]
}

public struct JellyfinLibraryClient: JellyfinLibraryProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func fetchViews(userId: String, serverURL: URL, token: String) async throws -> [LibraryView] {
        let url = serverURL.appendingPathComponent("Users/\(userId)/Views")
        let data = try await fetchData(from: url, token: token)
        let response = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
        return response.items
    }

    public func fetchItems(
        userId: String,
        serverURL: URL,
        token: String,
        parentId: String?,
        includeTypes: String?,
        limit: Int,
        orderBy: String,
        filters: String?
    ) async throws -> [JellyfinMediaItem] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("Users/\(userId)/Items"),
            resolvingAgainstBaseURL: false
        )!

        var queryItems = [
            URLQueryItem(name: "OrderBy", value: orderBy),
            URLQueryItem(name: "Descending", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]

        if let parentId {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        if let includeTypes {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes))
        }
        if let filters {
            queryItems.append(URLQueryItem(name: "Filters", value: filters))
        }

        components.queryItems = queryItems

        let data = try await fetchData(from: components.url!, token: token)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }

    public func fetchSeasons(userId: String, serverURL: URL, token: String, seriesId: String) async throws -> [JellyfinSeason] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("Shows/\(seriesId)/Seasons"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "userId", value: userId),
        ]

        let data = try await fetchData(from: components.url!, token: token)
        let response = try JSONDecoder().decode(JellyfinSeasonsResponse.self, from: data)
        return response.items
    }

    public func fetchEpisodes(userId: String, serverURL: URL, token: String, seriesId: String, seasonId: String) async throws -> [JellyfinEpisode] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("Shows/\(seriesId)/Episodes"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "seasonId", value: seasonId),
        ]

        let data = try await fetchData(from: components.url!, token: token)
        let response = try JSONDecoder().decode(JellyfinEpisodesResponse.self, from: data)
        return response.items
    }

    public func fetchResumeItems(userId: String, serverURL: URL, token: String, limit: Int) async throws -> [JellyfinMediaItem] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("Users/\(userId)/Items/Resume"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "Recursive", value: "true"),
        ]

        let data = try await fetchData(from: components.url!, token: token)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }

    // MARK: - Private

    private func fetchData(from url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        return data
    }

    private var deviceOS: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }
}

public enum LibraryError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Respuesta inválida del servidor."
        case .unauthorized: "Sesión expirada. Inicia sesión de nuevo."
        case .serverError(let code): "Error del servidor (código \(code))."
        }
    }
}
