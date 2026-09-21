import SwiftUI
import AVKit
import ThisJellyFixCore

struct PlayerView: View {
    let streamURL: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                }
            } else {
                ProgressView("Preparando reproducción…")
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: streamURL)
        self.player = avPlayer
        avPlayer.play()
    }
}
