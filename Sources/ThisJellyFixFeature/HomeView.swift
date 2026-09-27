import SwiftUI
import ThisJellyFixCore

struct HomeView: View {
    let libraryModel: LibraryModel
    let serverURL: URL
    let token: String
    let userId: String
    let userName: String
    let onLogout: () -> Void

    /// Episode or movie tapped on a card — played directly, without pushing DetailView.
    @State private var directItem: JellyfinMediaItem?
    /// nil = discovery not configured (or tvOS/visionOS) → rows never render.
    @Environment(DiscoveryModel.self) private var discovery: DiscoveryModel?

    var body: some View {
        #if os(macOS)
        sidebarLayout
        #else
        NavigationStack {
            scrollContent
                .navigationDestination(for: JellyfinMediaItem.self) { item in
                    DetailView(
                        item: item, serverURL: serverURL, token: token, userId: userId,
                        onPlayerDismiss: { Task {
                            // Wait for the async reportStopped HTTP request to land
                            // before re-fetching, otherwise the server has no progress yet.
                            // Only the resume row changes after playback, so refresh
                            // just that row instead of re-running the whole library load.
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.refreshResume(force: true)
                        } }
                    )
                }
                #if os(iOS) || os(macOS)
                .navigationDestination(for: CatalogItem.self) { item in
                    CatalogDetailView(item: item)
                }
                #endif
        }
        #endif
    }

    // MARK: - macOS Sidebar

    #if os(macOS)
    @State private var selectedTab: MareaTab = .home

