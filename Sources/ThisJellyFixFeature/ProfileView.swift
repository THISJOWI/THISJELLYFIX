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
