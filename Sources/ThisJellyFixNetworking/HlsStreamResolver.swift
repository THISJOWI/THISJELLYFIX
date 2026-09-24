import Foundation
import ThisJellyFixCore

/// Resolves an HLS playlist URL (master.m3u8) for a media item.
///
/// Used by the iOS picture-in-picture feature: AVPlayer cannot play Jellyfin's
/// direct/remux streams (progressive MKV), so we ask the server with an
/// HLS-only DeviceProfile and take the `TranscodingUrl` it answers with.
/// Returns `nil` when the server offers no HLS — PiP is then unavailable and
/// playback degrades to VLC background audio.
public struct HlsStreamResolver: Sendable {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func resolveHlsURL(
        userId: String,
        serverURL: URL,
        token: String,
        itemId: String
    ) async -> URL? {
        let client = JellyfinPlaybackClient(session: session)
        guard let info = try? await client.fetchPlaybackInfo(
            userId: userId,
            serverURL: serverURL,
            token: token,
            itemId: itemId,
            deviceProfile: .pipHLS
        ),
        let source = info.mediaSources.first,
        let transcodingUrl = source.transcodingUrl
        else {
            TJFLog("HlsResolver: no TranscodingUrl for item=\(itemId)")
            return nil
        }

        // Jellyfin returns relative paths ("/Videos/…/master.m3u8?…") — resolve
        // against the server when the string has no scheme. Build the absolute
        // string directly: appendingPathComponent would percent-encode the "?".
        guard let components = URLComponents(string: transcodingUrl) else {
            TJFLog("HlsResolver: unparsable transcodingUrl=\(transcodingUrl)")
            return nil
        }
        var url: URL?
        if components.scheme == nil {
            let path = transcodingUrl.hasPrefix("/") ? String(transcodingUrl.dropFirst()) : transcodingUrl
            let base = serverURL.absoluteString.hasSuffix("/")
                ? String(serverURL.absoluteString.dropLast())
                : serverURL.absoluteString
            url = URL(string: "\(base)/\(path)")
        } else {
            url = components.url
        }

        guard var finalURL = url else { return nil }

        // Ensure the playlist/segments authenticate: add ApiKey when absent.
        if var c = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) {
            var query = c.queryItems ?? []
            if !query.contains(where: {
                $0.name.lowercased().replacingOccurrences(of: "_", with: "") == "apikey"
            }) {
                query.append(URLQueryItem(name: "ApiKey", value: token))
                c.queryItems = query
            }
            finalURL = c.url ?? finalURL
        }

        TJFLog("HlsResolver: resolved item=\(itemId) → \(finalURL.absoluteString)")
        return finalURL
    }
}
