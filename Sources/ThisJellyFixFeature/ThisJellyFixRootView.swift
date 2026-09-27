import Observation
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if os(iOS)
import AVFoundation
#endif

public struct ThisJellyFixRootView: View {
    @State private var model = ServerConnectionModel()
    @State private var authModel = AuthModel()
    @State private var libraryModel: LibraryModel?
    @State private var isLoadingLibrary = false
    /// Discovery + downloads state. Rebuilt whenever the library model
    /// changes so its library snapshot points at the live model.
    @State private var discoveryModel: DiscoveryModel?
    #if os(iOS)
    @State private var selectedTab: MareaTab = .home
    @Environment(\.scenePhase) private var scenePhase
    /// Floating PiP whose fullscreen player was already dismissed: the root
    /// view is the only owner that survives the player, so it re-presents it
    /// when the system asks for the UI back (4.5 — the old restore closure
    /// lived in the player's view model and died with it).
    @State private var restoredPlayback: RestoredPlayback?
    /// Root registrations live for the process lifetime (static, not @State:
    /// SwiftUI may rebuild the view, re-registering must not stack handlers).
    private static var pipRestoreHandlerId: UUID?
    private static var pipClosedHandlerId: UUID?

    /// Everything needed to rebuild the fullscreen player at `position`.
    private struct RestoredPlayback: Identifiable {
        let id = UUID()
        let context: PipSession.Context
        let position: Double
    }
    #endif

    public init() {}

    /// Decoded Handoff payload waiting to be acted on once the library is loaded.
    @State private var pendingHandoff: HandoffPayload?

    /// Lightweight struct carrying everything decoded from a NSUserActivity.
    private struct HandoffPayload {
        let itemId: String
        let serverURL: URL
        let title: String
        let mediaType: String
        let position: Double?   // non-nil only for "playing" activities
    }

