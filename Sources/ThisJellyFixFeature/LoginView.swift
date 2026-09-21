import SwiftUI
import ThisJellyFixCore

struct LoginView: View {
    let serverName: String
    let serverURL: URL
    @Bindable var authModel: AuthModel

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .cyan.opacity(0.3), radius: 10)

                Text("Iniciar sesión")
                    .font(.title.bold())

                Text(serverName)
                    .foregroundStyle(.secondary)
            }

            // Form
            VStack(alignment: .leading, spacing: 12) {
                Text("Usuario")
                    .font(.headline)
                TextField("Tu usuario", text: $authModel.username)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Text("Contraseña")
                    .font(.headline)
                SecureField("Tu contraseña", text: $authModel.password)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .submitLabel(.go)
                    .onSubmit { loginIfPossible() }

                if let error = authModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 380)

            // Login button
            Button {
                loginIfPossible()
            } label: {
                if authModel.isAuthenticating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Entrar")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(
                authModel.username.trimmingCharacters(in: .whitespaces).isEmpty
                    || authModel.isAuthenticating
            )
            .frame(maxWidth: 380)
        }
        .padding(32)
    }

    private func loginIfPossible() {
        guard !authModel.username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await authModel.login(serverURL: serverURL) }
    }
}
