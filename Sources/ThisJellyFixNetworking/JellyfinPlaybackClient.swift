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
        try await fetchPlaybackInfo(userId: userId, serverURL: serverURL, token: token, itemId: itemId, deviceProfile: nil)
    }

    /// Same as `fetchPlaybackInfo` but sends a Jellyfin DeviceProfile so the
    /// server answers with a specific playback plan (e.g. an HLS-only profile
    /// yields a `TranscodingUrl` usable by AVPlayer picture-in-picture).
    public func fetchPlaybackInfo(
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String,
        deviceProfile: PlaybackDeviceProfile?
    ) async throws -> PlaybackInfo {
        let url = serverURL.appendingPathComponent("Items/\(itemId)/PlaybackInfo")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(DeviceIdentifier().current())\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "Authorization"
        )

        var body: [String: Any] = [
            "UserId": userId,
            "DeviceId": DeviceIdentifier().current(),
            "MediaSourceId": itemId,
        ]
        if let deviceProfile {
            let profileData = try JSONEncoder().encode(deviceProfile)
            body["DeviceProfile"] = try JSONSerialization.jsonObject(with: profileData)
        }
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

// MARK: - Playback Reporting

/// Reports playback progress to Jellyfin so episodes get marked as watched.
/// Jellyfin considers an item "watched" when progress >= 90%.
public struct JellyfinPlaybackReporter: Sendable {
    private let session: any JellyfinNetworkSession

    /// Server-issued PlaySessionId from PlaybackInfo — echoed on every report
    /// so Jellyfin attributes progress to the right playback session.
    public var playSessionId: String? = nil

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    private func authHeader(token: String) -> String {
        "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(DeviceIdentifier().current())\", Version=\"0.1\", Token=\"\(token)\""
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

    /// Report that playback has started.
    public func reportPlaying(
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String,
        mediaSourceId: String
    ) async {
        await report(
            endpoint: "Sessions/Playing",
            userId: userId,
            serverURL: serverURL,
            token: token,
            itemId: itemId,
            mediaSourceId: mediaSourceId
        )
    }

    /// Report playback progress (call periodically).
    public func reportProgress(
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String,
        mediaSourceId: String,
        positionTicks: Int64,
        isPaused: Bool
    ) async {
        let body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "IsMuted": false,
        ]
        await report(
            endpoint: "Sessions/Playing/Progress",
            userId: userId,
            serverURL: serverURL,
            token: token,
            body: body
        )
    }

    /// Report that playback has stopped.
    public func reportStopped(
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String,
        mediaSourceId: String,
        positionTicks: Int64
    ) async {
        let body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PositionTicks": positionTicks,
        ]
        await report(
            endpoint: "Sessions/Playing/Stopped",
            userId: userId,
            serverURL: serverURL,
            token: token,
            body: body
        )
    }

    private func report(
        endpoint: String,
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String,
        mediaSourceId: String
    ) async {
        let body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
        ]
        await report(
            endpoint: endpoint,
            userId: userId,
            serverURL: serverURL,
            token: token,
            body: body
        )
    }

    private func report(
        endpoint: String,
        userId: String,
        serverURL: URL,
        token: String,
        body: [String: Any]
    ) async {
        let url = serverURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        var finalBody = body
        if let playSessionId {
            finalBody["PlaySessionId"] = playSessionId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: finalBody)

        let logBody: String
        if let data = request.httpBody, let str = String(data: data, encoding: .utf8) {
            logBody = str
        } else {
            logBody = "nil"
        }
        TJFLog("HTTP → \(endpoint) url=\(url.absoluteString) body=\(logBody)")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let responseStr = String(data: data, encoding: .utf8) ?? "binary"
                TJFLog("HTTP ← \(endpoint) status=\(http.statusCode) response=\(responseStr.prefix(300))")
            }
        } catch {
            TJFLog("HTTP ← \(endpoint) ERROR: \(error.localizedDescription)")
        }
    }
}
