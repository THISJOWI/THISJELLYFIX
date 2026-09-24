import Foundation

/// Maps free-form chapter names (Jellyfin `ChapterInfo.Name`) to a
/// `SegmentType`. Pure function — fully unit-tested.
public enum ChapterClassifier {
    /// Returns the segment type for a chapter name, or `nil` when the name
    /// doesn't match any known intro/recap/credits pattern.
    ///
    /// Matching is case- and diacritic-insensitive, EN + ES patterns.
    /// Order matters: recap is checked first ("previously on …"), then intro
    /// (so "Opening Credits" resolves to intro, not credits), then credits.
    public static func classify(name: String) -> SegmentType? {
        let normalized = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if containsAny(normalized, ["recap", "previously", "resumen", "anteriormente"]) {
            return .recap
        }
        if containsAny(normalized, ["intro", "opening", "main title", "abertura", "apertura"]) {
            return .intro
        }
        if containsAny(normalized, ["credit", "ending", "outro", "closing", "fin de"]) {
            return .credits
        }
        return nil
    }

    /// Builds skip markers from chapters sorted by start time.
    /// Each chapter's end = the next chapter's start; the last chapter runs
    /// until the end of the video (`end == nil`).
    public static func markers(from chapters: [(start: Double, name: String?)]) -> [SegmentMarker] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var markers: [SegmentMarker] = []
        for (index, chapter) in sorted.enumerated() {
            guard let name = chapter.name, let type = classify(name: name) else { continue }
            let end = index + 1 < sorted.count ? sorted[index + 1].start : nil
            let marker = SegmentMarker(type: type, start: chapter.start, end: end)
            if marker.isValid {
                markers.append(marker)
            }
        }
        return markers.sorted { $0.start < $1.start }
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
