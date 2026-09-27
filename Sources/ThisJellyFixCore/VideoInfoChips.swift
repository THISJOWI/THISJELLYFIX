import Foundation

/// One technical detail about a media source, rendered as a pill in the
/// detail screen's "Vídeo" section (size, resolution, dynamic range, codec…).
public struct VideoChip: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case size
        case resolution
        case range
        case codec
        case bitrate
        case fps

        public var systemImage: String {
            switch self {
            case .size: "internaldrive"
            case .resolution: "rectangle.on.rectangle"
            case .range: "circle.lefthalf.filled"
            case .codec: "chevron.left.forwardslash.chevron.right"
            case .bitrate: "gauge.with.dots.needle.33percent"
            case .fps: "film"
            }
        }
    }

    public let kind: Kind
    public let text: String

    public var id: Kind { kind }
    public var systemImage: String { kind.systemImage }
}

/// Turns a Jellyfin `MediaSource` into display-ready chips.
///
/// Pure so the detail screen stays a renderer and the formatting rules
/// (decimal separators, unit thresholds) stay unit-testable.
public enum VideoInfoChips {
    public static func chips(from source: MediaSource) -> [VideoChip] {
        let video = source.mediaStreams.first { $0.type == "Video" }
        var chips: [VideoChip] = []

        if let size = formatSize(source.size) {
            chips.append(VideoChip(kind: .size, text: size))
        }
        if let width = video?.width, let height = video?.height, width > 0, height > 0 {
            chips.append(VideoChip(kind: .resolution, text: "\(width)x\(height)"))
        }
        if let range = video?.videoRange, !range.isEmpty {
            chips.append(VideoChip(kind: .range, text: range.uppercased()))
        }
        if let codec = video?.codec, !codec.isEmpty {
            chips.append(VideoChip(kind: .codec, text: codec))
        }
        if let bitrate = formatBitrate(video?.bitRate) {
            chips.append(VideoChip(kind: .bitrate, text: bitrate))
        }
        if let fps = formatFps(video?.realFrameRate) {
            chips.append(VideoChip(kind: .fps, text: fps))
        }

        return chips
    }

    /// Bytes → "26.6 GB" / "999 MB". nil when absent or non-positive.
    public static func formatSize(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let value = Double(bytes)
        if value >= 1_000_000_000 {
            return String(format: "%.1f GB", value / 1_000_000_000)
        }
        return String(format: "%.0f MB", value / 1_000_000)
    }

    /// Bits per second → "30.06 Mbps" / "500 Kbps". nil when absent or non-positive.
    public static func formatBitrate(_ bitsPerSecond: Int64?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        let value = Double(bitsPerSecond)
        if value >= 1_000_000 {
            return String(format: "%.2f Mbps", value / 1_000_000)
        }
        return String(format: "%.0f Kbps", value / 1_000)
    }

    /// "24 fps" for whole numbers, "23.98 fps" otherwise. nil when absent or non-positive.
    public static func formatFps(_ fps: Double?) -> String? {
        guard let fps, fps > 0 else { return nil }
        if fps == fps.rounded() {
            return String(format: "%.0f fps", fps)
        }
        return String(format: "%.2f fps", fps)
    }
}
