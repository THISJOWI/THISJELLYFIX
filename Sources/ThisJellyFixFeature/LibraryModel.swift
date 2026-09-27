import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking

struct ContentRow: Identifiable, Hashable {
    /// Stable identity: a refresh replaces `items` under the same row, so the
    /// view updates in place instead of tearing down every card (and its image).
    let id: String
    let title: String
    let items: [JellyfinMediaItem]

    init(title: String, items: [JellyfinMediaItem]) {
        self.id = title
        self.title = title
        self.items = items
    }

    static func == (lhs: ContentRow, rhs: ContentRow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
@Observable
final class LibraryModel {
    var rows: [ContentRow] = []
    var isLoading = false
    var errorMessage: String?
    /// Every distinct item across the loaded rows — the discovery layer
    /// matches TMDB ids against this set to know what the library owns.
    var allItems: [JellyfinMediaItem] {
        var seen = Set<String>()
        return rows.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }
    /// E4: the server answered 401 — the token is gone. Retrying can never
    /// succeed, so the UI offers "Cerrar sesión" instead of a dead "Reintentar".
    var sessionExpired = false

    /// Handoff: set by the root view when a Handoff continuation resolves to a
    /// known library item. HomeView consumes this value immediately by pushing
    /// it onto the NavigationStack, then resets it to nil.
    var pendingNavigationItem: JellyfinMediaItem?

    private let libraryClient: any JellyfinLibraryProviding
    private let serverURL: URL
    private let userId: String
    private let token: String

    init(
        libraryClient: any JellyfinLibraryProviding = JellyfinLibraryClient(),
        serverURL: URL,
        userId: String,
        token: String
    ) {
        self.libraryClient = libraryClient
        self.serverURL = serverURL
        self.userId = userId
        self.token = token
    }

    /// Canonical row order. Rows publish as their fetches land, so each insert
    /// re-sorts into place.
    private static let rowOrder = [
        "Estás viendo", "Últimos agregados", "Películas", "Series", "Visto recientemente",
    ]

    /// Minimum gap between resume-row refreshes: Home reappears several times
    /// in a row (tab switch, pop back from detail), each with its own trigger,
    /// which used to fire the same `/Items/Resume` GET back to back.
    private static let resumeRefreshCooldown: TimeInterval = 5
    private var lastResumeRefresh: Date?

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Views first: the Movies/Series rows need their folder ids. Everything
        // else is independent, so the row fetches run IN PARALLEL and each row
        // appears the moment it lands instead of after the slowest request.
        var moviesParent: String?
        var seriesParent: String?
        do {
            let views = try await libraryClient.fetchViews(
                userId: userId, serverURL: serverURL, token: token
            )
            moviesParent = views.first(where: { $0.collectionType == "movies" })?.id
            seriesParent = views.first(where: { $0.collectionType == "tvshows" })?.id
        } catch {
            // Only the two folder-backed rows are lost; the rest still load.
            noteFetchFailure(error, context: "fetchViews", surfaceMessage: true)
        }

        let client = libraryClient
        let serverURL = self.serverURL
        let userId = self.userId
        let token = self.token

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadRow("Estás viendo") {
                try await client.fetchResumeItems(
                    userId: userId, serverURL: serverURL, token: token, limit: 20
                )
            } }
            group.addTask { await self.loadRow("Últimos agregados") {
                try await client.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: nil, includeTypes: "Movie,Series",
                    limit: 20, orderBy: "DateCreated", filters: nil
                )
            } }
            if let moviesParent {
                group.addTask { await self.loadRow("Películas") {
                    try await client.fetchItems(
                        userId: userId, serverURL: serverURL, token: token,
                        parentId: moviesParent, includeTypes: "Movie",
                        limit: 20, orderBy: "DateCreated", filters: nil
                    )
                } }
            }
            if let seriesParent {
                group.addTask { await self.loadRow("Series") {
                    try await client.fetchItems(
                        userId: userId, serverURL: serverURL, token: token,
                        parentId: seriesParent, includeTypes: "Series",
                        limit: 20, orderBy: "DateCreated", filters: nil
                    )
                } }
            }
            group.addTask { await self.loadRow("Visto recientemente") {
                try await client.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: nil, includeTypes: "Movie,Series",
                    limit: 20, orderBy: "DateCreated", filters: "IsPlayed"
                )
            } }
        }

        if rows.isEmpty, errorMessage == nil {
            errorMessage = "No se pudo cargar la biblioteca."
        } else if !rows.isEmpty {
            SpotlightIndexer.shared.index(allItems, serverURL: serverURL)
        }
    }

    /// Fetch one row alongside its siblings and publish it as soon as it lands.
    /// A failing row degrades to a logged gap — it never discards the rows that
    /// already arrived (the old all-or-nothing behaviour lost five responses
    /// when the sixth request timed out).
    private func loadRow(
        _ title: String,
        _ fetch: @Sendable @escaping () async throws -> [JellyfinMediaItem]
    ) async {
        do {
            let items = try await fetch()
            TJFLog("load: \(title) items=\(items.count)")
            if title == "Estás viendo" { lastResumeRefresh = Date() }
            publish(ContentRow(title: title, items: items))
        } catch {
            noteFetchFailure(error, context: "\(title) row", surfaceMessage: false)
        }
    }

    private func publish(_ row: ContentRow) {
        guard !row.items.isEmpty else { return }
        rows.removeAll { $0.id == row.id }
        rows.append(row)
        rows.sort {
            let l = Self.rowOrder.firstIndex(of: $0.title) ?? Self.rowOrder.count
            let r = Self.rowOrder.firstIndex(of: $1.title) ?? Self.rowOrder.count
            return l == r ? $0.title < $1.title : l < r
        }
    }

    /// Refresh ONLY the "Estás viendo" row without touching the rest of the UI.
    /// Used when returning to Home or shortly after the player dismisses.
    /// Coalesced: repeated appearances within `resumeRefreshCooldown` share one
    /// request instead of firing the same GET over and over.
    ///
    /// - Parameter force: the refresh that matters — after playback, the row
    ///   must show the NEW progress. Without this, the appearance trigger that
    ///   fires a moment earlier (still holding the old progress) stamps the
    ///   cooldown and the authoritative refresh is silently dropped: the row
    ///   keeps the pre-playback state and the user "loses" their progress.
    func refreshResume(force: Bool = false) async {
        // A load() is already fetching every row, including this one — but a
        // FORCED refresh is the authoritative post-playback update: a resume
        // fetch does not conflict with `load()` (it overwrites the same row),
        // and dropping it is what made the row keep the old progress.
        if !force, isLoading { return }
        if !force, let last = lastResumeRefresh, Date().timeIntervalSince(last) < Self.resumeRefreshCooldown {
            return
        }
        let stampedAt = Date()
        // Stamp before the request so concurrent NON-forced triggers don't stack.
        lastResumeRefresh = stampedAt
        do {
            let resumeItems = try await libraryClient.fetchResumeItems(
                userId: userId, serverURL: serverURL, token: token, limit: 20
            )
            // Stamp again on success: a slow/stale response must not count as
            // "fresh data" for the next request within the cooldown window.
            lastResumeRefresh = Date()
            TJFLog("refreshResume items=\(resumeItems.count) force=\(force) ids=\(resumeItems.prefix(8).map { "\($0.id):\($0.type):\(Int(($0.userData?.playbackPositionTicks ?? 0) / 10_000_000))s" }.joined(separator: ","))")
            if let idx = rows.firstIndex(where: { $0.title == "Estás viendo" }) {
                if resumeItems.isEmpty {
                    rows.remove(at: idx)
                } else {
                    rows[idx] = ContentRow(title: "Estás viendo", items: resumeItems)
                }
            } else if !resumeItems.isEmpty {
                rows.insert(ContentRow(title: "Estás viendo", items: resumeItems), at: 0)
            }
        } catch {
            // A failed request must NOT burn the cooldown: the pre-stamp above
            // exists only to coalesce concurrent triggers, and leaving it set
            // after an error silently dropped the next natural refresh —
            // which is how "Estás viendo" stayed stale and episodes started in
            // another app never showed up. Only OUR stamp is cleared, never a
            // newer one a concurrent refresh already replaced it with.
            if lastResumeRefresh == stampedAt {
                lastResumeRefresh = nil
            }
            noteFetchFailure(error, context: "refreshResume", surfaceMessage: false)
        }
    }

    /// Records a failed fetch: always logs; surfaces the message only for the
    /// callers that own the error UI, and marks the session dead on 401 so the
    /// screen can offer a logout that works instead of a retry that never will.
    private func noteFetchFailure(_ error: Error, context: String, surfaceMessage: Bool) {
        TJFLog("load: \(context) FAILED: \(error.localizedDescription)")
        if let libraryError = error as? LibraryError, libraryError == .unauthorized {
            sessionExpired = true
            errorMessage = libraryError.errorDescription ?? error.localizedDescription
            return
        }
        if surfaceMessage {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for item: JellyfinMediaItem, wide: Bool = false) -> URL? {
        guard item.hasImage else { return nil }
        let path: String
        if wide {
            // Resume-row landscape cards: prefer a real 16:9 frame (Thumb),
            // then the backdrop, then fall back to the portrait poster.
            if item.imageTags?["Thumb"] != nil {
                path = "Items/\(item.id)/Images/Thumb"
            } else if !(item.backdropImageTags ?? []).isEmpty {
                path = "Items/\(item.id)/Images/Backdrop"
            } else {
                path = "Items/\(item.id)/Images/Primary"
            }
        } else {
            path = "Items/\(item.id)/Images/Primary"
        }
        return serverURL
            .appendingPathComponent(path)
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: wide ? "480" : "300"),
                URLQueryItem(name: "quality", value: "90"),
            ])
    }
}
