import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

struct DetailView: View {
    let item: JellyfinMediaItem
    let serverURL: URL
    let token: String
    let userId: String
    var onPlayerDismiss: (() -> Void)? = nil

    @State private var detail: JellyfinItemDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPlayer = false
    @State private var streamURL: URL?
    @State private var streamTitle: String = ""
    @State private var streamStartPosition: Double?
    @State private var currentItemId: String?
    @State private var currentPlaySessionId: String?
    @State private var currentMediaStreams: [MediaStream] = []
    @State private var isPreparingPlayback = false
    @State private var playbackError: String?
    @State private var nextEpisode: JellyfinEpisode?

    // MARK: - Seasons & Episodes
    @State private var seasons: [JellyfinSeason] = []
    @State private var selectedSeasonIndex: Int = 0
    @State private var episodes: [JellyfinEpisode] = []
    @State private var isLoadingEpisodes = false

    // MARK: - User flags & technical info
    @State private var isFavorite = false
    @State private var isPlayed = false
    /// One flag per action: a slow or failing request must not lock the whole
    /// pill, and the other action stays usable.
    @State private var isSavingFavorite = false
    @State private var isSavingPlayed = false
    @State private var userActionError: String?
    @State private var videoChips: [VideoChip] = []
    /// Bumped by the episodes button; the `ScrollViewReader` watches it because
    /// `ScrollViewProxy` can't be stored across the toolbar.
    @State private var scrollToEpisodesToken = 0

    private static let episodesAnchor = "episodes"

