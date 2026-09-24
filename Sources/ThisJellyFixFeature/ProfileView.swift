import SwiftUI
import ThisJellyFixCore

struct ProfileView: View {
    let userName: String
    let onLogout: () -> Void
    var serverURL: URL? = nil
    var token: String? = nil
    var userId: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(.cyan.opacity(0.2))
                            .frame(width: 100, height: 100)
                        Image(systemName: "person.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.cyan)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 4) {
                        Text(userName)
                            .font(.title2.bold())
                        Text("Usuario Jellyfin")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Favorites section
                    if let serverURL, let token, let userId {
                        FavoritesView(serverURL: serverURL, token: token, userId: userId)
                            .frame(height: 300)
                    }

                    // Skip segment preferences
                    SkipSettingsSection()

                    // Preferred playback languages
                    LanguageSettingsSection()

                    // Actions
                    VStack(spacing: 12) {
                        Button {
                            onLogout()
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Cerrar sesión")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 32)
                }
            }
            .navigationTitle("Perfil")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

// MARK: - Skip Settings

private struct SkipSettingsSection: View {
    // @AppStorage inside @Observable-adjacent views: plain @State-free view,
    // so no @ObservationIgnored needed here.
    @AppStorage(SkipSettings.Key.autoSkip) private var autoSkip = true
    @AppStorage(SkipSettings.Key.intro) private var introEnabled = true
    @AppStorage(SkipSettings.Key.recap) private var recapEnabled = true
    @AppStorage(SkipSettings.Key.credits) private var creditsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Salto automático")
                .font(.headline)

            Toggle(isOn: $autoSkip) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-saltar segmentos")
                    Text("Salta solo tras 5 s dentro de un segmento")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Introducción", isOn: $introEnabled)
            Toggle("Resumen", isOn: $recapEnabled)
            Toggle("Ending", isOn: $creditsEnabled)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }
}

// MARK: - Language Settings

private struct LanguageSettingsSection: View {
    @AppStorage(LanguagePreferences.Key.audio) private var preferredAudio: String?
    @AppStorage(LanguagePreferences.Key.subtitles) private var preferredSubtitles: String?

    /// None = no preference (player untouched).
    private static let noPreference = ""

    /// Common picker choices + the system language as suggested default.
    private var options: [String] {
        var codes = ["es", "en", "ja", "pt", "fr", "de", "it"]
        if let system = LanguagePreferences.systemDefault, !codes.contains(system) {
            codes.insert(system, at: 0)
        }
        return codes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Idioma")
                .font(.headline)

            Picker("Audio preferido", selection: $preferredAudio) {
                Text("Sin preferencia").tag(String?.none)
                ForEach(options, id: \.self) { code in
                    Text(label(for: code)).tag(String?.some(code))
                }
            }

            Divider()

            Picker("Subtítulos preferidos", selection: $preferredSubtitles) {
                Text("Sin preferencia").tag(String?.none)
                ForEach(options, id: \.self) { code in
                    Text(label(for: code)).tag(String?.some(code))
                }
            }

            Text("Al abrir un vídeo se elige tu idioma si está disponible. Si cambias dentro del reproductor, se respeta hasta el siguiente.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .onAppear {
            // Preselect system language on first run (only if never set).
            if preferredAudio == nil, let system = LanguagePreferences.systemDefault {
                preferredAudio = system
            }
            if preferredSubtitles == nil, let system = LanguagePreferences.systemDefault {
                preferredSubtitles = system
            }
        }
    }

    private func label(for code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        if code == LanguagePreferences.systemDefault {
            return "\(name) (sistema)"
        }
        return name
    }
}
