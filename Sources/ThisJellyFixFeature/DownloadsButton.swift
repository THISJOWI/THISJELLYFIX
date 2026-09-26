#if os(iOS) || os(macOS)
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixDiscovery

/// Toolbar entry to the downloads panel, with a live count badge and an
/// automatic poll start so states keep moving without opening the panel.
struct DownloadsButton: View {
    let discovery: DiscoveryModel
    @State private var showPanel = false

    private var activeCount: Int {
        discovery.coordinator.entries.filter { !$0.state.isFinished }.count
    }

    var body: some View {
        Button {
            showPanel = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPanel) {
            DownloadsView()
                .environment(discovery)
        }
        .task {
            // Active orders keep tracking while Home is on screen.
            if activeCount > 0 || !discovery.coordinator.entries.isEmpty {
                discovery.startPolling()
            }
        }
    }
}
#endif
