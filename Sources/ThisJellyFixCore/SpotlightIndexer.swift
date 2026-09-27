#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
import Foundation

// MARK: - SpotlightIndexer

/// Indexes `JellyfinMediaItem` entries into CoreSpotlight so the user can
/// find their Jellyfin media directly from the system search on iOS and macOS.
///
/// Only movies and series are indexed (episodes are too granular and would
/// flood the index).  Thumbnails are omitted to keep the index lightweight;
/// the system fetches them lazily from the `thumbnailURL` if provided.
public final class SpotlightIndexer: Sendable {

    /// Domain that groups all THISJELLYFIX items so we can delete them in bulk.
    public static let domainIdentifier = "com.thisjellyfix.library"

    public static let shared = SpotlightIndexer()
    private init() {}

    // MARK: - Public API

    /// Indexes the given items asynchronously.  Safe to call on any actor.
    /// Items that are already indexed are updated in place (CoreSpotlight
    /// deduplicates by `uniqueIdentifier`).
    public func index(_ items: [JellyfinMediaItem], serverURL: URL) {
        #if canImport(CoreSpotlight)
        // Filter to movies and series only — no episodes, no generic.
        let indexable = items.filter { $0.type == "Movie" || $0.type == "Series" }
        guard !indexable.isEmpty else { return }

        let searchItems = indexable.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .audiovisualContent)
            attributes.title       = item.name
            attributes.displayName = item.name

            if let overview = item.overview, !overview.isEmpty {
                attributes.contentDescription = overview
            }

            if let year = item.year {
                // `CSSearchableItemAttributeSet` has no `year` property — Spotlight
                // matches on the creation date, so expose the year through it.
                var components = DateComponents()
                components.year = year
                attributes.contentCreationDate = Calendar.current.date(from: components)
            }

            // Rating (parental guide rating stored as a string in Jellyfin)
            if let rating = item.officialRating {
                attributes.rating = NSNumber(value: 0)
                attributes.ratingDescription = rating
            }

            // Keywords for better search matching
            var keywords: [String] = [item.type == "Movie" ? "Película" : "Serie"]
            if let genres = item.genres { keywords += genres }
            attributes.keywords = keywords

            return CSSearchableItem(
                uniqueIdentifier: "tjf://item/\(item.id)",
                domainIdentifier: Self.domainIdentifier,
                attributeSet: attributes
            )
        }

        CSSearchableIndex.default().indexSearchableItems(searchItems) { error in
            if let error {
                print("[Spotlight] indexing error: \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Removes all previously indexed THISJELLYFIX items (e.g. on logout).
    public func deleteAll() {
        #if canImport(CoreSpotlight)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in }
        #endif
    }
}
