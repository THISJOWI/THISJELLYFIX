import SwiftUI
import ThisJellyFixCore

struct MediaCardView: View {
    let item: JellyfinMediaItem
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MareaImageView(
                url: imageURL,
                placeholder: String(item.name.prefix(1)),
                width: 150,
                height: 220
            )
            .overlay(alignment: .bottom) {
                if let percentage = item.playedPercentage, percentage > 0 {
                    VStack(spacing: 0) {
                        Spacer()
                        // Progress bar background
                        Rectangle()
                            .fill(.black.opacity(0.6))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(.cyan)
                                        .frame(width: geo.size.width * percentage / 100.0)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)

            if let year = item.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
