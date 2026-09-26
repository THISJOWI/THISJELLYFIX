#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// Poster card for an external catalogue item (not yet in the library).
/// Same footprint as `MediaCardView` so rows stay visually aligned.
struct CatalogCardView: View {
    let item: CatalogItem
    /// Download state for this item, if the user already ordered it.
    var state: DownloadState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MareaImageView(
                url: item.posterURL,
                placeholder: String(item.title.prefix(1)),
                width: 150,
                height: 220
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if let state {
                    let badge = badge(for: state)
                    Label(badge.text, systemImage: badge.icon)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            Text(item.title)
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

    private struct Badge {
        let text: String
        let icon: String
        let color: Color
    }

    private func badge(for state: DownloadState) -> Badge {
        switch state {
        case .submitting: Badge(text: "Enviando", icon: "paperplane.fill", color: .gray)
        case .queued: Badge(text: "En cola", icon: "clock.fill", color: .orange)
        case .downloading(let progress):
            Badge(text: "\(Int(progress))%", icon: "arrow.down.circle.fill", color: .cyan)
        case .paused: Badge(text: "Pausado", icon: "pause.fill", color: .gray)
        case .completed: Badge(text: "Listo", icon: "checkmark.circle.fill", color: .green)
        case .available: Badge(text: "Disponible", icon: "play.circle.fill", color: .green)
        case .failed: Badge(text: "Fallo", icon: "exclamationmark.triangle.fill", color: .red)
        }
    }
}
#endif
