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
            .navigationBarTitleDisplayMode(.inline)
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
        ScrollView(.vertical, showsIndicators: true) {
            if let detail {
                VStack(alignment: .leading, spacing: 0) {
                    // Backdrop image
                    backdropImage(detail: detail)

                    // Content
                    VStack(alignment: .leading, spacing: 16) {
                        // Title + info
                        titleSection(detail: detail)

                        // Genres
                        if let genres = detail.genres, !genres.isEmpty {
                            genreBadges(genres)
                        }

                        // Play button (movies only — series play from episodes)
                        if detail.type != "Series" {
                            Button {
                                streamTitle = detail.name
                                Task { await preparePlayback(itemId: item.id, startPosition: item.resumePositionSeconds) }
                            } label: {
                                if isPreparingPlayback {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    HStack {
                                        Image(systemName: "play.fill")
                                        Text("Reproducir")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(isPreparingPlayback)
                        }

                        // Synopsis
                        if let overview = detail.overview, !overview.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sinopsis")
                                    .font(.headline)
                                Text(overview)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Playback error
                        if let playbackError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(playbackError)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // Episodes (for series)
                        if detail.type == "Series" {
                            episodesSection
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
    }

    // MARK: - Subviews

    @ViewBuilder
    private func backdropImage(detail: JellyfinItemDetail) -> some View {
        if detail.hasBackdrop {
            let url = serverURL
                .appendingPathComponent("Items/\(detail.id)/Images/Backdrop")
                .appending(queryItems: [
                    URLQueryItem(name: "maxWidth", value: "1200"),
                    URLQueryItem(name: "quality", value: "90"),
                ])

            MareaImageView(url: url, width: 600, height: 200)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            Rectangle()
                .fill(Color(red: 0.08, green: 0.1, blue: 0.18))
                .frame(height: 120)
        }
    }

    @ViewBuilder
    private func titleSection(detail: JellyfinItemDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Poster
            if detail.hasPoster {
                let posterURL = serverURL
                    .appendingPathComponent("Items/\(detail.id)/Images/Primary")
                    .appending(queryItems: [
                        URLQueryItem(name: "maxWidth", value: "200"),
                        URLQueryItem(name: "quality", value: "90"),
                    ])

                MareaImageView(url: posterURL, width: 100, height: 150)
                    .shadow(radius: 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name)
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    if let year = detail.year {
                        Text(String(year))
                    }
                    if let duration = detail.durationMinutes {
                        Text("\(duration) min")
                    }
                    if let rating = detail.formattedRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(rating)
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let rating = detail.officialRating {
                    Text(rating)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.2), in: Capsule())
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
                playbackError = "No hay fuente de reproducción disponible."
                return
            }

            currentPlaySessionId = info.playSessionId
            currentMediaStreams = source.mediaStreams

            let url: URL?

            if let urlString = source.directStreamUrl {
                var components = URLComponents(string: urlString)
                var queryItems = components?.queryItems ?? []
                queryItems.append(URLQueryItem(name: "ApiKey", value: token))
                components?.queryItems = queryItems
                url = components?.url
            } else if let urlString = source.transcodingUrl {
                url = URL(string: urlString)
            } else {
                var components = URLComponents(
                    url: serverURL.appendingPathComponent("Videos/\(itemId)/stream"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [
                    URLQueryItem(name: "static", value: "true"),
                    URLQueryItem(name: "ApiKey", value: token),
                ]
                url = components?.url
            }

            guard let finalURL = url else {
                playbackError = "URL de stream inválida."
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
            playbackError = error.localizedDescription
        }
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

    /// Credits overlay → tear down the current player and start the next one.
    private func playNextEpisode(_ episode: JellyfinEpisode) async {
        showPlayer = false
        // Let the full-screen cover dismiss and VLC stop before re-presenting.
        try? await Task.sleep(for: .milliseconds(500))
        await playEpisode(episode)
    }

    // MARK: - Load

    private func loadDetail() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let client = JellyfinItemDetailClient()
            detail = try await client.fetchItemDetail(
                userId: userId,
                serverURL: serverURL,
                token: token,
                itemId: item.id
            )

            // Load seasons if this is a series
            if detail?.type == "Series" {
                await loadSeasons()
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
