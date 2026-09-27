import Foundation
import ThisJellyFixCore

/// Toggle-only endpoints for the per-user item flags shown in the detail
/// screen: favorite and watched. Absolute (not toggle) semantics — the caller
/// knows the desired state, so the UI can roll back optimistically.
public protocol JellyfinUserActionProviding: Sendable {
    func setFavorite(_ favorite: Bool, userId: String, serverURL: URL, token: String, itemId: String) async throws
    func setPlayed(_ played: Bool, userId: String, serverURL: URL, token: String, itemId: String) async throws
}

public struct JellyfinUserActionClient: JellyfinUserActionProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func setFavorite(
        _ favorite: Bool,
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String
    ) async throws {
        try await set(
            enabled: favorite,
            route: "UserFavoriteItems",
            userId: userId,
            serverURL: serverURL,
            token: token,
            itemId: itemId
        )
    }

    public func setPlayed(
        _ played: Bool,
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String
    ) async throws {
        try await set(
            enabled: played,
            route: "UserPlayedItems",
            userId: userId,
            serverURL: serverURL,
            token: token,
            itemId: itemId
        )
    }

    /// POST enables the flag, DELETE clears it.
    ///
    /// Route shape is `/UserFavoriteItems/{itemId}?userId=…` — the user id is a
    /// **query** parameter. The Emby-style `Users/{userId}/FavoriteItems/{itemId}`
    /// path is no longer routed and answers 404, which used to make the toggle
    /// look dead.
    private func set(
        enabled: Bool,
        route: String,
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String
    ) async throws {
        let url = serverURL
            .appendingPathComponent("\(route)/\(itemId)")
            .appending(queryItems: [URLQueryItem(name: "userId", value: userId)])

        var request = URLRequest(url: url)
        request.httpMethod = enabled ? "POST" : "DELETE"
        request.timeoutInterval = 10
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(DeviceIdentifier().current())\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "Authorization"
        )

        TJFLog("[UserAction] \(request.httpMethod ?? "?") \(route)/\(itemId)")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        TJFLog("[UserAction] \(request.httpMethod ?? "?") \(route)/\(itemId) status=\(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200...299: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }
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