    private var sidebarLayout: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Logo header
                HStack {
                    Image("AppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Inicio")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                List {
                    Section("Navegación") {
                        ForEach(MareaTab.allCases.filter { $0 != .favorites }, id: \.self) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                Label(tab.label, systemImage: tab.icon)
                                    .foregroundStyle(selectedTab == tab ? .cyan : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(minWidth: 200)
        } detail: {
            macTabContent(selectedTab)
                .id(selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func macTabContent(_ tab: MareaTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                scrollContent
                    .navigationDestination(for: JellyfinMediaItem.self) { item in
                        DetailView(
                            item: item, serverURL: serverURL, token: token, userId: userId,
                            onPlayerDismiss: { Task {
                            // Wait for the async reportStopped HTTP request to land
                            // before re-fetching, otherwise the server has no progress yet.
                            // Only the resume row changes after playback, so refresh
                            // just that row instead of re-running the whole library load.
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.refreshResume(force: true)
                        } }
                        )
                    }
                    #if os(iOS) || os(macOS)
                    .navigationDestination(for: CatalogItem.self) { item in
                        CatalogDetailView(item: item)
                    }
                    #endif
            }
        case .search:
            SearchView(serverURL: serverURL, token: token, userId: userId)
        case .favorites:
            // Favorites removed from sidebar — redirect to home
            NavigationStack {
                scrollContent
                    .navigationDestination(for: JellyfinMediaItem.self) { item in
                        DetailView(
                            item: item, serverURL: serverURL, token: token, userId: userId,
                            onPlayerDismiss: { Task {
                            // Wait for the async reportStopped HTTP request to land
                            // before re-fetching, otherwise the server has no progress yet.
                            // Only the resume row changes after playback, so refresh
                            // just that row instead of re-running the whole library load.
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.refreshResume(force: true)
                        } }
                        )
                    }
            }
        case .profile:
            ProfileView(userName: userName, onLogout: onLogout, serverURL: serverURL, token: token, userId: userId)
        }
    }
    #endif

    // MARK: - Scroll Content (shared)

    #if os(iOS) || os(macOS)
    /// Trending shelves — nil discovery (tvOS/visionOS or no config) = empty.
    @ViewBuilder
    private var trendingShelf: some View {
        if let discovery {
            ForEach(discovery.trendingRows) { row in
                DiscoveryRowView(row: row, discovery: discovery)
            }
        }
    }

    /// Homogeneous "para ti" shelves (series/movies/anime kept apart).
    @ViewBuilder
    private var forYouShelf: some View {
        if let discovery {
            ForEach(discovery.forYouRows) { row in
                DiscoveryRowView(row: row, discovery: discovery)
            }
        }
    }
    #endif

    private var scrollContent: some View {
        let base = ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Image("AppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Inicio")
                        .font(.largeTitle.bold())
                    Spacer()

                    #if os(iOS) || os(macOS)
                    if let discovery, discovery.hasDownloadService {
                        DownloadsButton(discovery: discovery)
                    }
                    #endif
                }
                .padding(.horizontal, 32)

                // E4: dead token — the retry button can never succeed, so the
                // banner (and the empty-state button) offer a real way out.
                if libraryModel.sessionExpired {
                    HStack(spacing: 12) {
                        Label("Sesión expirada", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Cerrar sesión", action: onLogout)
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                    }
                    .padding(.horizontal, 32)
                }

                if libraryModel.isLoading && libraryModel.rows.isEmpty {
                    ProgressView("Cargando biblioteca…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = libraryModel.errorMessage, libraryModel.rows.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                        if libraryModel.sessionExpired {
                            Button("Cerrar sesión", action: onLogout)
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                        } else {
                            Button("Reintentar") { Task { await libraryModel.load() } }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    #if os(iOS) || os(macOS)
                    if libraryModel.rows.isEmpty {
                        trendingShelf
                    }
                    #endif

                    ForEach(Array(libraryModel.rows.enumerated()), id: \.element.id) { index, row in
                        ContentRowView(
                            row: row,
                            libraryModel: libraryModel,
                            onPlayDirect: { item in directItem = item }
                        )

                        // Trending sits right after "Estás viendo" so fresh
                        // content shows up at the top of Home.
                        #if os(iOS) || os(macOS)
                        if index == 0 {
                            trendingShelf
                        }
                        #endif
                    }
                }

                // "Para ti" shelves: homogeneous rows after the library.
                #if os(iOS) || os(macOS)
                forYouShelf
                #endif
            }
            .padding(.top, 16)
        }
        .onAppear {
            // Refresh resume row whenever Home reappears (tab switch, pop back
            // from DetailView) so "Estás viendo" is never stale.
            Task { await libraryModel.refreshResume() }
        }

        #if os(macOS)
        return base.overlay {
            if let directItem {
                DirectPlayer(
                    item: directItem,
                    serverURL: serverURL,
                    token: token,
                    userId: userId,
                    onClosed: closeDirectPlayer
                )
                .ignoresSafeArea()
            }
        }
        #else
        return base.fullScreenCover(item: $directItem) { item in
            DirectPlayer(
                item: item,
                serverURL: serverURL,
                token: token,
                userId: userId,
                onClosed: closeDirectPlayer
            )
        }
        #endif
    }

    /// Player dismissed: back to this screen, then refresh progress rows
    /// once the reportStopped request has had time to land.
    private func closeDirectPlayer() {
        directItem = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            await libraryModel.refreshResume(force: true)
        }
    }
}

private struct ContentRowView: View {
    let row: ContentRow
    let libraryModel: LibraryModel
    /// Direct playback taps (episodes/movies) bypass DetailView.
    var onPlayDirect: (JellyfinMediaItem) -> Void = { _ in }
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title)
                .font(.title3.bold())
                .padding(.horizontal, 32)

            ScrollView(.horizontal, showsIndicators: false) {
                // Top-align cards: text below posters varies in height (1–2 line
                // titles, optional year, episode labels), and the default
                // .center alignment vertically offset the posters, making them
                // look like different heights.
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { index, item in
                        let isResumeRow = row.title == "Estás viendo"
                        let card = MediaCardView(
                            item: item,
                            imageURL: libraryModel.imageURL(for: item, wide: isResumeRow),
                            wide: isResumeRow,
                            // Wide (Thumb/Backdrop) fetches fail more often than
                            // the poster: fall back so the resume tile never
                            // sits there as a dead black card.
                            fallbackImageURL: isResumeRow
                                ? libraryModel.imageURL(for: item, wide: false)
                                : nil
                        )

                        if item.type == "Episode" || item.type == "Movie" {
                            // Direct playback — no DetailView in between.
                            Button { onPlayDirect(item) } label: { card }
                                .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: item) { card }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 32)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05)) {
                appeared = true
            }
        }
    }
}
