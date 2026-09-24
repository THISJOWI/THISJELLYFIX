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
                            // before re-fetching, otherwise the server has no progress yet
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.load()
                        } }
                    )
                }
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
                            // before re-fetching, otherwise the server has no progress yet
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.load()
                        } }
                        )
                    }
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
                            // before re-fetching, otherwise the server has no progress yet
                            try? await Task.sleep(for: .seconds(2))
                            await libraryModel.load()
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
                }
                .padding(.horizontal, 32)

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
                        Button("Reintentar") { Task { await libraryModel.load() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(libraryModel.rows) { row in
                        ContentRowView(
                            row: row,
                            libraryModel: libraryModel,
                            onPlayDirect: { item in directItem = item }
                        )
                    }
                }
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
            await libraryModel.load()
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
                            wide: isResumeRow
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
