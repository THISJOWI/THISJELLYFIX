import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

struct SearchView: View {
    let serverURL: URL
    let token: String
    let userId: String

    @State private var query = ""
    @State private var results: [JellyfinMediaItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?

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
                VStack(alignment: .leading, spacing: 16) {
                    // Search bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Buscar películas, series…", text: $query)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        if isSearching {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if !query.isEmpty {
                            Button {
                                query = ""
                                results = []
                                hasSearched = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                    // Results
                    if hasSearched && results.isEmpty && !isSearching {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Sin resultados para \"\(query)\"")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else if !results.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120), spacing: 14)],
                            spacing: 20
                        ) {
                            ForEach(results) { item in
                                NavigationLink(value: item) {
                                    MediaCardView(
                                        item: item,
                                        imageURL: imageURL(for: item)
                                    )
                                    .transition(.scale.combined(with: .opacity))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    } else if !hasSearched && query.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundStyle(.cyan.opacity(0.6))
                            Text("Busca tu contenido favorito")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .background(Color.black.opacity(0.3))
            .navigationTitle("Buscar")
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
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                results = []
                hasSearched = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                isSearching = true
                hasSearched = true
                do {
                    let found = try await libraryClient.searchItems(
                        userId: userId,
                        serverURL: serverURL,
                        token: token,
                        query: trimmed,
                        includeTypes: "Movie,Series",
                        limit: 40
                    )
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.3)) {
                        results = found
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    results = []
                }
                isSearching = false
            }
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
