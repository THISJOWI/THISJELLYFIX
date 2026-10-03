import Foundation
import ThisJellyFixCore

/// Builds the final playback URL from the strings PlaybackInfo returns
/// (`DirectStreamUrl`, `TranscodingUrl`).
///
/// Jellyfin answers with ABSOLUTE or RELATIVE paths depending on the server
/// configuration and endpoint: a bare "/Videos/…/master.m3u8?…" has no scheme,
/// and feeding such a URL to VLC/AVPlayer fails with an opaque error. The same
/// helper also guarantees the URL carries an `ApiKey` (segments/queries often
/// omit it → HTTP 401 mid-playback).
///
/// One implementation for every call site: DetailView, DirectPlayer and
/// HlsStreamResolver used to each re-implement this with subtle differences
/// (missing ApiKey, duplicate ApiKey, no relative resolution).
public enum StreamURLResolver {
    /// Resolves `value` against `serverURL` when it has no scheme and ensures
    /// the query authenticates with `token`. Returns nil only when the string
    /// is not a parseable URL at all.
    public static func resolve(_ value: String, serverURL: URL, token: String) -> URL? {
        // Build the absolute string directly: URL.appendingPathComponent
        // percent-encodes the "?" of the query.
        guard let components = URLComponents(string: value) else {
            return nil
        }
        let absolute: URL?
        if components.scheme == nil {
            let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
            let base = serverURL.absoluteString.hasSuffix("/")
                ? String(serverURL.absoluteString.dropLast())
                : serverURL.absoluteString
            absolute = URL(string: "\(base)/\(path)")
        } else {
            absolute = components.url
        }
        guard let absolute else { return nil }
        return appendingApiKey(to: absolute, token: token)
    }

    /// Adds `ApiKey` when the URL doesn't carry one already (case/underscore
    /// insensitive — servers send `ApiKey`, `api_key` or `apiKey`).
    public static func appendingApiKey(to url: URL, token: String) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var query = c.queryItems ?? []
        if !query.contains(where: { Self.isApiKey($0.name) }) {
            query.append(URLQueryItem(name: "ApiKey", value: token))
            c.queryItems = query
        }
        return c.url ?? url
    }

    /// True when a query item name denotes the API key.
    public static func isApiKey(_ name: String) -> Bool {
        name.lowercased().replacingOccurrences(of: "_", with: "") == "apikey"
    }

    /// AVPlayer-aware variant: picks direct → remux → HLS through
    /// `AVPlayerCapability` (a mkv direct URL would fail in AVPlayer), then
    /// resolves relative paths and authenticates. Falls back to the static
    /// stream endpoint when the source carries no usable URL.
    public static func playbackURL(
        source: MediaSource,
        serverURL: URL,
        itemId: String,
        token: String
    ) -> URL? {
        if let pick = AVPlayerCapability.chooseURL(source, serverURL: serverURL),
           let url = resolve(pick.url.absoluteString, serverURL: serverURL, token: token) {
            return url
        }
        return playbackURL(
            directStreamUrl: nil,
            transcodingUrl: nil,
            serverURL: serverURL,
            itemId: itemId,
            token: token
        )
    }

    /// Full playback URL for a PlaybackInfo media source: preferred
    /// `DirectStreamUrl`, else `TranscodingUrl`, else the static
    /// `/Videos/{id}/stream` fallback. All three branches resolve relative
    /// paths and authenticate — the transcoding branch used to skip the ApiKey
    /// entirely (HTTP 401 as soon as the segment is fetched).
    public static func playbackURL(
        directStreamUrl: String?,
        transcodingUrl: String?,
        serverURL: URL,
        itemId: String,
        token: String
    ) -> URL? {
        if let directStreamUrl {
            return resolve(directStreamUrl, serverURL: serverURL, token: token)
        }
        if let transcodingUrl {
            return resolve(transcodingUrl, serverURL: serverURL, token: token)
        }
        let base = serverURL.appendingPathComponent("Videos/\(itemId)/stream")
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "ApiKey", value: token),
        ]
        return c.url
    }
}
