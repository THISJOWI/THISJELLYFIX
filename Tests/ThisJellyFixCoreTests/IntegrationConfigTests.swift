import XCTest
@testable import ThisJellyFixCore

final class IntegrationConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: InMemoryKeychain!
    private var config: IntegrationConfig!

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "IntegrationConfigTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = InMemoryKeychain()
        config = IntegrationConfig(defaults: defaults, keychain: keychain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Empty by default

    func testEmptyByDefault() {
        XCTAssertNil(config.tmdbApiKey)
        XCTAssertNil(config.radarrURL)
        XCTAssertNil(config.radarrApiKey)
        XCTAssertNil(config.sonarrURL)
        XCTAssertNil(config.sonarrApiKey)
        XCTAssertFalse(config.hasMetadataProvider)
        XCTAssertFalse(config.isConfigured(service: .radarr)
            && config.isConfigured(service: .sonarr))
    }

    // MARK: - TMDB key (secret → Keychain)

    func testTmdbApiKeyRoundTrip() {
        config.tmdbApiKey = "tmdb-secret"
        XCTAssertEqual(config.tmdbApiKey, "tmdb-secret")
        XCTAssertTrue(config.hasMetadataProvider)
        XCTAssertEqual(keychain.read(key: IntegrationConfig.KeychainKey.tmdbApiKey), "tmdb-secret")
    }

    func testClearingTmdbKeyRemovesSecret() {
        config.tmdbApiKey = "x"
        config.tmdbApiKey = nil
        XCTAssertNil(config.tmdbApiKey)
        XCTAssertFalse(config.hasMetadataProvider)
        XCTAssertNil(keychain.read(key: IntegrationConfig.KeychainKey.tmdbApiKey))
    }

    // MARK: - Service URLs (non-secret → UserDefaults)

    func testRadarrURLStoredInDefaults() {
        config.radarrURL = URL(string: "http://radarr.local:7878")
        XCTAssertEqual(config.radarrURL, URL(string: "http://radarr.local:7878"))
        XCTAssertEqual(
            defaults.string(forKey: IntegrationConfig.DefaultsKey.radarrURL),
            "http://radarr.local:7878"
        )
    }

    func testURLNormalizationAcceptsTrailingSlashAndMissingScheme() throws {
        config.radarrURL = try XCTUnwrap(URL(string: "http://radarr.local:7878/"))
        XCTAssertEqual(config.radarrURL?.absoluteString, "http://radarr.local:7878")
    }

    // MARK: - Per-service keys

    func testServiceKeysAreIndependent() {
        config.radarrApiKey = "radarr-key"
        config.sonarrApiKey = "sonarr-key"
        XCTAssertEqual(config.radarrApiKey, "radarr-key")
        XCTAssertEqual(config.sonarrApiKey, "sonarr-key")
        XCTAssertEqual(
            keychain.read(key: IntegrationConfig.KeychainKey.radarrApiKey),
            "radarr-key"
        )
        XCTAssertEqual(
            keychain.read(key: IntegrationConfig.KeychainKey.sonarrApiKey),
            "sonarr-key"
        )
    }

    // MARK: - isConfigured

    func testServiceIsConfiguredOnlyWithURLAndKey() {
        XCTAssertFalse(config.isConfigured(service: .radarr))
        config.radarrURL = URL(string: "http://r:7878")
        XCTAssertFalse(config.isConfigured(service: .radarr))
        config.radarrApiKey = "k"
        XCTAssertTrue(config.isConfigured(service: .radarr))
        XCTAssertFalse(config.isConfigured(service: .sonarr))
    }

    func testSonarrIsConfigured() {
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k"
        XCTAssertTrue(config.isConfigured(service: .sonarr))
    }

    // MARK: - Reset

    func testResetClearsEverything() {
        config.tmdbApiKey = "t"
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k2"
        config.reset()
        XCTAssertNil(config.tmdbApiKey)
        XCTAssertNil(config.radarrURL)
        XCTAssertNil(config.radarrApiKey)
        XCTAssertNil(config.sonarrURL)
        XCTAssertNil(config.sonarrApiKey)
        XCTAssertFalse(config.hasMetadataProvider)
    }
}

// MARK: - Test doubles

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func save(key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
    }

    func read(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = nil
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}