    public var body: some View {
        ZStack {
            #if os(iOS)
            // Layer host for the floating PiP session. It must be alive for the
            // WHOLE app lifetime: PipSession attaches the layer synchronously
            // the moment a session starts, and starting PiP a render early (with
            // `superlayer == nil`) is what made the window never appear. It sits
            // BEHIND the opaque gradient so an active session can never paint
            // over Home (the black box that was covering the rows); `cleanup()`
            // detaches the layer when the session ends.
            PipLayerHostView(isActive: PipSession.shared.isActive)
                .allowsHitTesting(false)
            #endif
            LinearGradient(
                colors: [.black, Color(red: 0.05, green: 0.08, blue: 0.15), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let server = model.server {
                if authModel.isAuthenticated {
                    if let libModel = libraryModel {
                        // Home renders its own loading skeleton, so the app is
                        // interactive while the row requests are still flying.
                        #if os(iOS)
                        mainContent(libModel: libModel, server: server)
                            .environment(discoveryModel)
                        #else
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
                        .environment(discoveryModel)
                        #endif
                    } else if isLoadingLibrary {
                        ProgressView("Cargando biblioteca…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                            .onAppear {
                                Task { await loadLibrary() }
                            }
                    }
                } else {
                    LoginView(
                        serverName: server.name,
                        serverURL: server.baseURL,
                        authModel: authModel,
                        onBack: { model.disconnect() }
                    )
                }
            } else {
                ServerConnectionView(model: model)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        // The system asks for the fullscreen UI back when the user taps the
        // floating window and no player is alive to claim the request.
        .fullScreenCover(item: $restoredPlayback) { restored in
            PlayerView(
                streamURL: restored.context.streamURL ?? fallbackStreamURL(restored.context),
                title: restored.context.title,
                startPosition: restored.position,
                onDismiss: {
                    restoredPlayback = nil
                    refreshResumeSoon()
                },
                itemId: restored.context.itemId,
                serverURL: restored.context.serverURL,
                token: restored.context.token,
                userId: restored.context.userId,
                playSessionId: restored.context.playSessionId,
                mediaStreams: restored.context.mediaStreams
            )
        }
        .onChange(of: selectedTab) { _, tab in
            // TabView keeps views alive, so onAppear won't re-fire on tab
            // switches — refresh resume when user returns to Inicio.
            if tab == .home, let lib = libraryModel {
                Task { await lib.refreshResume() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from another app/client: Home is still mounted, so
            // NO onAppear fires, and progress recorded elsewhere (web, TV,
            // another phone) never reached "Estás viendo".
            guard phase == .active, let lib = libraryModel else { return }
            Task { await lib.refreshResume() }
        }
        .onAppear {
            configureAudioSession()
            registerPipHandlers()
        }
        #endif
        .task {
            if model.server != nil && !authModel.isAuthenticated {
                _ = await authModel.restoreSession(serverURL: model.server!.baseURL)
            }
        }
        // MARK: - Handoff reception
        // Browsing: just open the app — nothing extra to do.
        .onContinueUserActivity(HandoffActivity.browsing) { _ in
            #if os(iOS)
            selectedTab = .home
            #endif
        }
        // Detail: navigate to the item's detail screen.
        .onContinueUserActivity(HandoffActivity.detail) { activity in
            guard let info       = activity.userInfo,
                  let itemId     = info[HandoffActivity.Key.itemId]     as? String,
                  let serverStr  = info[HandoffActivity.Key.serverURL]  as? String,
                  let serverURL  = URL(string: serverStr),
                  let title      = info[HandoffActivity.Key.title]      as? String,
                  let mediaType  = info[HandoffActivity.Key.mediaType]  as? String
            else { return }

            pendingHandoff = HandoffPayload(
                itemId: itemId,
                serverURL: serverURL,
                title: title,
                mediaType: mediaType,
                position: nil
            )
            #if os(iOS)
            selectedTab = .home
            #endif
        }
        // Playing: open the detail screen (or the player directly if possible)
        // at the stored position so the user picks up right where they left off.
        .onContinueUserActivity(HandoffActivity.playing) { activity in
            guard let info       = activity.userInfo,
                  let itemId     = info[HandoffActivity.Key.itemId]     as? String,
                  let serverStr  = info[HandoffActivity.Key.serverURL]  as? String,
                  let serverURL  = URL(string: serverStr),
                  let title      = info[HandoffActivity.Key.title]      as? String
            else { return }

            let position = info[HandoffActivity.Key.position] as? Double

            pendingHandoff = HandoffPayload(
                itemId: itemId,
                serverURL: serverURL,
                title: title,
                mediaType: "",
                position: position
            )
            #if os(iOS)
            selectedTab = .home
            #endif
        }
        #if canImport(CoreSpotlight)
        // Spotlight Search result tapped by the user in system search.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            let prefix = "tjf://item/"
            let itemId = identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
            guard let server = model.server else { return }

            pendingHandoff = HandoffPayload(
                itemId: itemId,
                serverURL: server.baseURL,
                title: "",
                mediaType: "",
                position: nil
            )
            #if os(iOS)
            selectedTab = .home
            #endif
        }
        #endif
        // Once a payload arrives AND the library is loaded, find the item and
        // push the DetailView. The library may still be loading when the
        // activity fires, so we watch both triggers.
        .onChange(of: pendingHandoff?.itemId) { _, newId in
            guard newId != nil else { return }
            resolveHandoffIfReady()
        }
        .onChange(of: libraryModel != nil) { _, ready in
            guard ready else { return }
            resolveHandoffIfReady()
        }
    }

    #if os(iOS)
    /// Static stream URL (4.3): the app only ever let VLCKit / PipSession set
    /// up the session implicitly — background audio then depended on whoever
    /// happened to configure it first. Category is set once, up front;
    /// activation stays with the players (activating on the login screen would
    /// silence whatever else is playing).
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, mode: .moviePlayback)
            TJFLog("audio session: category=.playback configured")
        } catch {
            TJFLog("audio session: configure FAILED \(error)")
        }
    }

    /// Permanent PiP observers: the live player registers while its view is on
    /// screen and unregisters on disappear, so without these the system's
    /// restore request had NO owner once the cover closed → PiP died (4.5).
    private func registerPipHandlers() {
        if let id = Self.pipRestoreHandlerId {
            PipSession.shared.removeRestoreHandler(id)
        }
        if let id = Self.pipClosedHandlerId {
            PipSession.shared.removeClosedHandler(id)
        }

        Self.pipRestoreHandlerId = PipSession.shared.addRestoreHandler { [self] position in
            // Another fullscreen player already owns the UI (Home's direct
            // player, DetailView's cover): presenting a SECOND one on top
            // fails silently — the system had already been told "yes", so the
            // window closed with nothing playing. Refuse instead: the session
            // then reports stop and the resume entry survives.
            guard PlayerView.presentedCount == 0 else {
                TJFLog("pip: root refuses restore — \(PlayerView.presentedCount) fullscreen player(s) on screen")
                return false
            }
            guard let request = PipSession.shared.restoreRequest,
                  request.context.streamURL != nil
            else {
                TJFLog("pip: root cannot restore — request=\(PipSession.shared.restoreRequest != nil)")
                return false
            }
            TJFLog("pip: root re-presenting fullscreen player at \(String(format: "%.1f", position))s")
            restoredPlayback = RestoredPlayback(context: request.context, position: position)
            return true
        }
        Self.pipClosedHandlerId = PipSession.shared.addClosedHandler { [self] in
            // Floating window closed while root owned the player: the session
            // reported the stop, so the row must reflect it right now.
            restoredPlayback = nil
            refreshResumeSoon()
        }
    }

    /// Forced resume-row refresh AFTER the stop POST has had time to land.
    /// Refreshing immediately (or relying on the 5s cooldown) let the row be
    /// fetched in its pre-stop state and then blocked the correction — the
    /// user then saw the episode as "progress lost".
    private func refreshResumeSoon() {
        guard let lib = libraryModel else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await lib.refreshResume(force: true)
        }
    }

    /// Defensive: a context without a stream URL would crash the restored
    /// player — the handler refuses the restore instead, but keep a value for
    /// the memberwise parameter so the call stays total.
    private func fallbackStreamURL(_ context: PipSession.Context) -> URL {
        context.serverURL.appendingPathComponent("Videos/\(context.itemId)/stream")
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private func mainContent(libModel: LibraryModel, server: JellyfinServer) -> some View {
        let token = KeychainStore().read(key: KeychainKey.accessToken) ?? ""
        let userId = authModel.currentUser?.id ?? ""
        let userName = authModel.currentUser?.name ?? ""

        if #available(iOS 18, *) {
            // Native TabView with Tab items — iOS 26 automatically applies Liquid Glass.
            // Same pattern used by Apple Music, App Store, WhatsApp, etc.
            let tabView = TabView(selection: $selectedTab) {
                Tab("Inicio", systemImage: "house.fill", value: MareaTab.home) {
                    HomeView(
                        libraryModel: libModel,
                        serverURL: server.baseURL,
                        token: token,
                        userId: userId,
                        userName: userName,
                        onLogout: { authModel.logout(); libraryModel = nil }
                    )
                }

                Tab("Buscar", systemImage: "magnifyingglass", value: MareaTab.search) {
                    SearchView(serverURL: server.baseURL, token: token, userId: userId)
                }

                Tab("Perfil", systemImage: "person.fill", value: MareaTab.profile) {
                    ProfileView(
                        userName: userName,
                        onLogout: { authModel.logout(); libraryModel = nil },
                        serverURL: server.baseURL,
                        token: token,
                        userId: userId
                    )
                }
            }

            if #available(iOS 26, *) {
                tabView.tint(.red).tabBarMinimizeBehavior(.onScrollDown)
            } else {
                tabView.tint(.red)
            }
        } else {
            // Legacy TabView for iOS 17
            TabView(selection: $selectedTab) {
                HomeView(
                    libraryModel: libModel,
                    serverURL: server.baseURL,
                    token: token,
                    userId: userId,
                    userName: userName,
                    onLogout: { authModel.logout(); libraryModel = nil }
                )
                .tabItem { Label("Inicio", systemImage: "house.fill") }
                .tag(MareaTab.home)

                SearchView(serverURL: server.baseURL, token: token, userId: userId)
                    .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
                    .tag(MareaTab.search)

                ProfileView(
                    userName: userName,
                    onLogout: { authModel.logout(); libraryModel = nil },
                    serverURL: server.baseURL,
                    token: token,
                    userId: userId
                )
                    .tabItem { Label("Perfil", systemImage: "person.fill") }
                    .tag(MareaTab.profile)
            }
            .tint(.red)
        }
    }
    #endif

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
        // Publish BEFORE loading: the view tree switches straight to Home (which
        // shows its own skeleton) instead of holding the whole screen hostage
        // until every row request finishes.
        libraryModel = libModel
        // Discovery reads the live library through the same reference, so its
        // TMDB matching sees rows as they land.
        discoveryModel = DiscoveryModel.live { [weak libModel] in
            libModel?.allItems ?? []
        }
        await libModel.load()
        // Rows landed: discovery can now seed recommendations from them.
        await discoveryModel?.loadRows()
    }

    // MARK: - Handoff resolution

    /// Called whenever a pending Handoff payload arrives OR the library finishes
    /// loading — whichever comes last.  Finds the item by ID in the already-loaded
    /// rows and pushes a navigation destination (iOS: NavigationLink value via
    /// a dedicated @State property; all platforms share the same logic path).
    private func resolveHandoffIfReady() {
        guard let payload = pendingHandoff,
              let lib = libraryModel else { return }

        // Find the item in the already-loaded library rows.
        let match = lib.allItems.first { $0.id == payload.itemId }

        // Clear the pending payload regardless of whether we found the item —
        // a second trigger (e.g. library reloaded) must not repeat the navigation.
        pendingHandoff = nil

        guard let item = match else {
            // Item not in the local library yet (e.g. library still loading).
            // Could try a direct API call here in a future iteration.
            return
        }

        // For iOS: switch to home tab and inject the item for NavigationLink.
        // The navigation is handled by the NavigationStack in HomeView, so we
        // store it in LibraryModel as a pending navigation target.
        lib.pendingNavigationItem = item
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
    private let keychain: any KeychainStoring

    init(
        probe: any JellyfinServerProbing = JellyfinServerProbe(),
        keychain: any KeychainStoring = KeychainStore()
    ) {
        self.probe = probe
        self.keychain = keychain
        // Restore server from Keychain if available
        if let urlString = keychain.read(key: KeychainKey.serverURL),
           let url = URL(string: urlString) {
            server = JellyfinServer(baseURL: url, name: url.host ?? "Server")
        }
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
                Text("THISJELLYFIX")
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
