import Foundation

/// How the server ended up delivering the stream we chose to play.
public enum PlayMethod: String, Sendable, Equatable {
    /// Original file served as-is (static=true).
    case directPlay
    /// Server remuxed the file (same codecs, different container).
    case directStream
    /// Server transcoded to HLS.
    case transcode
}

/// Client-side capability check for AVPlayer: given a `MediaSource` answer
/// (possibly produced without a device profile), pick the best URL AVPlayer
/// can actually open. Mirrors the ladder the old VLC path implied:
/// direct → remux → HLS.
public enum AVPlayerCapability {
    /// Containers AVPlayer opens from a plain progressive HTTP URL.
    public static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    public static let directPlayVideoCodecs: Set<String> = ["h264", "hevc", "mpeg4"]
    public static let directPlayAudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "flac"]

    /// True when the source's container+codecs are playable without remux.
    public static func canDirectPlay(_ source: MediaSource) -> Bool {
        let containers = (source.container ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !containers.isEmpty, containers.allSatisfy({ directPlayContainers.contains($0) }) else {
            return false
        }
        return streamsPlayable(source.mediaStreams)
    }

    /// True when only a container swap is needed (codecs AVPlayer decodes).
    /// Signals the server's remux DirectStreamUrl is acceptable.
    public static func canDirectStream(_ source: MediaSource) -> Bool {
        streamsPlayable(source.mediaStreams)
    }

    private static func streamsPlayable(_ streams: [MediaStream]) -> Bool {
        for stream in streams {
            guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { continue }
            switch stream.type {
            case "Video":
                guard directPlayVideoCodecs.contains(codec) else { return false }
            case "Audio":
                // Unknown audio codec on a direct URL: refuse and let the
                // server transcode — AVPlayer fails hard on e.g. dts.
                guard directPlayAudioCodecs.contains(codec) else { return false }
            default:
                continue
            }
        }
        return true
    }

    /// Picks the best URL + play method for AVPlayer from a MediaSource.
    ///
    /// - direct: source already AVPlayer-playable and directStreamUrl exists
    ///   over a supported container → `PlayMethod.directPlay`.
    /// - remux: codecs fine, container not (mkv, …) and directStreamUrl
    ///   exists (server remuxed) → `PlayMethod.directStream`.
    /// - HLS: everything else → transcodingUrl.
    /// - Last resort: any remaining directStreamUrl.
    public static func chooseURL(
        _ source: MediaSource,
        serverURL: URL
    ) -> (url: URL, method: PlayMethod)? {
        if canDirectPlay(source), let direct = source.directStreamUrl {
            if let url = resolve(direct, serverURL: serverURL) {
                return (url, .directPlay)
            }
        }
        if canDirectStream(source), let direct = source.directStreamUrl,
           let url = resolve(direct, serverURL: serverURL) {
            return (url, .directStream)
        }
        if let transcoding = source.transcodingUrl,
           let url = resolve(transcoding, serverURL: serverURL) {
            return (url, .transcode)
        }
        if let direct = source.directStreamUrl,
           let url = resolve(direct, serverURL: serverURL) {
            return (url, canDirectPlay(source) ? .directPlay : .directStream)
        }
        if let transcoding = source.transcodingUrl,
           let url = resolve(transcoding, serverURL: serverURL) {
            return (url, .transcode)
        }
        return nil
    }

    /// Server URLs are either absolute (`http(s)://…`) or site-relative
    /// (`/Videos/…`) — same normalization StreamURLResolver does.
    static func resolve(_ raw: String, serverURL: URL) -> URL? {
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: serverURL)?.absoluteURL
        }
        return URL(string: raw, relativeTo: serverURL)?.absoluteURL
    }
}
