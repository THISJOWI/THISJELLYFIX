import Foundation
import ThisJellyFixCore

/// A titled shelf of catalogue items for the Home rows.
public struct CatalogRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let items: [CatalogItem]

    public init(id: String, title: String, items: [CatalogItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Pure row-building for Home: dedupe, drop what the library already has,
/// and shape the shelves. Kept free of network/UI so it stays testable.
public enum CatalogRecommender {
    /// Attach the Jellyfin item id to every catalogue entry the library
    /// already contains (match by TMDB id, case-insensitive).
    public static func markLibrary(
        _ items: [CatalogItem],
        library: [JellyfinMediaItem]
    ) -> [CatalogItem] {
        let index = Dictionary(
            library.compactMap { item in item.tmdbId.map { ($0.lowercased(), item.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        return items.map { entry in
            guard let tmdbId = entry.tmdbId?.lowercased(), let jellyfinId = index[tmdbId] else {
                return entry
            }
            return CatalogItem(
                id: entry.id, kind: entry.kind, title: entry.title, year: entry.year,
                overview: entry.overview, posterURL: entry.posterURL,
                backdropURL: entry.backdropURL, tmdbId: entry.tmdbId,
                imdbId: entry.imdbId, jellyfinId: jellyfinId
            )
        }
    }

    /// Remove repeated TMDB ids, keeping the first occurrence.
    public static func dedupe(_ items: [CatalogItem]) -> [CatalogItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard let key = item.tmdbId?.lowercased() else { return true }
            return seen.insert(key).inserted
        }
    }

    /// Build the Home shelves. `nil` input = provider not configured = shelf
    /// omitted entirely (no empty headers, no error banners on Home).
    public static func buildRows(
        trending: [CatalogItem]?,
        recommendations: [CatalogItem]?,
        library: [JellyfinMediaItem]
    ) -> [CatalogRow] {
        var rows: [CatalogRow] = []

        // Trending is public discovery: keep library titles (they're popular
        // for a reason), but "Para ti" must not recommend what you already own.
        if let trending, !trending.isEmpty {
            rows.append(CatalogRow(
                id: "trending", title: "Tendencias",
                items: dedupe(markLibrary(trending, library: library))
            ))
        }

        if let recommendations {
            let fresh = recommendations.filter { candidate in
                !library.contains { $0.matches(candidate) }
            }
            let shaped = dedupe(markLibrary(fresh, library: library))
            if !shaped.isEmpty {
                rows.append(CatalogRow(id: "forYou", title: "Para ti", items: shaped))
            }
        }

        return rows
    }
}

private extension JellyfinMediaItem {
    func matches(_ candidate: CatalogItem) -> Bool {
        guard let tmdbId else { return false }
        return candidate.matches(tmdbId: tmdbId)
    }
}
