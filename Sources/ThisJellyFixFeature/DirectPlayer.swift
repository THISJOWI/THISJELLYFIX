import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

/// Plays an episode or movie immediately without pushing DetailView.
///
/// Presented as a full-screen cover from the calling screen: shows a black
/// loading state while the playback URL is resolved, mounts `PlayerView` when
/// ready, and calls `onClosed` when the player is dismissed — the calling
/// screen (e.g. Home) is still there underneath.
struct DirectPlayer: View {
    let item: JellyfinMediaItem
    let serverURL: URL
    let token: String
    let userId: String
    var onClosed: () -> Void = {}

    @State private var currentItemId: String
    @State private var currentTitle: String
    @State private var currentStartPosition: Double?
    @State private var streamURL: URL?
    @State private var playSessionId: String?
    @State private var mediaStreams: [MediaStream] = []
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var nextEpisode: JellyfinEpisode?
    @State private var seasonEpisodes: [JellyfinEpisode] = []

    init(
        item: JellyfinMediaItem,
        serverURL: URL,
        token: String,
        userId: String,
        onClosed: @escaping () -> Void = {}
    ) {
        self.item = item
        self.serverURL = serverURL
        self.token = token
        self.userId = userId
        self.onClosed = onClosed
        _currentItemId = State(initialValue: item.id)
        _currentTitle = State(initialValue: item.name)
        _currentStartPosition = State(initialValue: item.resumePositionSeconds)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let streamURL {
                PlayerView(
                    streamURL: streamURL,
                    title: currentTitle,
                    startPosition: currentStartPosition,
                    onDismiss: { onClosed() },
                    itemId: currentItemId,
                    serverURL: serverURL,
                    token: token,
                    userId: userId,
                    playSessionId: playSessionId,
                    mediaStreams: mediaStreams,
                    nextEpisode: nextEpisode,
                    onPlayNextEpisode: { episode in
                        Task { await play(episode) }
                    }
                )
                .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Reintentar") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                        Button("Cerrar") { close() }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.white)
                    }
                }
                .foregroundStyle(.white)
                .padding(32)
            } else {
                ProgressView("Preparando reproducción…")
                    .foregroundStyle(.white)
            }
        }
        .task(id: attempt) {
            await prepare()
            await resolveNextEpisode()
        }
    }

    // MARK: - Playback

    private func prepare() async {
        errorMessage = nil

        do {
            let client = JellyfinPlaybackClient()
            let info = try await client.fetchPlaybackInfo(
                userId: userId,
                serverURL: serverURL,
                token: token,
                itemId: currentItemId
            )

            guard let source = info.mediaSources.first else {
                errorMessage = "No hay fuente de reproducción disponible."
                return
            }

            playSessionId = info.playSessionId
            mediaStreams = source.mediaStreams

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
                    url: serverURL.appendingPathComponent("Videos/\(currentItemId)/stream"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [
                    URLQueryItem(name: "static", value: "true"),
                    URLQueryItem(name: "ApiKey", value: token),
                ]
                url = components?.url
            }

            guard let finalURL = url else {
                errorMessage = "URL de stream inválida."
                return
            }

            #if os(iOS)
            // Lock to landscape before mounting the player
            UIApplication.shared.tjf_orientationLock = [.landscapeLeft, .landscapeRight]
            #endif

            streamURL = finalURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Tear down the current player and start another episode in place.
    private func play(_ episode: JellyfinEpisode) async {
        streamURL = nil
        // Let PlayerView unmount (stops VLC, restores orientation) before re-mounting.
        try? await Task.sleep(for: .milliseconds(500))

        currentItemId = episode.id
        currentTitle = episode.name
        currentStartPosition = episode.resumePositionSeconds

        if let index = seasonEpisodes.firstIndex(where: { $0.id == episode.id }),
           index + 1 < seasonEpisodes.count {
            nextEpisode = seasonEpisodes[index + 1]
        } else {
            nextEpisode = nil
        }

        await prepare()
    }

    /// Best-effort: locate the next episode of the item's season so the credits
    /// overlay can offer "Siguiente episodio". Movies have no season → skipped.
    private func resolveNextEpisode() async {
        guard streamURL != nil,
              nextEpisode == nil,
              let seasonNumber = item.parentIndexNumber
        else { return }

        let detail = try? await JellyfinItemDetailClient().fetchItemDetail(
            userId: userId, serverURL: serverURL, token: token, itemId: item.id
        )
        guard let seriesId = detail?.seriesId else { return }

        let client = JellyfinLibraryClient()
        guard let seasons = try? await client.fetchSeasons(
            userId: userId, serverURL: serverURL, token: token, seriesId: seriesId
        ), let season = seasons.first(where: { $0.indexNumber == seasonNumber })
        else { return }

        guard let episodes = try? await client.fetchEpisodes(
            userId: userId, serverURL: serverURL, token: token,
            seriesId: seriesId, seasonId: season.id
        ) else { return }

        seasonEpisodes = episodes
        if let index = episodes.firstIndex(where: { $0.id == currentItemId }),
           index + 1 < episodes.count {
            nextEpisode = episodes[index + 1]
        }
    }

    private func close() {
        #if os(iOS)
        UIApplication.shared.tjf_orientationLock = .all
        #endif
        onClosed()
    }
}
