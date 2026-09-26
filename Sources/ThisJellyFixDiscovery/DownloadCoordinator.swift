import Foundation
import ThisJellyFixCore
import Observation

// MARK: - Errors

public enum DownloadCoordinatorError: LocalizedError, Equatable {
    case serviceNotConfigured(DownloadService)
    case lookupReturnedNothing

    public var errorDescription: String? {
        switch self {
        case .serviceNotConfigured(let service):
            "\(service == .radarr ? "Radarr" : "Sonarr") no está configurado en Ajustes."
        case .lookupReturnedNothing:
            "El servicio no encontró ese título."
        }
    }
}

// MARK: - Coordinator

/// Owns the download list: submits orders to Radarr/Sonarr, tracks the
/// remote queue, and flips entries to `.available` once Jellyfin picks
/// the file up.
///
/// Polling cadence lives in the UI layer; this type only exposes
/// `refresh()` so the panel and tests decide when to call it.
@Observable
public final class DownloadCoordinator {
    public private(set) var entries: [DownloadEntry] = []
    /// Last refresh failure (nil = healthy). UI shows it as a banner.
    public private(set) var lastRefreshError: Error?

    private let config: IntegrationConfig
    private let radarr: (any RadarrProviding)?
    private let sonarr: (any SonarrProviding)?

    public init(
        config: IntegrationConfig,
        radarr: (any RadarrProviding)? = nil,
        sonarr: (any SonarrProviding)? = nil
    ) {
        self.config = config
        self.radarr = radarr
        self.sonarr = sonarr
    }

    /// Build the default coordinator from the user's stored settings.
    public static func live(config: IntegrationConfig) -> DownloadCoordinator {
        var radarr: (any RadarrProviding)?
        if let url = config.radarrURL, let key = config.radarrApiKey, !key.isEmpty {
            radarr = RadarrClient(baseURL: url, apiKey: key)
        }
        var sonarr: (any SonarrProviding)?
        if let url = config.sonarrURL, let key = config.sonarrApiKey, !key.isEmpty {
            sonarr = SonarrClient(baseURL: url, apiKey: key)
        }
        return DownloadCoordinator(config: config, radarr: radarr, sonarr: sonarr)
    }

    // MARK: Submit

    /// Send the download order. The entry appears immediately in
    /// `.submitting` so the UI reacts before the network answers.
    public func submit(_ item: CatalogItem, options: AddOptions? = nil) async throws {
        let service = item.downloadService
        guard config.isConfigured(service: service) else {
            throw DownloadCoordinatorError.serviceNotConfigured(service)
        }

        let localId = "local-\(service.rawValue)-\(item.tmdbId ?? item.id)"
        upsert(DownloadEntry(
            id: localId, service: service, title: item.title,
            tmdbId: item.tmdbId, state: .submitting
        ))

        do {
            switch service {
            case .radarr:
                try await submitMovie(item, options: options)
            case .sonarr:
                try await submitSeries(item, options: options)
            }
        } catch {
            set(state: .failed("\(error)"), for: localId)
            throw error
        }
    }

    private func submitMovie(_ item: CatalogItem, options: AddOptions?) async throws {
        guard let radarr, let tmdbId = item.tmdbId else {
            throw DownloadCoordinatorError.serviceNotConfigured(.radarr)
        }
        let resolved = try await resolve(options: options, radarr: radarr)
        _ = try await radarr.addMovie(
            tmdbId: tmdbId,
            title: item.title,
            qualityProfileId: resolved.qualityProfileId,
            rootFolderPath: resolved.rootFolderPath,
            monitored: resolved.monitored,
            searchForMovie: resolved.searchNow
        )
    }

    private func submitSeries(_ item: CatalogItem, options: AddOptions?) async throws {
        guard let sonarr else {
            throw DownloadCoordinatorError.serviceNotConfigured(.sonarr)
        }
        guard let tmdbId = item.tmdbId else {
            throw DownloadCoordinatorError.serviceNotConfigured(.sonarr)
        }
        let matches = try await sonarr.lookup(tmdbId: tmdbId)
        guard let match = matches.first else {
            throw DownloadCoordinatorError.lookupReturnedNothing
        }
        let resolved = try await resolve(options: options, sonarr: sonarr)
        _ = try await sonarr.addSeries(
            tvdbId: match.tvdbId,
            title: match.title,
            qualityProfileId: resolved.qualityProfileId,
            rootFolderPath: resolved.rootFolderPath,
            monitored: resolved.monitored,
            monitor: .all,
            seasons: match.seasons.map(\.seasonNumber),
            searchForMissing: resolved.searchNow
        )
    }

