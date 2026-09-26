import Foundation
import ThisJellyFixCore

/// Orchestrates the discovery screens: asks the metadata provider for
/// trending/recommendations/search and shapes the results against the
/// user's Jellyfin library. Network-free parts (row building, dedupe,
/// library marking) live in `CatalogRecommender`.
public struct DiscoveryLoader: Sendable {
    /// nil = no provider configured = discovery screens stay hidden.
    private let provider: (any MetadataProvider)?
    /// Cap on library titles used as recommendation seeds (keeps the
    /// fan-out of TMDB calls bounded on Home load).
    private let maxSeeds: Int

    public init(provider: (any MetadataProvider)?, maxSeeds: Int = 5) {
        self.provider = provider
        self.maxSeeds = maxSeeds
    }

    /// Build from the stored TMDB key; nil when not configured.
    public static func live(config: IntegrationConfig) -> DiscoveryLoader {
        guard config.hasMetadataProvider, let key = config.tmdbApiKey else {
            return DiscoveryLoader(provider: nil)
        }
        return DiscoveryLoader(provider: TMDBMetadataProvider(apiKey: key))
    }

    // MARK: - Home

    /// Home shelves. Individual provider failures degrade to fewer shelves
    /// instead of an error state: Home must always render the library.
    public func loadRows(library: [JellyfinMediaItem]) async -> [CatalogRow] {
        guard let provider else { return [] }

        let trending = await safe { try await provider.trending() }
        let recommendations = await recommendations(for: library, provider: provider)

        return CatalogRecommender.buildRows(
            trending: trending,
            recommendations: recommendations,
            library: library
        )
    }

    /// Seed recommendations from the library's TMDB ids (movies and series
    /// separately so a series seed never returns movie rows as "Para ti").
    private func recommendations(
        for library: [JellyfinMediaItem],
        provider: any MetadataProvider
    ) async -> [CatalogItem]? {
        let seeds = library.compactMap { item -> (String, CatalogItem.Kind)? in
            guard let tmdbId = item.tmdbId else { return nil }
            return (tmdbId, item.type == "Series" ? .series : .movie)
        }
        guard !seeds.isEmpty else { return nil }

        var merged: [CatalogItem] = []
        for seed in seeds.prefix(maxSeeds) {
            let batch = await safe { try await provider.recommendations(tmdbId: seed.0, kind: seed.1) }
            if let batch { merged += batch }
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Search

    /// External catalog results for the search screen, marked against the
    /// library so the UI can badge "ya en tu biblioteca" instead of
    /// offering a duplicate download.
    public func search(query: String, library: [JellyfinMediaItem]) async throws -> [CatalogItem] {
        guard let provider else { return [] }
        let results = try await provider.search(query: query)
        return CatalogRecommender.markLibrary(
            CatalogRecommender.dedupe(results),
            library: library
        )
    }

    // MARK: - Private

    /// Swallow a failing call into nil — callers decide whether that means
    /// "hide the shelf" or "keep the previous value".
    private func safe<T>(_ work: () async throws -> T) async -> T? {
        do { return try await work() }
        catch {
            TJFLog("discovery: \(error)")
            return nil
        }
    }
}
