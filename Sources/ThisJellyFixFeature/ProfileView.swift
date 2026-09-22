import SwiftUI

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
