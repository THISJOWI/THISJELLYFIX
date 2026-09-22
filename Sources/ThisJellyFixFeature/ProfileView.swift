import SwiftUI

struct ProfileView: View {
    let userName: String
    let onLogout: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Avatar
                ZStack {
                    Circle()
                        .fill(.cyan.opacity(0.2))
                        .frame(width: 100, height: 100)
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.cyan)
                }

                VStack(spacing: 4) {
                    Text(userName)
                        .font(.title2.bold())
                    Text("Usuario Jellyfin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

                Spacer()
                Spacer()
            }
            .navigationTitle("Perfil")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
