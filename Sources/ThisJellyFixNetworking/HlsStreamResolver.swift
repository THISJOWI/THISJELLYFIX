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

        // Relative path → absolute URL + ApiKey (shared with the other
        // playback call sites — see StreamURLResolver).
        guard let finalURL = StreamURLResolver.resolve(transcodingUrl, serverURL: serverURL, token: token) else {
            TJFLog("HlsResolver: unparsable transcodingUrl=\(transcodingUrl)")
            return nil
        }

        TJFLog("HlsResolver: resolved item=\(itemId) → \(finalURL.absoluteString)")
        return finalURL
    }

    // MARK: - Warm-up

    /// Best-effort pre-flight: master playlist → variant playlist → first
    /// segment. Fetching them spins Jellyfin's transcoding session up ahead
    /// of the first PiP handoff, so the floating window fills near-instantly
    /// instead of paying the cold-start cost (seconds of black video).
    ///
    /// The segment GET routinely fails on the first tries (HTTP 5xx while the
    /// transcode is still spinning up → NSURLError -1011): a warm that gives
    /// up means a cold handoff, i.e. the floating window takes ~10s to appear
    /// and the user gives up first. So retry.
    /// - Returns: true only when the full pipeline (master → variant → first
    ///   segment) was fetched — the caller uses it to decide whether the
    ///   session may consider itself warmed.
    @discardableResult
    public func warmUp(hlsURL: URL, token: String) async -> Bool {
        for attempt in 1...3 {
            do {
                let master = try await fetchData(url: hlsURL, step: "master")
                guard let variant = Self.firstVariant(in: master, base: hlsURL) else {
                    TJFLog("HlsResolver: warm — no variant URI in master")
                    return false
                }
                let variantData = try await fetchData(url: appendingApiKey(variant, token: token), step: "variant")
                guard let segment = Self.firstSegment(in: variantData, base: variant) else {
                    TJFLog("HlsResolver: warm — no segment URI in variant")
                    return false
                }
                _ = try await fetchData(url: appendingApiKey(segment, token: token), step: "segment")
                TJFLog("HlsResolver: warmed HLS pipeline (attempt \(attempt))")
                return true
            } catch {
                TJFLog("HlsResolver: warm failed attempt \(attempt)/3 — \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        TJFLog("HlsResolver: warm gave up after 3 attempts — handoff will be cold")
        return false
    }

    /// First `#EXT-X-STREAM-INF` URI in a master playlist.
    static func firstVariant(in data: Data, base: URL) -> URL? {
        firstURI(in: data, after: "#EXT-X-STREAM-INF", base: base)
    }

    /// First `#EXTINF` URI (media segment) in a variant playlist.
    static func firstSegment(in data: Data, base: URL) -> URL? {
        firstURI(in: data, after: "#EXTINF", base: base)
    }

    private static func firstURI(in data: Data, after prefix: String, base: URL) -> URL? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        var wanted = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(prefix) {
                wanted = true
                continue
            }
            if wanted, !line.isEmpty, !line.hasPrefix("#") {
                return URL(string: line, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    private func fetchData(url: URL, step: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            TJFLog("HlsResolver: warm \(step) HTTP \(http.statusCode) url=\(url.absoluteString.prefix(120))")
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Adds `ApiKey` when the URL doesn't carry one already (segment URIs
    /// inside a playlist may omit it).
    private func appendingApiKey(_ url: URL, token: String) -> URL {
        StreamURLResolver.appendingApiKey(to: url, token: token)
    }
}