    /// Explicit options win; otherwise pull the service defaults
    /// (first quality profile, first root folder) — the *arr defaults
    /// the user already configured server-side.
    private func resolve(options: AddOptions?, radarr: any RadarrProviding) async throws -> AddOptions {
        if let options { return options }
        let profile = try await radarr.qualityProfiles().first
        let folder = try await radarr.rootFolders().first
        return AddOptions(
            qualityProfileId: profile?.id ?? 0,
            rootFolderPath: folder?.path ?? ""
        )
    }

    private func resolve(options: AddOptions?, sonarr: any SonarrProviding) async throws -> AddOptions {
        if let options { return options }
        let profile = try await sonarr.qualityProfiles().first
        let folder = try await sonarr.rootFolders().first
        return AddOptions(
            qualityProfileId: profile?.id ?? 0,
            rootFolderPath: folder?.path ?? ""
        )
    }

    // MARK: Refresh

    /// Pull the queue from every configured service and merge it over the
    /// optimistic local entries. A failing service sets `lastRefreshError`
    /// and keeps the previous list — never blanks the panel.
    public func refresh() async {
        var remote: [DownloadEntry] = []
        var firstError: Error?

        if config.isConfigured(service: .radarr) {
            do {
                remote += try await RadarrQueueOpener(radarr: radarr).fetch()
            } catch {
                firstError = firstError ?? error
            }
        }
        if config.isConfigured(service: .sonarr) {
            do {
                remote += try await SonarrQueueOpener(sonarr: sonarr).fetch()
            } catch {
                firstError = firstError ?? error
            }
        }

        lastRefreshError = firstError

        // Local optimistic entries survive until the remote queue covers them.
        let unmatchedLocal = entries.filter { local in
            local.id.hasPrefix("local-") &&
            !remote.contains { sameTitle($0, local) || sameTmdb($0, local) }
        }
        entries = remote + unmatchedLocal
    }

    // MARK: Availability

    /// Jellyfin now has this title: the download is done and playable.
    public func markAvailable(tmdbId: String) {
        entries = entries.map { entry in
            guard isPending(entry.state) || entry.state == .completed,
                  let id = entry.tmdbId, id.caseInsensitiveCompare(tmdbId) == .orderedSame
            else { return entry }
            return DownloadEntry(
                id: entry.id, service: entry.service, title: entry.title,
                tmdbId: entry.tmdbId, state: .available
            )
        }
    }

    // MARK: - Private

    private func upsert(_ entry: DownloadEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func set(state: DownloadState, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = DownloadEntry(
            id: entries[index].id, service: entries[index].service,
            title: entries[index].title, tmdbId: entries[index].tmdbId,
            state: state
        )
    }

    private func sameTitle(_ a: DownloadEntry, _ b: DownloadEntry) -> Bool {
        a.service == b.service && a.title.caseInsensitiveCompare(b.title) == .orderedSame
    }

    private func sameTmdb(_ a: DownloadEntry, _ b: DownloadEntry) -> Bool {
        guard let x = a.tmdbId, let y = b.tmdbId else { return false }
        return x.caseInsensitiveCompare(y) == .orderedSame
    }

    private func isPending(_ state: DownloadState) -> Bool {
        switch state {
        case .submitting, .queued, .downloading, .paused: return true
        case .completed, .available, .failed: return false
        }
    }
}

// MARK: - Queue openers (nil-client handling)

private struct RadarrQueueOpener {
    let radarr: (any RadarrProviding)?
    func fetch() async throws -> [DownloadEntry] {
        guard let radarr else { return [] }
        return try await radarr.queue()
    }
}

private struct SonarrQueueOpener {
    let sonarr: (any SonarrProviding)?
    func fetch() async throws -> [DownloadEntry] {
        guard let sonarr else { return [] }
        return try await sonarr.queue()
    }
}
