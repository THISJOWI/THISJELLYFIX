#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery
import ThisJellyFixNetworking
#if os(iOS)
import UIKit
#endif

/// Profile section for the external services: TMDB key, Radarr/Sonarr
/// endpoint + key, and a connection test per service.
///
/// URLs live in UserDefaults (`@AppStorage`-compatible keys); API keys go
/// straight to the Keychain through `IntegrationConfig`.
struct IntegrationsSection: View {
    @AppStorage(IntegrationConfig.DefaultsKey.radarrURL) private var radarrURL = ""
    @AppStorage(IntegrationConfig.DefaultsKey.sonarrURL) private var sonarrURL = ""

    @State private var tmdbKey = ""
    @State private var radarrKey = ""
    @State private var sonarrKey = ""

    @State private var showTmdbKey = false
    @State private var showRadarrKey = false
    @State private var showSonarrKey = false

    @State private var testing: DownloadService?
    @State private var testResult: [DownloadService: Bool] = [:]
    /// Why the last test failed. Without it every cause (Red local, ATS,
    /// key rejected, dead tunnel) looked like the same red label.
    @State private var testFailure: [DownloadService: String] = [:]
    @State private var tmdbTesting = false
    @State private var tmdbResult: Bool?

    private let config = IntegrationConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Integraciones")
                .font(.headline)

            tmdbField
            Divider()
            serviceFields(service: .radarr)
            Divider()
            serviceFields(service: .sonarr)

            Text("Las claves se guardan en el Keychain del dispositivo. Radarr/Sonarr deben ser accesibles desde este dispositivo (LAN o túnel).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .onAppear(perform: load)
        .onChange(of: radarrURL) { _, _ in save() }
        .onChange(of: sonarrURL) { _, _ in save() }
        .onChange(of: tmdbKey) { _, _ in save() }
        .onChange(of: radarrKey) { _, _ in save() }
        .onChange(of: sonarrKey) { _, _ in save() }
    }

    // MARK: - TMDB

    private var tmdbField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TMDB — metadatos y recomendaciones")
                .font(.subheadline.weight(.medium))

            HStack {
                if showTmdbKey {
                    TextField("API key de TMDB", text: $tmdbKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API key de TMDB", text: $tmdbKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    showTmdbKey.toggle()
                } label: {
                    Image(systemName: showTmdbKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await testTmdb() }
                } label: {
                    if tmdbTesting { ProgressView().scaleEffect(0.8) } else { Text("Probar") }
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
                .disabled(tmdbKey.isEmpty || tmdbTesting)

                if let ok = tmdbResult {
                    Label(
                        ok ? "Conectado" : "Key rechazada",
                        systemImage: ok ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(ok ? .green : .red)
                }
            }
        }
    }

    // MARK: - Radarr / Sonarr

    private func serviceFields(service: DownloadService) -> some View {
        let isRadarr = service == .radarr
        let url = isRadarr ? $radarrURL : $sonarrURL
        let key = isRadarr ? $radarrKey : $sonarrKey
        let show = isRadarr ? $showRadarrKey : $showSonarrKey

        return VStack(alignment: .leading, spacing: 6) {
            Text(isRadarr ? "Radarr — películas" : "Sonarr — series")
                .font(.subheadline.weight(.medium))

            TextField(isRadarr ? "http://radarr.local:7878" : "http://sonarr.local:8989", text: url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif

            HStack {
                if show.wrappedValue {
                    TextField("API key", text: key)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API key", text: key)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    show.wrappedValue.toggle()
                } label: {
                    Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            Text("Consigue la API key en \(isRadarr ? "Radarr" : "Sonarr") → Settings → General → Security → API Key")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                let isFilled = !url.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                Button {
                    Task { await test(service) }
                } label: {
                    if testing == service {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("Probar conexión")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
                .disabled(!isFilled || testing != nil)

                if let ok = testResult[service] {
                    Label(
                        ok ? "Conectado" : "Fallo de conexión",
                        systemImage: ok ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(ok ? .green : .red)

                    if !ok {
                        // Say why: the user cannot tell a blocked local
                        // network from a rejected key by looking at a label.
                        Text(testFailure[service] ?? "")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            #if os(iOS)
            if testResult[isRadarr ? .radarr : .sonarr] == false {
                HStack(spacing: 12) {
                    Button("Permiso de red local") {
                        LocalNetworkAuthorizer.shared.triggerPrompt()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.cyan)

                    Button("Abrir ajustes del sistema") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            #endif
        }
    }

    // MARK: - Actions

    private func load() {
        tmdbKey = config.tmdbApiKey ?? ""
        radarrKey = config.radarrApiKey ?? ""
        sonarrKey = config.sonarrApiKey ?? ""
        LocalNetworkAuthorizer.shared.triggerPrompt()
    }

    private func save() {
        config.tmdbApiKey = tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.radarrApiKey = radarrKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sonarrApiKey = sonarrKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func test(_ service: DownloadService) async {
        save()
        LocalNetworkAuthorizer.shared.triggerPrompt()
        testing = service
        defer { testing = nil }

        let isRadarr = service == .radarr
        let rawURL = (isRadarr ? radarrURL : sonarrURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawKey = (isRadarr ? radarrKey : sonarrKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = isRadarr ? "Radarr" : "Sonarr"

        guard !rawURL.isEmpty else {
            testResult[service] = false
            testFailure[service] = "Falta la URL de \(name)."
            return
        }
        guard !rawKey.isEmpty else {
            testResult[service] = false
            testFailure[service] = "Falta la API key de \(name) (encuéntrala en Ajustes → General → Seguridad de \(name))."
            return
        }

        var normalizedString = rawURL
        if !normalizedString.contains("://") { normalizedString = "http://" + normalizedString }
        while normalizedString.hasSuffix("/") { normalizedString.removeLast() }

        guard let targetURL = URL(string: normalizedString) else {
            testResult[service] = false
            testFailure[service] = "La URL no tiene un formato válido."
            return
        }

        let ok: Bool
        do {
            switch service {
            case .radarr:
                try await RadarrClient(baseURL: targetURL, apiKey: rawKey).testConnection()
            case .sonarr:
                try await SonarrClient(baseURL: targetURL, apiKey: rawKey).testConnection()
            }
            ok = true
            testFailure[service] = nil
        } catch {
            ok = false
            testFailure[service] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        testResult[service] = ok
    }

    @MainActor
    private func testTmdb() async {
        save()
        tmdbTesting = true
        defer { tmdbTesting = false }
        guard let key = config.tmdbApiKey, !key.isEmpty else {
            tmdbResult = false
            return
        }
        do {
            _ = try await TMDBMetadataProvider(apiKey: key).trending(kind: .movie)
            tmdbResult = true
        } catch {
            tmdbResult = false
        }
    }
}
#endif