    var body: some View {
        #if os(macOS)
        ZStack {
            detailContent
                .navigationTitle("")
                .navigationBarBackButtonHidden(showPlayer)
                .toolbar(showPlayer ? .hidden : .visible, for: .windowToolbar)
                .task { await loadDetail() }
                .onChange(of: showPlayer) { _, showing in
                    if !showing { onPlayerDismiss?() }
                }

            if showPlayer, let streamURL {
                PlayerView(
                    streamURL: streamURL,
                    title: streamTitle,
                    startPosition: streamStartPosition,
                    onDismiss: { withAnimation { showPlayer = false } },
                    itemId: currentItemId,
                    serverURL: serverURL,
                    token: token,
                    userId: userId,
                    playSessionId: currentPlaySessionId,
                    mediaStreams: currentMediaStreams,
                    nextEpisode: nextEpisode,
                    onPlayNextEpisode: { episode in
                        Task { await playNextEpisode(episode) }
                    }
                )
                .ignoresSafeArea()
            }
        }
        #else
        detailContent
            .navigationTitle("")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationBarBackButtonHidden(showPlayer)
            .fullScreenCover(isPresented: $showPlayer) {
                if let streamURL {
                    PlayerView(
                        streamURL: streamURL,
                        title: streamTitle,
                        startPosition: streamStartPosition,
                        onDismiss: {
                            withAnimation { showPlayer = false }
                        },
                        itemId: currentItemId,
                        serverURL: serverURL,
                        token: token,
                        userId: userId,
                        playSessionId: currentPlaySessionId,
                        mediaStreams: currentMediaStreams,
                        nextEpisode: nextEpisode,
                        onPlayNextEpisode: { episode in
                            Task { await playNextEpisode(episode) }
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .task { await loadDetail() }
            .onChange(of: showPlayer) { _, showing in
                if !showing { onPlayerDismiss?() }
            }
        #endif
    }

    private var detailContent: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: true) {
                if let detail {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(detail: detail)

                        VStack(alignment: .leading, spacing: 16) {
                            titleSection(detail: detail)

                            if let genres = detail.genres, !genres.isEmpty {
                                genreBadges(genres)
                            }

                            if detail.type != "Series" {
                                playButton(detail: detail)
                            }

                            errorBanners

                            if !videoChips.isEmpty {
                                videoSection
                            }

                            if let overview = detail.overview, !overview.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Sinopsis")
                                        .font(.headline)
                                    Text(overview)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if detail.type == "Series" {
                                episodesSection
                                    .id(Self.episodesAnchor)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                        // Spacer ensures scroll area extends beyond content
                        Spacer(minLength: 80)
                    }
                } else if isLoading {
                    ProgressView("Cargando detalle…")
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                        Button("Reintentar") { Task { await loadDetail() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                }
            }
            // The hero owns the whole top of the screen; the navigation bar floats
            // above it (hidden background) so the backdrop bleeds under the status bar.
            .ignoresSafeArea(edges: .top)
            .background(Color.black.ignoresSafeArea())
            .onChange(of: scrollToEpisodesToken) { _, _ in
                withAnimation { scroller.scrollTo(Self.episodesAnchor, anchor: .top) }
            }
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            #if os(iOS) || os(tvOS) || os(visionOS)
            ToolbarItem(placement: .topBarTrailing) {
                actionPill
            }
            #else
            // `navigationBar`/`topBarTrailing` don't exist on macOS — the pill
            // rides in the window toolbar instead.
            ToolbarItem(placement: .primaryAction) {
                actionPill
            }
            #endif
        }
    }

    // MARK: - Navigation bar actions

    /// Play / jump-to-episodes / watched / favorite — lives in the navigation bar
    /// so it lines up with the back button instead of floating over the artwork.
    private var actionPill: some View {
        HStack(spacing: 16) {
            if let detail {
                if detail.type != "Series" {
                    pillButton("play.fill", label: "Reproducir") {
                        Task { await playMovie(detail) }
                    }
                } else {
                    pillButton("list.bullet", label: "Episodios") {
                        scrollToEpisodesToken += 1
                    }
                }
            }

            pillButton(
                isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                label: isPlayed ? "Marcar como no visto" : "Marcar como visto",
                busy: isSavingPlayed
            ) {
                togglePlayed()
            }

            pillButton(
                isFavorite ? "heart.fill" : "heart",
                label: isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                busy: isSavingFavorite
            ) {
                toggleFavorite()
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
    }

    private func pillButton(
        _ icon: String,
        label: String,
        busy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .accessibilityLabel(label)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }

    // MARK: - Hero

    private func hero(detail: JellyfinItemDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdropImage(detail: detail)

            // Bottom scrim keeps the badges readable on light artwork and blends
            // the image into the black content below.
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )

            heroBadges(detail: detail)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
        .frame(height: heroHeight)
        .clipped()
    }

    @ViewBuilder
    private func backdropImage(detail: JellyfinItemDetail) -> some View {
        if detail.hasBackdrop {
            let url = serverURL
                .appendingPathComponent("Items/\(detail.id)/Images/Backdrop")
                .appending(queryItems: [
                    URLQueryItem(name: "maxWidth", value: "1600"),
                    URLQueryItem(name: "quality", value: "90"),
                ])

            MareaImageView(
                url: url,
                placeholder: String(detail.name.prefix(1)),
                width: 600,
                height: 400,
                fallbackURL: posterURL(for: detail)
            )
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
            .overlay(
                // Top scrim: legibility for the navigation bar and status bar.
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            // No backdrop — poster centred on the app's dark card colour.
            ZStack {
                Color(red: 0.08, green: 0.1, blue: 0.18)
                if detail.hasPoster {
                    MareaImageView(url: posterURL(for: detail), width: 160, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func heroBadges(detail: JellyfinItemDetail) -> some View {
        HStack(spacing: 8) {
            if let certification = detail.officialRating {
                badge(certification)
            }
            if let rating = detail.formattedRating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(rating)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
            }
            if let minutes = detail.durationMinutes {
                badge(Self.durationLabel(minutes))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }

    private func posterURL(for detail: JellyfinItemDetail) -> URL? {
        guard detail.hasPoster else { return nil }
        return serverURL
            .appendingPathComponent("Items/\(detail.id)/Images/Primary")
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: "200"),
                URLQueryItem(name: "quality", value: "90"),
            ])
    }

    // MARK: - Content sections

    @ViewBuilder
    private func titleSection(detail: JellyfinItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.name)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            if let year = detail.year {
                Text(String(year))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func playButton(detail: JellyfinItemDetail) -> some View {
        Button {
            Task { await playMovie(detail) }
        } label: {
            if isPreparingPlayback {
                ProgressView()
                    .tint(.black)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text(playLabel(detail: detail))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .controlSize(.large)
        .disabled(isPreparingPlayback)
    }

    /// "1h 38m" from scratch, "Continuar · 52 min" when there's saved progress.
    private func playLabel(detail: JellyfinItemDetail) -> String {
        let total = detail.durationMinutes
        guard let resume = resumeSeconds(detail), resume > 0 else {
            return total.map(Self.durationLabel) ?? "Reproducir"
        }
        let elapsed = Int(resume / 60)
        guard let total else { return "Continuar · \(elapsed) min" }
        return "Continuar · \(max(total - elapsed, 0)) min"
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let playbackError {
            errorBanner(playbackError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let userActionError {
            errorBanner(userActionError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func errorBanner(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vídeo")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(videoChips) { chip in
                    Label(chip.text, systemImage: chip.systemImage)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.10), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func genreBadges(_ genres: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.cyan.opacity(0.2), in: Capsule())
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    // MARK: - Episodes Section (Series)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodios")
                .font(.headline)

            if seasons.isEmpty && isLoadingEpisodes {
                ProgressView("Cargando temporadas…")
                    .frame(maxWidth: .infinity)
            } else if seasons.isEmpty {
                Text("No se encontraron temporadas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Season picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(seasons.enumerated()), id: \.element.id) { index, season in
                            Button {
                                selectedSeasonIndex = index
                                Task { await loadEpisodes(for: season) }
                            } label: {
                                Text(season.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        index == selectedSeasonIndex
                                            ? Color.cyan
                                            : Color.white.opacity(0.1),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(index == selectedSeasonIndex ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Episode list
                if isLoadingEpisodes {
                    ProgressView("Cargando episodios…")
                        .frame(maxWidth: .infinity)
                } else if episodes.isEmpty {
                    Text("No hay episodios en esta temporada.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            serverURL: serverURL
                        ) {
                            Task { await playEpisode(episode) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Playback

    private func playMovie(_ detail: JellyfinItemDetail) async {
        streamTitle = detail.name
        await preparePlayback(itemId: item.id, startPosition: resumeSeconds(detail))
    }

    /// Fresh server progress first (it changes while the screen is open),
    /// then whatever the library row carried.
    private func resumeSeconds(_ detail: JellyfinItemDetail) -> Double? {
        detail.resumePositionSeconds ?? item.resumePositionSeconds
    }

    private func preparePlayback(itemId: String, startPosition: Double? = nil) async {
        isPreparingPlayback = true
        playbackError = nil
        currentItemId = itemId
        defer { isPreparingPlayback = false }

        do {
            let client = JellyfinPlaybackClient()
            let info = try await client.fetchPlaybackInfo(
                userId: userId,
                serverURL: serverURL,
                token: token,
                itemId: itemId
            )

            guard let source = info.mediaSources.first else {
                failPlayback("No hay fuente de reproducción disponible.")
                return
            }

            currentPlaySessionId = info.playSessionId
            currentMediaStreams = source.mediaStreams

            // Shared resolution: relative paths + ApiKey on every branch.
            let url = StreamURLResolver.playbackURL(
                directStreamUrl: source.directStreamUrl,
                transcodingUrl: source.transcodingUrl,
                serverURL: serverURL,
                itemId: itemId,
                token: token
            )

            guard let finalURL = url else {
                failPlayback("URL de stream inválida.")
                return
            }

            #if os(iOS)
            // Lock to landscape BEFORE presenting so iOS rotates the cover on entry
            UIApplication.shared.tjf_orientationLock = [.landscapeLeft, .landscapeRight]
            #endif

            streamURL = finalURL
            streamStartPosition = startPosition
            showPlayer = true
        } catch {
            // A failed next-episode swap must return to the detail screen where
            // the error is visible, instead of stranding a stopped player.
            failPlayback(error.localizedDescription)
        }
    }

    /// Record the failure and tear the player down BECAUSE of it — the flag
    /// tells `PlayerView.onDisappear` to skip the auto-PiP handoff instead of
    /// floating a broken episode over the error screen.
    private func failPlayback(_ message: String) {
        playbackError = message
        PlayerTeardown.noteError()
        showPlayer = false
    }

    private func playEpisode(_ episode: JellyfinEpisode) async {
        streamTitle = episode.name
        nextEpisode = nextEpisodeAfter(episode)
        await preparePlayback(itemId: episode.id, startPosition: episode.resumePositionSeconds)
    }

    /// Next episode in the currently listed season order, if any.
    private func nextEpisodeAfter(_ episode: JellyfinEpisode) -> JellyfinEpisode? {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }),
              index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// Credits overlay → start the next episode IN PLACE. The cover stays
    /// presented, so `PlayerView.onChange(of: streamURL)` swaps the stream and
    /// the user never lands back on the episode list.
    private func playNextEpisode(_ episode: JellyfinEpisode) async {
        await playEpisode(episode)
    }

    // MARK: - User flags

    private func toggleFavorite() {
        guard !isSavingFavorite else { return }
        let desired = !isFavorite
        isFavorite = desired
        userActionError = nil
        isSavingFavorite = true
        Task {
            defer { isSavingFavorite = false }
            do {
                try await JellyfinUserActionClient().setFavorite(
                    desired,
                    userId: userId,
                    serverURL: serverURL,
                    token: token,
                    itemId: item.id
                )
            } catch {
                isFavorite = !desired
                userActionError = "No se pudo actualizar el favorito (\(Self.describe(error)))."
            }
        }
    }

    private func togglePlayed() {
        guard !isSavingPlayed else { return }
        let desired = !isPlayed
        isPlayed = desired
        userActionError = nil
        isSavingPlayed = true
        Task {
            defer { isSavingPlayed = false }
            do {
                try await JellyfinUserActionClient().setPlayed(
                    desired,
                    userId: userId,
                    serverURL: serverURL,
                    token: token,
                    itemId: item.id
                )
            } catch {
                isPlayed = !desired
                userActionError = "No se pudo actualizar el estado de reproducción (\(Self.describe(error)))."
            }
        }
    }

    /// Short reason for the inline banner: a bare "server error 404" is exactly
    /// what tells us the route drifted again.
    private static func describe(_ error: Error) -> String {
        if let libraryError = error as? LibraryError {
            switch libraryError {
            case .unauthorized: return "sesión no válida"
            case .serverError(let code): return "HTTP \(code)"
            default: return libraryError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Load

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // PlaybackInfo only feeds the "Vídeo" chips here — a failure must
            // not stop the detail screen from rendering.
            async let playbackInfo = JellyfinPlaybackClient().fetchPlaybackInfo(
                userId: userId,
                serverURL: serverURL,
                token: token,
                itemId: item.id
            )

            let client = JellyfinItemDetailClient()
            let loaded = try await client.fetchItemDetail(
                userId: userId,
                serverURL: serverURL,
                token: token,
                itemId: item.id
            )
            detail = loaded
            isFavorite = loaded.isFavorite
            isPlayed = loaded.isPlayed

            // Load seasons if this is a series
            if loaded.type == "Series" {
                await loadSeasons()
            }

            if let info = try? await playbackInfo,
               let source = info.mediaSources.first {
                videoChips = VideoInfoChips.chips(from: source)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSeasons() async {
        let libraryClient = JellyfinLibraryClient()
        do {
            seasons = try await libraryClient.fetchSeasons(
                userId: userId,
                serverURL: serverURL,
                token: token,
                seriesId: item.id
            )
            if let firstSeason = seasons.first {
                selectedSeasonIndex = 0
                await loadEpisodes(for: firstSeason)
            }
        } catch {
            // Seasons failing shouldn't block the detail page
        }
    }

    private func loadEpisodes(for season: JellyfinSeason) async {
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }

        let libraryClient = JellyfinLibraryClient()
        do {
            episodes = try await libraryClient.fetchEpisodes(
                userId: userId,
                serverURL: serverURL,
                token: token,
                seriesId: item.id,
                seasonId: season.id
            )
        } catch {
            episodes = []
        }
    }

    // MARK: - Metrics

    private var heroHeight: CGFloat {
        #if os(macOS) || os(visionOS)
        460
        #else
        min(max(screenHeight * 0.45, 280), 520)
        #endif
    }

    private var screenHeight: CGFloat {
        #if os(iOS) || os(tvOS)
        UIScreen.main.bounds.height
        #else
        480
        #endif
    }

    private static func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(rest) min" }
        return rest > 0 ? "\(hours)h \(rest) min" : "\(hours)h"
    }
}

// MARK: - Flow Layout

/// Wraps subviews onto as many lines as needed — technical chips have wildly
/// different widths and a fixed grid looks wrong.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : max(x - spacing, 0), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Episode Row

private struct EpisodeRow: View {
    let episode: JellyfinEpisode
    let serverURL: URL
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Episode thumbnail
            if episode.imageTags?["Backdrop"] != nil || episode.imageTags?["Primary"] != nil {
                let hasBackdrop = episode.imageTags?["Backdrop"] != nil
                let thumbURL = serverURL
                    .appendingPathComponent("Items/\(episode.id)/Images/\(hasBackdrop ? "Backdrop" : "Primary")")
                    .appending(queryItems: [
                        URLQueryItem(name: "maxWidth", value: "200"),
                        URLQueryItem(name: "quality", value: "90"),
                    ])

                MareaImageView(url: thumbURL, width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.15, green: 0.17, blue: 0.25))
                    .frame(width: 120, height: 68)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
            }

            // Episode info
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.episodeLabel)
                    .font(.caption)
                    .foregroundStyle(.cyan)

                Text(episode.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let duration = episode.durationMinutes {
                    Text("\(duration) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Play button
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
