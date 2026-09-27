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
        hydrate()
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
            let remoteId: Int?
            switch service {
            case .radarr:
                remoteId = try await submitMovie(item, options: options)
            case .sonarr:
                remoteId = try await submitSeries(item, options: options)
            }
            // Keep the service-side id: cancel before the first refresh
            // needs it to DELETE the entry we just created.
            if let remoteId {
                patch(remoteId: String(remoteId), for: localId)
            }
        } catch {
            set(state: .failed(error.localizedDescription), for: localId)
            throw error
        }
    }

    private func submitMovie(_ item: CatalogItem, options: AddOptions?) async throws -> Int {
        guard let radarr, let tmdbId = item.tmdbId else {
            throw DownloadCoordinatorError.serviceNotConfigured(.radarr)
        }
        let resolved = try await resolve(options: options, radarr: radarr)
        return try await radarr.addMovie(
            tmdbId: tmdbId,
            title: item.title,
            qualityProfileId: resolved.qualityProfileId,
            rootFolderPath: resolved.rootFolderPath,
            monitored: resolved.monitored,
            searchForMovie: resolved.searchNow
        )
    }

    private func submitSeries(_ item: CatalogItem, options: AddOptions?) async throws -> Int {
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
        return try await sonarr.addSeries(
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

        // A failing service would rebuild the list from a partial (or
        // empty) queue and wipe real entries: keep the previous list.
        if firstError != nil { return }

        // Local optimistic entries survive until the remote queue covers them.
        let unmatchedLocal = entries.filter { local in
            local.id.hasPrefix("local-") &&
            !remote.contains { sameTitle($0, local) || sameTmdb($0, local) }
        }
        // Terminal entries (done/failed) left the remote queue but are the
        // history the user keeps across launches — until they cancel them.
        // Matched against re-downloads so a title never shows up twice.
        let history = entries.filter { entry in
            !entry.id.hasPrefix("local-") &&
            !isPending(entry.state) &&
            !remote.contains {
                $0.id == entry.id || sameTitle($0, entry) || sameTmdb($0, entry)
            }
        }
        entries = remote + unmatchedLocal + history
        persist()
    }

    // MARK: Removal

    /// Cancel: delete the entry from the *arr service, drop it locally and
    /// re-sync. Files already on disk stay — the service owns those.
    public func removeEntries(matching item: CatalogItem) async {
        let matches = entries.filter { entry in
            (item.tmdbId != nil && entry.tmdbId == item.tmdbId) || entry.title == item.title
        }
        for entry in matches {
            // Local-* entries count too: they were already created
            // server-side by submit, cancel must undo them there as well.
            guard let id = await serviceId(for: entry) else { continue }
            switch entry.service {
            case .radarr: try? await radarr?.deleteEntry(id: id)
            case .sonarr: try? await sonarr?.deleteEntry(id: id)
            }
        }
        let doomed = Set(matches.map(\.id))
        entries.removeAll { doomed.contains($0.id) }
        persist()
        await refresh()
    }

    /// Id the service's DELETE endpoint expects: the stored service id,
    /// falling back to a lookup by TMDB id when the queue didn't carry one.
    private func serviceId(for entry: DownloadEntry) async -> String? {
        if let remoteId = entry.remoteId { return remoteId }
        guard let tmdbId = entry.tmdbId else { return nil }
        switch entry.service {
        case .radarr:
            guard let radarr, let match = try? await radarr.lookup(tmdbId: tmdbId).first else {
                return nil
            }
            return match.id.map(String.init)
        case .sonarr:
            guard let sonarr, let match = try? await sonarr.lookup(tmdbId: tmdbId).first else {
                return nil
            }
            return match.id.map(String.init)
        }
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
                tmdbId: entry.tmdbId, remoteId: entry.remoteId, state: .available
            )
        }
        persist()
    }

    // MARK: - Private

    /// Rebuild the panel from the last persisted state so leaving the app
    /// doesn't wipe the history. A submit interrupted by the app dying is
    /// reported as failed instead of hanging in `.submitting`.
    private func hydrate() {
        guard let data = config.downloadHistoryData,
              let decoded = try? JSONDecoder().decode([DownloadEntry].self, from: data)
        else { return }
        entries = decoded.map { entry in
            guard entry.state == .submitting else { return entry }
            return DownloadEntry(
                id: entry.id, service: entry.service, title: entry.title,
                tmdbId: entry.tmdbId, remoteId: entry.remoteId,
                state: .failed("Envío interrumpido")
            )
        }
    }

    /// Mirror the panel into storage. Called after every mutation so the
    /// persisted list never lags behind what the user sees.
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        config.saveDownloadHistory(data)
    }

    private func upsert(_ entry: DownloadEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    private func set(state: DownloadState, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = DownloadEntry(
            id: entries[index].id, service: entries[index].service,
            title: entries[index].title, tmdbId: entries[index].tmdbId,
            remoteId: entries[index].remoteId, state: state
        )
        persist()
    }

    /// Attach the service-side id to an already-created local entry.
    private func patch(remoteId: String, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = DownloadEntry(
            id: entries[index].id, service: entries[index].service,
            title: entries[index].title, tmdbId: entries[index].tmdbId,
            remoteId: remoteId, state: entries[index].state
        )
        persist()
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
