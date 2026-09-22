import SwiftUI
import ThisJellyFixCore

struct MediaCardView: View {
    let item: JellyfinMediaItem
    let imageURL: URL?
    @State private var isAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MareaImageView(
                url: imageURL,
                placeholder: String(item.name.prefix(1)),
                width: 150,
                height: 220
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottom) {
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

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
        .scaleEffect(isAppeared ? 1 : 0.9)
        .opacity(isAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double.random(in: 0...0.15))) {
                isAppeared = true
            }
        }
    }
}
