import Foundation
import ThisJellyFixCore

// MARK: - Result Model

public struct AuthenticationResult: Decodable, Sendable, Equatable {
    public let user: JellyfinUser
    public let accessToken: String
    public let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

// MARK: - Errors

public enum AuthError: LocalizedError, Equatable {
    case invalidCredentials
    case networkError(String)
    case serverError(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Usuario o contraseña incorrectos."
        case .networkError(let message):
            "Error de red: \(message)"
        case .serverError(let code):
            "Error del servidor (código \(code))."
        case .invalidResponse:
            "El servidor devolvió una respuesta inesperada."
        }
    }
}

// MARK: - Network Protocol

public protocol JellyfinNetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: JellyfinNetworkSession {}

// MARK: - Auth Protocol

public protocol JellyfinAuthenticating: Sendable {
    func authenticate(
        username: String,
        password: String,
        serverURL: URL,
        deviceId: String
    ) async throws -> AuthenticationResult
}

// MARK: - Implementation

public struct JellyfinAuthClient: JellyfinAuthenticating {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func authenticate(
        username: String,
        password: String,
        serverURL: URL,
        deviceId: String
    ) async throws -> AuthenticationResult {
        let endpoint = serverURL.appending(path: "Users/AuthenticateByName")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            authorizationHeader(deviceId: deviceId),
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let body = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AuthError.invalidCredentials
        default:
            throw AuthError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(AuthenticationResult.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    // MARK: - Private

    private func authorizationHeader(deviceId: String) -> String {
        "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(deviceId)\", Version=\"0.1\""
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
