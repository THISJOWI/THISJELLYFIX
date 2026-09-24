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
        let systemCode = Locale.current.language.languageCode?.identifier
        XCTAssertEqual(LanguagePreferences.systemDefault, systemCode)
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
}
