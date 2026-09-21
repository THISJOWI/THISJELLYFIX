import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

struct DetailView: View {
    let item: JellyfinMediaItem
    let serverURL: URL
    let token: String
    let userId: String

    @State private var detail: JellyfinItemDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
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

                        // Play button
                        playButton

                        // Episodes (for series)
                        if detail.type == "Series" {
                            episodesSection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
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
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadDetail() }
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

            MareaImageView(url: url, width: 600, height: 300)
                .frame(maxWidth: .infinity)
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
                .frame(height: 200)
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

                MareaImageView(url: posterURL, width: 120, height: 180)
                    .shadow(radius: 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name)
                    .font(.title.bold())

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

    private var playButton: some View {
        Button {
            // TODO: Phase 4 — playback
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Reproducir")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodios")
                .font(.headline)

            Text("La sección de episodios se implementará pronto.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
