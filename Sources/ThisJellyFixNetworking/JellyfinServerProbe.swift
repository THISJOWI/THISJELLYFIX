import Foundation
import ThisJellyFixCore

public struct JellyfinPublicInfo: Decodable, Equatable, Sendable {
    public let serverName: String
    public let version: String
    public let id: String

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

public enum JellyfinConnectionError: LocalizedError {
    case invalidResponse
    case notAJellyfinServer

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "El servidor no devolvió una respuesta válida."
        case .notAJellyfinServer: "Esta dirección no parece ser un servidor Jellyfin compatible."
        }
    }
}

public protocol JellyfinServerProbing: Sendable {
    func publicInfo(at baseURL: URL) async throws -> JellyfinPublicInfo
}

public struct JellyfinServerProbe: JellyfinServerProbing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func publicInfo(at baseURL: URL) async throws -> JellyfinPublicInfo {
        let endpoint = baseURL.appending(path: "System/Info/Public")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("thisjellyfix/0.1", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinConnectionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw JellyfinConnectionError.notAJellyfinServer
        }

        do {
            return try JSONDecoder().decode(JellyfinPublicInfo.self, from: data)
        } catch {
            throw JellyfinConnectionError.notAJellyfinServer
        }
    }
}
