#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// Downloads manager: live list of orders with progress, cancel/retry and
/// a banner when a service can't be reached.
struct DownloadsView: View {
    @Environment(DiscoveryModel.self) private var discovery
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEntry: DownloadEntry?

    var body: some View {
        NavigationStack {
            Group {
                if discovery.coordinator.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Descargas")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await discovery.refreshDownloads() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await discovery.refreshDownloads() }
            .task {
                // Panel open = user is watching: poll while it's visible.
                await discovery.refreshDownloads()
                discovery.startPolling()
            }
            .alert("Quitar de la cola", isPresented: Binding(
                get: { confirmingEntry != nil },
                set: { if !$0 { confirmingEntry = nil } }
            )) {
                Button("Quitar", role: .destructive) {
                    if let entry = confirmingEntry, let item = item(for: entry) {
                        Task { await discovery.coordinator.removeEntries(matching: item) }
                    }
                    confirmingEntry = nil
                }
                Button("Cancelar", role: .cancel) { confirmingEntry = nil }
            } message: {
                Text("Se elimina la entrada del servicio. Los archivos ya descargados no se borran.")
            }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 46))
                .foregroundStyle(.cyan.opacity(0.6))
            Text("Sin descargas")
                .font(.headline)
            Text("Las órdenes que envíes a Radarr/Sonarr aparecerán aquí.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private var list: some View {
        List {
            if let error = discovery.downloadError {
                Section {
                    Label(error.localizedDescription, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(discovery.coordinator.entries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: DownloadEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                statusBadge(entry.state)
            }

            switch entry.state {
            case .downloading(let progress):
                ProgressView(value: progress, total: 100)
                    .tint(.cyan)
            case .submitting, .queued, .paused, .completed, .available, .failed:
                EmptyView()
            }

            HStack {
                Label(
                    entry.service == .radarr ? "Radarr" : "Sonarr",
                    systemImage: entry.service == .radarr ? "film.fill" : "tv.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                if entry.state.isFinished {
                    Button("Descartar") {
                        Task { await discovery.coordinator.removeEntries(matching: entryAsItem(entry)) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                } else {
                    Button("Quitar", role: .destructive) {
                        confirmingEntry = entry
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ state: DownloadState) -> some View {
        let (text, icon, color): (String, String, Color) = switch state {
        case .submitting: ("Enviando", "paperplane.fill", .gray)
        case .queued: ("En cola", "clock.fill", .orange)
        case .downloading(let p): ("\(Int(p))%", "arrow.down.circle.fill", .cyan)
        case .paused: ("Pausado", "pause.fill", .gray)
        case .completed: ("Listo", "checkmark.circle.fill", .green)
        case .available: ("Disponible", "play.circle.fill", .green)
        case .failed: ("Fallo", "exclamationmark.triangle.fill", .red)
        }
        return Label(text, systemImage: icon)
            .font(.caption2.bold())
            .foregroundStyle(color)
    }

    /// Rebuild a catalogue item from an entry so removal can be shared
    /// with the detail screen's cancel path.
    private func entryAsItem(_ entry: DownloadEntry) -> CatalogItem {
        CatalogItem(
            id: entry.tmdbId ?? entry.id,
            kind: entry.service == .radarr ? .movie : .series,
            title: entry.title,
            year: nil, overview: nil, posterURL: nil, backdropURL: nil,
            tmdbId: entry.tmdbId, imdbId: nil
        )
    }

    private func item(for entry: DownloadEntry) -> CatalogItem? {
        entryAsItem(entry)
    }
}
#endif
