import Foundation

/// User-provided integration settings: TMDB metadata key plus the Radarr and
/// Sonarr endpoint + API key pairs.
///
/// Storage split by sensitivity: API keys live in the Keychain, URLs (not
/// secrets) in `UserDefaults` — the same split `@AppStorage` already uses for
/// playback preferences.
public struct IntegrationConfig: Sendable {
    public enum DefaultsKey {
        public static let radarrURL = "com.thisjellyfix.integration.radarrURL"
        public static let sonarrURL = "com.thisjellyfix.integration.sonarrURL"
    }

    public enum KeychainKey {
        public static let tmdbApiKey = "com.thisjellyfix.integration.tmdbApiKey"
        public static let radarrApiKey = "com.thisjellyfix.integration.radarrApiKey"
        public static let sonarrApiKey = "com.thisjellyfix.integration.sonarrApiKey"
    }

    private let defaults: UserDefaults
    private let keychain: any KeychainStoring

    public init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = KeychainStore(service: "com.thisjellyfix.integration")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: - TMDB

    public var tmdbApiKey: String? {
        get { keychain.read(key: KeychainKey.tmdbApiKey) }
        nonmutating set { setSecret(newValue, key: KeychainKey.tmdbApiKey) }
    }

    /// True when a metadata provider can be queried.
    public var hasMetadataProvider: Bool { !(tmdbApiKey ?? "").isEmpty }

    // MARK: - Radarr

    public var radarrURL: URL? {
        get { url(defaults.string(forKey: DefaultsKey.radarrURL)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: DefaultsKey.radarrURL) }
    }

    public var radarrApiKey: String? {
        get { keychain.read(key: KeychainKey.radarrApiKey) }
        nonmutating set { setSecret(newValue, key: KeychainKey.radarrApiKey) }
    }

    // MARK: - Sonarr

    public var sonarrURL: URL? {
        get { url(defaults.string(forKey: DefaultsKey.sonarrURL)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: DefaultsKey.sonarrURL) }
    }

    public var sonarrApiKey: String? {
        get { keychain.read(key: KeychainKey.sonarrApiKey) }
        nonmutating set { setSecret(newValue, key: KeychainKey.sonarrApiKey) }
    }

    // MARK: - Queries

    /// A service is usable only when both endpoint and key are present.
    public func isConfigured(service: DownloadService) -> Bool {
        switch service {
        case .radarr:
            return radarrURL != nil && !(radarrApiKey ?? "").isEmpty
        case .sonarr:
            return sonarrURL != nil && !(sonarrApiKey ?? "").isEmpty
        }
    }

    /// Endpoint for a configured service, `nil` when not configured.
    public func baseURL(service: DownloadService) -> URL? {
        isConfigured(service: service) ? (service == .radarr ? radarrURL : sonarrURL) : nil
    }

    /// API key for a configured service, `nil` when not configured.
    public func apiKey(service: DownloadService) -> String? {
        isConfigured(service: service) ? (service == .radarr ? radarrApiKey : sonarrApiKey) : nil
    }

    public func reset() {
        tmdbApiKey = nil
        radarrURL = nil
        radarrApiKey = nil
        sonarrURL = nil
        sonarrApiKey = nil
    }

    // MARK: - Private

    private func setSecret(_ value: String?, key: String) {
        if let value, !value.isEmpty {
            try? keychain.save(key: key, value: value)
        } else {
            try? keychain.delete(key: key)
        }
    }

    /// Normalize the stored endpoint: trim whitespace, drop a trailing slash
    /// so `appendingPathComponent("api/v3/…")` never produces a double slash.
    private func url(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }
}
