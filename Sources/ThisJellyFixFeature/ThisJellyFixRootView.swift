import Observation
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

public struct ThisJellyFixRootView: View {
    @State private var model = ServerConnectionModel()

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
                MareaHomeView(server: server, onDisconnect: model.disconnect)
            } else {
                ServerConnectionView(model: model)
            }
        }
        .preferredColorScheme(.dark)
    }
}

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

private struct ServerConnectionView: View {
    @Bindable var model: ServerConnectionModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.mint, .cyan)

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

private struct MareaHomeView: View {
    let server: JellyfinServer
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("La Marea")
                        .font(.largeTitle.bold())
                    Text(server.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Desconectar", action: onDisconnect)
            }

            ContentUnavailableView(
                "Servidor encontrado",
                systemImage: "checkmark.circle.fill",
                description: Text("El siguiente paso conecta tu perfil y tu biblioteca de Jellyfin.")
            )
        }
        .padding(32)
    }
}
