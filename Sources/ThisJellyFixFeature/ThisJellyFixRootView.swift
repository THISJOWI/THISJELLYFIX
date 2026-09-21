import Observation
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

public struct ThisJellyFixRootView: View {
    @State private var model = ServerConnectionModel()
    @State private var authModel = AuthModel()
    @State private var libraryModel: LibraryModel?
    @State private var isLoadingLibrary = false

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.05, green: 0.08, blue: 0.15), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let server = model.server {
                if authModel.isAuthenticated {
                    if isLoadingLibrary {
                        ProgressView("Cargando biblioteca…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let libModel = libraryModel {
                        HomeView(
                            libraryModel: libModel,
                            serverURL: server.baseURL,
                            token: KeychainStore().read(key: KeychainKey.accessToken) ?? "",
                            userId: authModel.currentUser?.id ?? "",
                            userName: authModel.currentUser?.name ?? "",
                            onLogout: {
                                authModel.logout()
                                libraryModel = nil
                            }
                        )
                    } else {
                        // First time authenticated — load library
                        Color.clear
                            .onAppear {
                                Task {
                                    await loadLibrary()
                                }
                            }
                    }
                } else {
                    LoginView(
                        serverName: server.name,
                        serverURL: server.baseURL,
                        authModel: authModel
                    )
                }
            } else {
                ServerConnectionView(model: model)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadLibrary() async {
        guard !isLoadingLibrary else { return }
        guard let server = model.server,
              let user = authModel.currentUser else { return }

        let keychain = KeychainStore()
        guard let token = keychain.read(key: KeychainKey.accessToken) else { return }

        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        let libModel = LibraryModel(
            serverURL: server.baseURL,
            userId: user.id,
            token: token
        )
        await libModel.load()
        libraryModel = libModel
    }
}

// MARK: - Server Connection

@MainActor
@Observable
final class ServerConnectionModel {
    var address = ""
    var isConnecting = false
    var errorMessage: String?
    var server: JellyfinServer?

    private let probe: any JellyfinServerProbing

    init(probe: any JellyfinServerProbing = JellyfinServerProbe()) {
        self.probe = probe
    }

    func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            let url = try ServerAddress.normalizedURL(from: address)
            let info = try await probe.publicInfo(at: url)
            server = JellyfinServer(baseURL: url, name: info.serverName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        server = nil
        address = ""
        errorMessage = nil
    }
}

// MARK: - Server Connection View

private struct ServerConnectionView: View {
    @Bindable var model: ServerConnectionModel

    var body: some View {
        VStack(spacing: 22) {
            Image("AppIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .cyan.opacity(0.3), radius: 12)

            VStack(spacing: 8) {
                Text("thisjellyfix")
                    .font(.largeTitle.bold())
                Text("Tu biblioteca. A tu manera.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Servidor Jellyfin")
                    .font(.headline)
                TextField("https://jellyfin.example.com", text: $model.address)
                    .textContentType(.URL)
                    .padding(12)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .submitLabel(.go)
                    .onSubmit { Task { await model.connect() } }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 440)

            Button {
                Task { await model.connect() }
            } label: {
                if model.isConnecting {
                    ProgressView().tint(.black)
                } else {
                    Text("Conectar")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isConnecting)
        }
        .padding(32)
    }
}
