import SwiftUI
import ThisJellyFixCore

struct MediaCardView: View {
    let item: JellyfinMediaItem
    let imageURL: URL?
    @State private var isAppeared = false

    private var isEpisode: Bool { item.type == "Episode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail
            MareaImageView(
                url: imageURL,
                placeholder: String(item.name.prefix(1)),
                width: cardWidth,
                height: cardHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                // Progress bar
                if let percentage = item.playedPercentage, percentage > 0 {
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(.black.opacity(0.6))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(.cyan)
                                        .frame(width: geo.size.width * percentage / 100.0)
                                        .animation(.easeInOut(duration: 0.5), value: percentage)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Play button overlay for episodes with progress
                if isEpisode, item.playedPercentage != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .opacity(isAppeared ? 1 : 0)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            // Text below card
            if isEpisode {
                // Series name (bold, primary)
                if let seriesName = item.seriesName {
                    Text(seriesName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: cardWidth, alignment: .leading)
                }
                // Episode label + name
                HStack(spacing: 4) {
                    if let label = item.episodeLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
            } else {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                if let year = item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scaleEffect(isAppeared ? 1 : 0.9)
        .opacity(isAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double.random(in: 0...0.15))) {
                isAppeared = true
            }
        }
    }

    private var cardWidth: CGFloat {
        isEpisode ? 240 : 150
    }

    private var cardHeight: CGFloat {
        isEpisode ? 135 : 220  // 16:9 for episodes, portrait for movies/series
    }
}
