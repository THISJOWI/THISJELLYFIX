import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking

struct ContentRow: Identifiable {
    let id = UUID()
    let title: String
    let items: [JellyfinMediaItem]
}

@MainActor
@Observable
final class LibraryModel {
    var rows: [ContentRow] = []
    var isLoading = false
    var errorMessage: String?

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

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let views = try await libraryClient.fetchViews(
                userId: userId, serverURL: serverURL, token: token
            )

            var allRows: [ContentRow] = []

            // 1. Recently added
            let recentItems = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: nil
            )
            if !recentItems.isEmpty {
                allRows.append(ContentRow(title: "Últimos agregados", items: recentItems))
            }

            // 2. Movies
            if let moviesView = views.first(where: { $0.collectionType == "movies" }) {
                let movies = try await libraryClient.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: moviesView.id, includeTypes: "Movie",
                    limit: 20, orderBy: "DateCreated", filters: nil
                )
                if !movies.isEmpty {
                    allRows.append(ContentRow(title: "Películas", items: movies))
                }
            }

            // 3. Series
            if let seriesView = views.first(where: { $0.collectionType == "tvshows" }) {
                let series = try await libraryClient.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: seriesView.id, includeTypes: "Series",
                    limit: 20, orderBy: "DateCreated", filters: nil
                )
                if !series.isEmpty {
                    allRows.append(ContentRow(title: "Series", items: series))
                }
            }

            // 4. Favorites
            let favorites = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: "IsFavorite"
            )
            if !favorites.isEmpty {
                allRows.append(ContentRow(title: "Favoritos", items: favorites))
            }

            // 5. Recently played
            let played = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: "IsPlayed"
            )
            if !played.isEmpty {
                allRows.append(ContentRow(title: "Visto recientemente", items: played))
            }

            rows = allRows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for item: JellyfinMediaItem) -> URL? {
        guard item.hasImage else { return nil }
        return serverURL
            .appendingPathComponent("Items/\(item.id)/Images/Primary")
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: "300"),
                URLQueryItem(name: "quality", value: "90"),
            ])
    }
}
