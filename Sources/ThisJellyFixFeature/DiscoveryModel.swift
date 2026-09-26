import Foundation
import Observation
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// UI-facing state for discovery + downloads. Thin: real logic lives in
/// `DiscoveryLoader` (row/search shaping) and `DownloadCoordinator`
/// (submit/refresh), both covered by tests.
@MainActor
@Observable
public final class DiscoveryModel {
    // Home
    public private(set) var rows: [CatalogRow] = []
    public private(set) var isLoadingRows = false

    // Search (external catalog half)
    public private(set) var catalogResults: [CatalogItem] = []

    // Downloads
    public let coordinator: DownloadCoordinator
    /// Last refresh failure for the downloads panel banner.
    public var downloadError: Error? { coordinator.lastRefreshError }

    private let loader: DiscoveryLoader
    private let library: () async -> [JellyfinMediaItem]
    private var pollTask: Task<Void, Never>?

    public init(
        loader: DiscoveryLoader,
        coordinator: DownloadCoordinator,
        library: @escaping () async -> [JellyfinMediaItem]
    ) {
        self.loader = loader
        self.coordinator = coordinator
        self.library = library
    }

    /// True when anything at all is configured (drives whether discovery
    /// UI appears at all — no config = app looks exactly as before).
    public private(set) var hasAnyConfiguration = false
    /// TMDB configured → Home rows and catalog search are possible.
    public private(set) var hasMetadataProvider = false
    /// Radarr or Sonarr configured → download buttons are possible.
    public private(set) var hasDownloadService = false

    // MARK: - Setup

    /// Build from stored settings. No config = the app looks exactly as
    /// before (no discovery rows, no download buttons).
    public static func live(library: @escaping () async -> [JellyfinMediaItem]) -> DiscoveryModel {
        let config = IntegrationConfig()
        let model = DiscoveryModel(
            loader: DiscoveryLoader.live(config: config),
            coordinator: DownloadCoordinator.live(config: config),
            library: library
        )
        model.hasMetadataProvider = config.hasMetadataProvider
        model.hasDownloadService = config.isConfigured(service: .radarr) || config.isConfigured(service: .sonarr)
        model.hasAnyConfiguration = model.hasMetadataProvider || model.hasDownloadService
        return model
    }

    // MARK: - Home

    public func loadRows() async {
        guard !isLoadingRows else { return }
        isLoadingRows = true
        defer { isLoadingRows = false }
        let items = await library()
        rows = await loader.loadRows(library: items)
    }

    // MARK: - Search

    /// External catalog results for `query`, already deduped and marked
    /// against the current library. Returns [] when discovery is off or the
    /// provider fails — the library half of Search is unaffected either way.
    public func searchCatalog(query: String) async -> [CatalogItem] {
        guard hasMetadataProvider else { return [] }
        let items = await library()
        guard let results = try? await loader.search(query: query, library: items) else { return [] }
        catalogResults = results
        return results
    }

    public func clearCatalogResults() {
        catalogResults = []
    }

    // MARK: - Downloads

    public func submit(_ item: CatalogItem, options: AddOptions? = nil) async throws {
        try await coordinator.submit(item, options: options)
        startPolling()
    }

    /// Refresh once (manual pull or single shot).
    public func refreshDownloads() async {
        await coordinator.refresh()
        await markAvailableFromLibrary()
    }

    /// Poll while something is in flight; stop when everything settles so
    /// an idle app makes no background requests.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshDownloads()
                let busy = self.coordinator.entries.contains { !$0.state.isFinished }
                if !busy {
                    self.pollTask = nil
                    return
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// A download whose file Jellyfin already has is "available" — playable
    /// from the normal library UI.
    private func markAvailableFromLibrary() async {
        let items = (try? await library()) ?? []
        let ownedTmdbIds = items.compactMap(\.tmdbId)
        for id in ownedTmdbIds {
            coordinator.markAvailable(tmdbId: id)
        }
    }
}
