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
            forHTTPHeaderField: "Authorization"
        )

        let body: [String: Any] = [
            "UserId": userId,
            "DeviceId": UUID().uuidString,
            "MediaSourceId": itemId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        // Write raw response to file for debugging
        if let body = String(data: data, encoding: .utf8) {
            let log = "[PlaybackClient] URL: \(url)\n[PlaybackClient] Status: \(httpResponse.statusCode)\n[PlaybackClient] Body: \(body)\n"
            let logPath = NSTemporaryDirectory() + "tjf_playback.log"
            if let fd = fopen(logPath, "a") {
                fputs(log, fd)
                fclose(fd)
            }
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        let log2 = "[PlaybackClient] Decoded mediaSources count: \(decoded.mediaSources.count)\n"
        let logPath2 = NSTemporaryDirectory() + "tjf_playback.log"
        if let fd = fopen(logPath2, "a") {
            fputs(log2, fd)
            fclose(fd)
        }
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
