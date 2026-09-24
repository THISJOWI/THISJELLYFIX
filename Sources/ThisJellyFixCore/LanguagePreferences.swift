import Foundation

/// User language preferences for playback. Persisted in `UserDefaults`
/// (same store `@AppStorage` writes to), so the player picks them up live.
///
/// Preference applies ONLY when tracks load (player start); a manual track
/// change mid-playback is respected until the next item.
public struct LanguagePreferences: Sendable, Equatable {
    /// Preferred audio language code (ISO 639-1, e.g. "es"), nil = no preference.
    public var preferredAudio: String?
    /// Preferred subtitle language code, nil = no preference (subtitles untouched).
    public var preferredSubtitles: String?

    public enum Key {
        public static let audio = "lang.audio"
        public static let subtitles = "lang.subtitles"
    }

    public init(preferredAudio: String? = nil, preferredSubtitles: String? = nil) {
        self.preferredAudio = preferredAudio
        self.preferredSubtitles = preferredSubtitles
    }

    /// Device language — the pre-selected default in the profile pickers.
    public static var systemDefault: String? {
        Locale.current.language.languageCode?.identifier
    }

    public static func current(_ defaults: UserDefaults = .standard) -> LanguagePreferences {
        LanguagePreferences(
            preferredAudio: defaults.string(forKey: Key.audio),
            preferredSubtitles: defaults.string(forKey: Key.subtitles)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(preferredAudio, forKey: Key.audio)
        defaults.set(preferredSubtitles, forKey: Key.subtitles)
    }

    // MARK: - Matching

    /// Compare preferred vs track language tolerantly:
    /// case-insensitive, region variants (`es-ES`, `es_MX`) match base codes,
    /// ISO 639-2/T codes (`spa`) match 639-1 (`es`).
    public static func matches(preferred: String?, trackLanguage: String?) -> Bool {
        guard let preferred, !preferred.isEmpty else { return false }
        guard let trackLanguage, !trackLanguage.isEmpty else { return false }

        let p = canonical(preferred)
        let t = canonical(trackLanguage)
        guard !p.isEmpty, !t.isEmpty else { return false }
        if p == t { return true }
        // Region variant: compare base codes both ways (pt-BR vs pt)
        return base(p) == base(t)
    }

    /// First track whose language matches `preferred`, nil otherwise
    /// (fallback: caller leaves selection untouched).
    public static func selectTrack<T>(
        in tracks: [T],
        preferred: String?,
        language: (T) -> String?
    ) -> T? {
        guard let preferred, !preferred.isEmpty else { return nil }
        return tracks.first { matches(preferred: preferred, trackLanguage: language($0)) }
    }

    /// Lowercase, strip region, map ISO 639-2/T → 639-1.
    private static func canonical(_ code: String) -> String {
        let lower = code.lowercased().replacingOccurrences(of: "_", with: "-")
        let baseCode = base(lower)
        return iso6392To6391[baseCode] ?? baseCode
    }

    /// Base language code without region (`es-ES` → `es`).
    private static func base(_ code: String) -> String {
        String(code.prefix(while: { $0 != "-" && $0 != "." }))
    }

    /// Common ISO 639-2/T (and /B) codes VLC/Jellyfin report → 639-1.
    private static let iso6392To6391: [String: String] = [
        "spa": "es", "eng": "en", "jpn": "ja", "por": "pt", "fra": "fr",
        "fre": "fr", "deu": "de", "ger": "de", "ita": "it", "rus": "ru",
        "kor": "ko", "zho": "zh", "chi": "zh", "ara": "ar", "nld": "nl",
        "dut": "nl", "pol": "pl", "tur": "tr", "swe": "sv", "nor": "no",
        "dan": "da", "fin": "fi", "gre": "el", "ell": "el", "heb": "he",
        "hin": "hi", "tha": "th", "vie": "vi", "ind": "id", "may": "ms",
        "ukr": "uk", "ces": "cs", "cze": "cs", "ron": "ro", "rum": "ro",
        "hun": "hu", "cat": "ca", "eus": "eu", "glg": "gl",
    ]
}
