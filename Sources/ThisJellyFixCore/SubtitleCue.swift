import Foundation

/// One timed subtitle line (SRT-style). Times are seconds from media start.
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

/// Minimal SRT parser for external subtitle files delivered by Jellyfin
/// (`/Videos/{id}/Subtitles/{i}/Stream.srt`). ASS/PGS never reach here —
/// the device profile asks the server to deliver those as text or burn them.
public enum SRTParser {
    /// Parses SRT content into cues sorted by start time. Malformed blocks
    /// are skipped — one bad timestamp must not kill the whole track.
    public static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        // Split on blank lines; each block = index / timing / text.
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let cue = parseBlock(lines: lines, timingIndex: timingIndex)
            else { continue }
            cues.append(cue)
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseBlock(lines: [String], timingIndex: Int) -> SubtitleCue? {
        let timing = lines[timingIndex]
        let parts = timing.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startRaw = parts[0].trimmingCharacters(in: .whitespaces)
        // End side may carry position/align settings after the timestamp.
        let endRaw = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first ?? ""
        guard let start = parseTimestamp(startRaw), let end = parseTimestamp(endRaw) else { return nil }

        let textLines = lines[(timingIndex + 1)...]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !textLines.isEmpty else { return nil }
        return SubtitleCue(start: start, end: end, text: textLines.joined(separator: "\n"))
    }

    /// `HH:MM:SS,mmm` or `HH:MM:SS.mmm` → seconds.
    static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// The cue active at `time`, or nil (binary search — the timer hits this
    /// every tick over potentially thousands of cues).
    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lo = 0
        var hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = cues[mid]
            if time < cue.start {
                hi = mid - 1
            } else if time >= cue.end {
                lo = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }
}
