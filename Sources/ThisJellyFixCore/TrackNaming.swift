import Foundation

/// Display-name derivation for audio/subtitle picker rows.
///
/// VLC reports raw names ("Track 2", "[ToonsHub] English - [English]") and
/// sometimes only an ISO code ("eng"); the Jellyfin server usually knows the
/// language and a descriptive title. These helpers merge both into a clean
/// title + caption without touching the raw ISO `language` field used by
/// `LanguagePreferences`.
public enum TrackNaming {

    public struct Display: Equatable, Sendable {
        public let title: String
        public let caption: String?

        public init(title: String, caption: String?) {
            self.title = title
            self.caption = caption
        }
    }

    /// Build the display row for one track.
    ///
    /// - Parameters:
    ///   - rawName: engine-reported track name (or trackId).
    ///   - languageCode: server language if known, else the engine's ISO-639 code.
    ///   - serverTitle: Jellyfin `DisplayTitle`/`Title` for the matched stream.
    ///   - index: zero-based position, used for the "Subtítulo N" fallback.
    ///   - fallbackPrefix: localized noun for the numbered fallback
    ///     ("Subtítulo", "Audio").
    public static func display(
        rawName: String?,
        languageCode: String?,
        serverTitle: String?,
        index: Int,
        fallbackPrefix: String = "Subtítulo"
    ) -> Display {
        let lang = languageDisplayName(languageCode)
        let group = leadingGroup(rawName)
        var desc = firstMeaningful([serverTitle, rawName])

        // Channel layout ("Stereo", "5.1") is caption material, not a title.
        var channel: String? = nil
        if let candidate = desc, channelWords.contains(normalizeLoose(candidate)) {
            channel = candidate
            desc = nil
        }

        let title: String
        if let desc, lang == nil || !isLanguageAlias(desc, languageCode: languageCode) {
            title = desc
        } else if let lang {
            title = lang
        } else if let channel {
            title = channel
        } else {
            title = "\(fallbackPrefix) \(index + 1)"
        }

        var parts: [String] = []
        if title != lang, let lang { parts.append(lang) }
        if let group { parts.append(group) }
        if let channel, title != channel { parts.append(channel) }

        return Display(title: title, caption: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// Spanish display name for an ISO-639 code ("eng" → "Inglés").
    /// Returns nil for unknown codes, "und", or "mul".
    public static func languageDisplayName(_ code: String?) -> String? {
        guard let normalized = normalize(code) else { return nil }
        return table[normalized]?.es
    }

    /// Strip decorations from a raw track name:
    /// leading "[Group]", redundant segments ("English - [English]"), and
    /// trailing codec tokens ("Spanish · SRT"). Returns nil when nothing
    /// meaningful remains (e.g. "Track 2").
    public static func cleanTrackName(_ raw: String?) -> String? {
        firstMeaningful([raw])
    }

    // MARK: - Parsing

    /// Leading "[Group]" tag, without brackets.
    private static func leadingGroup(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let pattern = #"^\[([^\]]+)\]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        let group = String(raw[range]).trimmingCharacters(in: .whitespaces)
        return group.isEmpty ? nil : group
    }

    /// First candidate that survives cleaning and isn't a bare track number.
    private static func firstMeaningful(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let cleaned = clean(candidate) else { continue }
            if !isGeneric(cleaned) { return cleaned }
        }
        return nil
    }

    private static func clean(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }

        // Drop a leading "[Group]" tag.
        if let group = leadingGroup(s), let range = s.range(of: "[\(group)]") {
            s = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // Split on common separators, strip brackets, dedupe repeated segments.
        var flattened = s
        for sep in [" - ", " – ", " — ", " | ", " · ", "|", "–", "—"] {
            flattened = flattened.replacingOccurrences(of: sep, with: "\u{1F}")
        }
        var segments: [String] = []
        for part in flattened.components(separatedBy: "\u{1F}") {
            var seg = part.trimmingCharacters(in: .whitespaces)
            seg = seg.replacingOccurrences(of: "[", with: "")
            seg = seg.replacingOccurrences(of: "]", with: "")
            seg = seg.trimmingCharacters(in: .whitespaces)
            guard !seg.isEmpty else { continue }
            if segments.contains(where: { $0.caseInsensitiveCompare(seg) == .orderedSame }) { continue }
            segments.append(seg)
        }
        guard !segments.isEmpty else { return nil }

        // Drop codec tokens ("Spanish · SRT" → "Spanish").
        segments = segments.filter { !codecTokens.contains($0.lowercased()) }

        let joined = segments.joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    private static let codecTokens: Set<String> = [
        "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "ttml",
        "mov_text", "mov-text", "pgs", "pgssub", "dvdsub", "text",
    ]

    private static func isGeneric(_ s: String) -> Bool {
        let pattern = #"^(track|subtitle|sub|pista|audio|text)[\s_-]*\d*$"#
        return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Channel-layout words that describe *how* a track sounds, not *what* it is.
    private static let channelWords: Set<String> = [
        "stereo", "mono", "surround", "51", "71", "left", "right",
        "center", "centre", "dolbyatmos", "dolbydigital",
    ]

    /// Exact match of a cleaned name against the known words for a language
    /// ("English"/"Inglés"/"eng" all alias `en`), after normalizing case and
    /// diacritics.
    private static func isLanguageAlias(_ s: String, languageCode: String?) -> Bool {
        guard let normalized = normalize(languageCode), let lang = table[normalized] else { return false }
        let needle = normalizeLoose(s)
        return lang.aliases.contains { normalizeLoose($0) == needle }
    }

    // MARK: - Name → code lookup

    /// Reverse index of every alias (English name, native name, ISO 639-1/2/T
    /// code) to its canonical ISO 639-1 code: `"Spanish"`/`"Español"`/`"spa"`
    /// → `"es"`. Keys are folded with `normalizeLoose` (case + diacritics).
    private static let aliasToCode: [String: String] = {
        var map: [String: String] = [:]
        for key in table.keys where key.count == 2 {
            guard let lang = table[key] else { continue }
            for alias in lang.aliases { map[normalizeLoose(alias)] = key }
            map[normalizeLoose(key)] = key
        }
        return map
    }()

    /// Resolve a track's `language` field — an ISO code OR a display name —
    /// to its ISO 639-1 code. Returns nil for unknown/undetermined values.
    /// Used by preference matching, where VLC frequently reports names.
    public static func languageCode(matching raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = normalizeLoose(trimmed)
        guard !folded.isEmpty else { return nil }
        if let exact = aliasToCode[folded] { return exact }
        // Strip a regional/qualifier suffix: "Español (Latinoamérica)" → "español".
        if let cut = trimmed.firstIndex(where: { "([,;".contains($0) }) {
            let head = normalizeLoose(String(trimmed[..<cut]))
            if let code = aliasToCode[head] { return code }
        }
        return nil
    }

    private static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).first
        guard let base, !base.isEmpty else { return nil }
        return String(base)
    }

    private static func normalizeLoose(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Language table

    private struct Lang {
        let es: String
        let aliases: [String]
    }

    private static func lang(_ es: String, _ en: String, _ extra: String...) -> Lang {
        Lang(es: es, aliases: [es, en] + extra)
    }

    private static let table: [String: Lang] = {
        var t: [String: Lang] = [:]
        func add(_ l: Lang, _ keys: String...) { for k in keys { t[k] = l } }

        add(lang("Inglés", "English", "en", "eng"), "en", "eng")
        add(lang("Español", "Spanish", "es", "spa", "cast"), "es", "spa")
        add(lang("Francés", "French", "fr", "fra", "fre"), "fr", "fra", "fre")
        add(lang("Alemán", "German", "de", "deu", "ger"), "de", "deu", "ger")
        add(lang("Italiano", "Italian", "it", "ita"), "it", "ita")
        add(lang("Portugués", "Portuguese", "pt", "por"), "pt", "por")
        add(lang("Árabe", "Arabic", "ar", "ara"), "ar", "ara")
        add(lang("Japonés", "Japanese", "ja", "jpn"), "ja", "jpn")
        add(lang("Coreano", "Korean", "ko", "kor"), "ko", "kor")
        add(lang("Chino", "Chinese", "zh", "zho", "chi"), "zh", "zho", "chi")
        add(lang("Ruso", "Russian", "ru", "rus"), "ru", "rus")
        add(lang("Neerlandés", "Dutch", "nl", "nld", "dut"), "nl", "nld", "dut")
        add(lang("Sueco", "Swedish", "sv", "swe"), "sv", "swe")
        add(lang("Noruego", "Norwegian", "no", "nor", "nb", "nn"), "no", "nor", "nb", "nn")
        add(lang("Danés", "Danish", "da", "dan"), "da", "dan")
        add(lang("Finlandés", "Finnish", "fi", "fin"), "fi", "fin")
        add(lang("Polaco", "Polish", "pl", "pol"), "pl", "pol")
        add(lang("Turco", "Turkish", "tr", "tur"), "tr", "tur")
        add(lang("Hebreo", "Hebrew", "he", "heb"), "he", "heb")
        add(lang("Hindi", "Hindi", "hi", "hin"), "hi", "hin")
        add(lang("Tailandés", "Thai", "th", "tha"), "th", "tha")
        add(lang("Vietnamita", "Vietnamese", "vi", "vie"), "vi", "vie")
        add(lang("Indonesio", "Indonesian", "id", "ind"), "id", "ind")
        add(lang("Catalán", "Catalan", "ca", "cat"), "ca", "cat")
        add(lang("Euskara", "Basque", "eu", "eus", "baq"), "eu", "eus", "baq")
        add(lang("Gallego", "Galician", "gl", "glg"), "gl", "glg")
        add(lang("Checo", "Czech", "cs", "ces", "cze"), "cs", "ces", "cze")
        add(lang("Griego", "Greek", "el", "ell", "gre"), "el", "ell", "gre")
        add(lang("Húngaro", "Hungarian", "hu", "hun"), "hu", "hun")
        add(lang("Rumano", "Romanian", "ro", "ron", "rum"), "ro", "ron", "rum")
        add(lang("Ucraniano", "Ukrainian", "uk", "ukr"), "uk", "ukr")
        add(lang("Persa", "Persian", "fa", "fas", "per"), "fa", "fas", "per")
        add(lang("Urdu", "Urdu", "ur", "urd"), "ur", "urd")
        add(lang("Tamil", "Tamil", "ta", "tam"), "ta", "tam")
        add(lang("Telugu", "Telugu", "te", "tel"), "te", "tel")
        add(lang("Bengalí", "Bengali", "bn", "ben"), "bn", "ben")
        add(lang("Malayalam", "Malayalam", "ml", "mal"), "ml", "mal")
        add(lang("Marathi", "Marathi", "mr", "mar"), "mr", "mar")
        add(lang("Panyabí", "Punjabi", "pa", "pan"), "pa", "pan")
        add(lang("Armenio", "Armenian", "hy", "hye", "arm"), "hy", "hye", "arm")
        add(lang("Búlgaro", "Bulgarian", "bg", "bul"), "bg", "bul")
        add(lang("Serbio", "Serbian", "sr", "srp"), "sr", "srp")
        add(lang("Croata", "Croatian", "hr", "hrv"), "hr", "hrv")
        add(lang("Eslovaco", "Slovak", "sk", "slk", "slo"), "sk", "slk", "slo")
        add(lang("Esloveno", "Slovenian", "sl", "slv"), "sl", "slv")
        add(lang("Lituano", "Lithuanian", "lt", "lit"), "lt", "lit")
        add(lang("Letón", "Latvian", "lv", "lav"), "lv", "lav")
        add(lang("Estonio", "Estonian", "et", "est"), "et", "est")
        add(lang("Islandés", "Icelandic", "is", "isl"), "is", "isl")
        add(lang("Irlandés", "Irish", "ga", "gle"), "ga", "gle")
        add(lang("Galés", "Welsh", "cy", "cym", "wel"), "cy", "cym", "wel")
        add(lang("Macedonio", "Macedonian", "mk", "mkd", "mac"), "mk", "mkd", "mac")
        add(lang("Albanés", "Albanian", "sq", "sqi", "alb"), "sq", "sqi", "alb")
        add(lang("Bosnio", "Bosnian", "bs", "bos"), "bs", "bos")
        add(lang("Georgiano", "Georgian", "ka", "kat", "geo"), "ka", "kat", "geo")
        add(lang("Azerí", "Azerbaijani", "az", "aze"), "az", "aze")
        add(lang("Kazajo", "Kazakh", "kk", "kaz"), "kk", "kaz")
        add(lang("Uzbeco", "Uzbek", "uz", "uzb"), "uz", "uzb")
        add(lang("Mongol", "Mongolian", "mn", "mon"), "mn", "mon")
        add(lang("Birmano", "Burmese", "my", "mya", "bur"), "my", "mya", "bur")
        add(lang("Jemer", "Khmer", "km", "khm"), "km", "khm")
        add(lang("Lao", "Lao", "lo", "lao"), "lo", "lao")
        add(lang("Cingalés", "Sinhala", "si", "sin"), "si", "sin")
        add(lang("Amárico", "Amharic", "am", "amh"), "am", "amh")
        add(lang("Suajili", "Swahili", "sw", "swa"), "sw", "swa")
        add(lang("Somalí", "Somali", "so", "som"), "so", "som")
        add(lang("Criollo haitiano", "Haitian Creole", "ht", "hat"), "ht", "hat")
        add(lang("Malayo", "Malay", "ms", "msa", "may"), "ms", "msa", "may")
        add(lang("Javanés", "Javanese", "jv", "jav"), "jv", "jav")
        return t
    }()
}
