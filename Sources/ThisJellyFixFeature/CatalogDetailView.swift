#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// Detail screen for a catalogue item that is NOT in the Jellyfin library:
/// poster, overview, download action (fast path + options sheet).
struct CatalogDetailView: View {
    let item: CatalogItem
    @Environment(DiscoveryModel.self) private var discovery: DiscoveryModel?
    @Environment(\.dismiss) private var dismiss

    @State private var showOptions = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false

    private var state: DownloadState? {
        discovery?.coordinator.entries.first { entry in
            (entry.tmdbId != nil && entry.tmdbId == item.tmdbId) || entry.title == item.title
        }?.state
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                actionButtons
                if let overview = item.overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sinopsis").font(.headline)
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .background(Color.black.opacity(0.3))
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showOptions) {
            DownloadOptionsSheet(item: item) { options in
                Task { await submit(options: options) }
            }
        }
        .alert("¿Quitar de la cola?", isPresented: $confirmingRemove) {
            Button("Quitar", role: .destructive) { Task { await remove() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminará la entrada de Radarr/Sonarr. Los archivos ya descargados no se borran.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            MareaImageView(
                url: item.posterURL,
                placeholder: String(item.title.prefix(1)),
                width: 130,
                height: 195
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.title3.bold())
                if let year = item.year {
                    Text(String(year)).foregroundStyle(.secondary)
                }
                Label(
                    item.kind == .movie ? "Película" : "Serie",
                    systemImage: item.kind == .movie ? "film.fill" : "tv.fill"
                )
                .font(.caption)
                .foregroundStyle(.cyan)
                if item.isInLibrary {
                    Label("Ya en tu biblioteca", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.isInLibrary {
            // Nothing to download — the title is already playable.
        } else if !(discovery?.hasDownloadService ?? false) {
            Label("Configura Radarr/Sonarr en Perfil para descargar.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let state, state.isFinished == false || state == .available {
            activeDownload(state)
        } else {
            HStack(spacing: 12) {
                Button {
                    Task { await submit(options: nil) }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        Label("Descargar", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(isSubmitting)

                Button {
                    showOptions = true
                } label: {
                    Label("Opciones", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
                .disabled(isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func activeDownload(_ state: DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .submitting:
                label("Enviando orden al servicio…", "paperplane.fill", .gray)
            case .queued:
                label("En cola de descarga", "clock.fill", .orange)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    label("Descargando · \(Int(progress))%", "arrow.down.circle.fill", .cyan)
                    ProgressView(value: progress, total: 100)
                        .tint(.cyan)
                }
            case .paused(let progress):
                label("Pausada · \(Int(progress))%", "pause.fill", .gray)
            case .completed:
                label("Descarga terminada — aparecerá en tu biblioteca", "checkmark.circle.fill", .green)
            case .available:
                label("Disponible en tu biblioteca", "play.circle.fill", .green)
            case .failed(let reason):
                label("Fallo: \(reason)", "exclamationmark.triangle.fill", .red)
            }

            if state == .available || state == .completed {
                Button("Hecho") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            } else if case .failed = state {
                Button("Reintentar") {
                    Task { await submit(options: nil) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            } else {
                Button("Quitar de la cola", role: .destructive) {
                    confirmingRemove = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
    }

    // MARK: - Actions

    private func submit(options: AddOptions?) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            guard let discovery else { return }
            try await discovery.submit(item, options: options)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        await discovery?.coordinator.removeEntries(matching: item)
    }
}
#endif
