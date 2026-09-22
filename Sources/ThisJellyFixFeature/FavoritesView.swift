import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

struct FavoritesView: View {
    let serverURL: URL
    let token: String
    let userId: String

    @State private var favoriteMovies: [JellyfinMediaItem] = []
    @State private var favoriteSeries: [JellyfinMediaItem] = []
    @State private var isLoading = true

    private let libraryClient: any JellyfinLibraryProviding

    init(
        serverURL: URL,
        token: String,
        userId: String,
        libraryClient: any JellyfinLibraryProviding = JellyfinLibraryClient()
    ) {
        self.serverURL = serverURL
        self.token = token
        self.userId = userId
        self.libraryClient = libraryClient
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isLoading {
                        ProgressView("Cargando favoritos…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if favoriteMovies.isEmpty && favoriteSeries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "heart.slash")
                                .font(.system(size: 48))
                                .foregroundStyle(.cyan.opacity(0.6))
                            Text("Sin favoritos aún")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Marca contenido como favorito en Jellyfin")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        if !favoriteSeries.isEmpty {
                            favoritesSection(title: "Series", items: favoriteSeries)
                        }
                        if !favoriteMovies.isEmpty {
                            favoritesSection(title: "Películas", items: favoriteMovies)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .background(Color.black.opacity(0.3))
            .navigationTitle("Favoritos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: JellyfinMediaItem.self) { item in
                DetailView(
                    item: item,
                    serverURL: serverURL,
                    token: token,
                    userId: userId
                )
            }
            .task { await loadFavorites() }
        }
    }

    private func favoritesSection(title: String, items: [JellyfinMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            MediaCardView(
                                item: item,
                                imageURL: imageURL(for: item)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadFavorites() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let moviesTask = libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie",
                limit: 30, orderBy: "DateCreated", filters: "IsFavorite"
            )
            async let seriesTask = libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Series",
                limit: 30, orderBy: "DateCreated", filters: "IsFavorite"
            )

            let (movies, series) = try await (moviesTask, seriesTask)
            withAnimation(.spring(response: 0.3)) {
                favoriteMovies = movies
                favoriteSeries = series
            }
        } catch {
            // Silent fail
        }
    }

    private func imageURL(for item: JellyfinMediaItem) -> URL? {
        guard item.hasImage else { return nil }
        return serverURL
            .appendingPathComponent("Items/\(item.id)/Images/Primary")
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: "300"),
                URLQueryItem(name: "quality", value: "90"),
            ])
    }
}
