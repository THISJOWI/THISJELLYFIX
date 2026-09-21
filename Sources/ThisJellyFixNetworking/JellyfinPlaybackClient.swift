import Foundation
import ThisJellyFixCore

public protocol JellyfinPlaybackProviding: Sendable {
    func fetchPlaybackInfo(userId: String, serverURL: URL, token: String, itemId: String) async throws -> PlaybackInfo
}

public struct JellyfinPlaybackClient: JellyfinPlaybackProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func fetchPlaybackInfo(userId: String, serverURL: URL, token: String, itemId: String) async throws -> PlaybackInfo {
        let url = serverURL.appendingPathComponent("Items/\(itemId)/PlaybackInfo")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let body = ["UserId": userId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        // Diagnostic: log raw response
        if let body = String(data: data, encoding: .utf8) {
            NSLog("[PlaybackClient] Status: %d, Body: %@", httpResponse.statusCode, String(body.prefix(500)))
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        NSLog("[PlaybackClient] Decoded mediaSources count: %d", decoded.mediaSources.count)
        return decoded
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
