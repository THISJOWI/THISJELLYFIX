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
