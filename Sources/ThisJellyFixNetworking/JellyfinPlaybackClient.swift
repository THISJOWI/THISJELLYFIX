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
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\", Version=\"0.1\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "MediaBrowser")

        let body = ["UserId": userId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(PlaybackInfo.self, from: data)
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
