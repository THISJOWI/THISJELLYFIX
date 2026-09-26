#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// Options before ordering a download: quality profile, root folder and
/// (series only) season monitoring + immediate search. Loads the choices
/// from the service itself, so what you see is what Radarr/Sonarr accept.
struct DownloadOptionsSheet: View {
    let item: CatalogItem
    let onConfirm: (AddOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ArrQualityProfile] = []
    @State private var folders: [ArrRootFolder] = []
    @State private var selectedProfileId: Int?
    @State private var selectedFolderPath: String?
    @State private var monitor: SeriesMonitor = .all
    @State private var searchNow = true
    @State private var monitored = true
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                Section("Calidad") {
                    if isLoading && profiles.isEmpty {
                        ProgressView()
                    } else if profiles.isEmpty {
                        Text("El servicio no devolvió perfiles de calidad.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Perfil", selection: $selectedProfileId) {
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                    }
                }

                Section("Carpeta destino") {
                    if folders.isEmpty {
                        Text("Sin carpetas raíz configuradas en el servicio.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Carpeta", selection: $selectedFolderPath) {
                            ForEach(folders, id: \.path) { folder in
                                Text(folder.path).tag(Optional(folder.path))
                            }
                        }
                    }
                }

                if item.kind == .series {
                    Section("Series") {
                        Picker("Monitorizar", selection: $monitor) {
                            Text("Todas las temporadas").tag(SeriesMonitor.all)
                            Text("Solo la primera").tag(SeriesMonitor.first)
                            Text("Solo la última").tag(SeriesMonitor.latest)
                            Text("Ninguna").tag(SeriesMonitor.none)
                        }
                        Toggle("Buscar episodios ausentes ya", isOn: $searchNow)
                    }
                }

                Section {
                    Toggle("Marcar como monitoreado", isOn: $monitored)
                    if item.kind == .movie {
                        Toggle("Buscar ahora", isOn: $searchNow)
                    }
                }
            }
            .navigationTitle("Opciones de descarga")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Descargar") { confirm() }
                        .disabled(selectedProfileId == nil || selectedFolderPath == nil)
                }
            }
            .task { await load() }
        }
    }

    private func confirm() {
        guard let profile = selectedProfileId, let folder = selectedFolderPath else { return }
        onConfirm(AddOptions(
            qualityProfileId: profile,
            rootFolderPath: folder,
            monitored: monitored,
            searchNow: searchNow
        ))
        dismiss()
    }

    @MainActor
    private func load() async {
        guard isLoading else { return }
        let config = IntegrationConfig()
        let service = item.downloadService
        guard let url = config.baseURL(service: service),
              let key = config.apiKey(service: service)
        else {
            loadError = "Servicio no configurado."
            isLoading = false
            return
        }

        do {
            switch service {
            case .radarr:
                let client = RadarrClient(baseURL: url, apiKey: key)
                profiles = try await client.qualityProfiles()
                folders = try await client.rootFolders()
            case .sonarr:
                let client = SonarrClient(baseURL: url, apiKey: key)
                profiles = try await client.qualityProfiles()
                folders = try await client.rootFolders()
            }
            selectedProfileId = profiles.first?.id
            selectedFolderPath = folders.first?.path
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
#endif
