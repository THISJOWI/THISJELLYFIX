import XCTest
@testable import ThisJellyFixCore

final class LanguagePreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "LanguagePreferencesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testNoPreferenceWhenUnset() {
        let prefs = LanguagePreferences.current(defaults)
        XCTAssertNil(prefs.preferredAudio)
        XCTAssertNil(prefs.preferredSubtitles)
    }

    func testRoundTripPersistence() {
        var prefs = LanguagePreferences()
        prefs.preferredAudio = "ja"
        prefs.preferredSubtitles = "en"
        prefs.save(to: defaults)

        let loaded = LanguagePreferences.current(defaults)
        XCTAssertEqual(loaded.preferredAudio, "ja")
        XCTAssertEqual(loaded.preferredSubtitles, "en")
    }

    func testSystemLanguageDefault() {
        // Preferred languages are authoritative (Locale.current follows region).
        let expected = Locale.preferredLanguages
            .first { !LanguagePreferences.baseLanguageCode($0).isEmpty }
            .map { LanguagePreferences.baseLanguageCode($0) }
        XCTAssertEqual(LanguagePreferences.systemDefault, expected)
        XCTAssertNotNil(LanguagePreferences.systemDefault)
    }

    func testBaseLanguageCodeNormalization() {
        XCTAssertEqual(LanguagePreferences.baseLanguageCode("es-ES"), "es")
        XCTAssertEqual(LanguagePreferences.baseLanguageCode("pt_BR"), "pt")
        XCTAssertEqual(LanguagePreferences.baseLanguageCode("zh-Hans-CN"), "zh")
        XCTAssertEqual(LanguagePreferences.baseLanguageCode("EN"), "en")
        XCTAssertEqual(LanguagePreferences.baseLanguageCode(""), "")
    }

    // MARK: - Language matching

    func testExactMatch() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "es"))
    }

    func testRegionVariantMatchesBase() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "es-ES"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "es_MX"))
    }

    func testBaseMatchesRegionVariant() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "pt-BR", trackLanguage: "pt"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "EN", trackLanguage: "en"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "ES-419"))
    }

    func testDifferentLanguagesDoNotMatch() {
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: "en"))
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: "ja"))
    }

    func testNilTrackLanguageDoesNotMatch() {
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: nil))
    }

    func testNilPreferenceNeverMatches() {
        XCTAssertFalse(LanguagePreferences.matches(preferred: nil, trackLanguage: "es"))
    }

    func testEmptyPreferenceNeverMatches() {
        XCTAssertFalse(LanguagePreferences.matches(preferred: "", trackLanguage: "es"))
    }

    // MARK: - Track selection

    func testSelectsFirstMatchingTrack() {
        let tracks = [
            AudioTrack(id: 0, name: "English", language: "en"),
            AudioTrack(id: 1, name: "Spanish", language: "spa"),
            AudioTrack(id: 2, name: "Spanish LAT", language: "es-419"),
        ]
        let match = LanguagePreferences.selectTrack(in: tracks, preferred: "es") { $0.language }
        XCTAssertEqual(match?.id, 1)
    }

    func testNoMatchReturnsNil() {
        let tracks = [AudioTrack(id: 0, name: "English", language: "en")]
        let match = LanguagePreferences.selectTrack(in: tracks, preferred: "ja") { $0.language }
        XCTAssertNil(match)
    }

    func testNilPreferenceReturnsNil() {
        let tracks = [AudioTrack(id: 0, name: "English", language: "en")]
        let match = LanguagePreferences.selectTrack(in: tracks, preferred: nil) { $0.language }
        XCTAssertNil(match)
    }

    // MARK: - Language names (VLC reports names, not codes)

    func testEnglishNameMatchesPreferredEnglish() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "en", trackLanguage: "English"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "en", trackLanguage: "Inglés"))
    }

    func testSpanishNameMatchesPreferredSpanish() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "Spanish"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "Español"))
    }

    func testTrackNameMatchesPreferredName() {
        // Both sides may be display names (e.g. preference seeded from a locale name).
        XCTAssertTrue(LanguagePreferences.matches(preferred: "Spanish", trackLanguage: "spa"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "Inglés", trackLanguage: "English"))
    }

    func testRegionalizedNameMatchesBaseCode() {
        XCTAssertTrue(LanguagePreferences.matches(preferred: "es", trackLanguage: "Español (Latinoamérica)"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "en", trackLanguage: "English (US)"))
        XCTAssertTrue(LanguagePreferences.matches(preferred: "pt", trackLanguage: "Português, Brasileiro"))
    }

    func testUnknownLanguageMarkersDoNotMatch() {
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: "und"))
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: "mul"))
        XCTAssertFalse(LanguagePreferences.matches(preferred: "es", trackLanguage: "zxx"))
        XCTAssertFalse(LanguagePreferences.matches(preferred: "en", trackLanguage: "und"))
    }

    func testSelectsTrackByLanguageNameWhenCodeMissing() {
        let tracks = [
            AudioTrack(id: 0, name: "Track 1", language: nil),
            AudioTrack(id: 1, name: "Español", language: "Spanish"),
            AudioTrack(id: 2, name: "Track 3", language: nil),
        ]
        let match = LanguagePreferences.selectTrack(in: tracks, preferred: "es") { $0.language }
        XCTAssertEqual(match?.id, 1)
    }

    func testSystemDefaultSelectsMatchingTrack() {
        // The reported bug: preference unset → player must fall back to system language.
        guard let system = LanguagePreferences.systemDefault else {
            return XCTFail("systemDefault must exist")
        }
        let tracks = [
            AudioTrack(id: 0, name: "English", language: "English"),
            AudioTrack(id: 1, name: "Español", language: "Español"),
        ]
        let match = LanguagePreferences.selectTrack(in: tracks, preferred: system) { $0.language }
        XCTAssertNotNil(match, "system language \(system) must match one of the name-labelled tracks")
    }

    func testNoPreferenceConstantSelectsNothing() {
        XCTAssertEqual(LanguagePreferences.noPreference, "")
        let tracks = [AudioTrack(id: 0, name: "Español", language: "es")]
        XCTAssertNil(
            LanguagePreferences.selectTrack(in: tracks, preferred: LanguagePreferences.noPreference) { $0.language }
        )
    }
}
