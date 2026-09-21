# Library Phase Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Implement Netflix-style home screen with 5 content rows from Jellyfin library.

**Architecture:** JellyfinLibraryClient fetches views/items from API, LibraryModel manages state, HomeView renders rows of MediaCardViews with async image loading.

**Tech Stack:** Swift 5.10, SwiftUI, Observation, URLSession, AsyncImage

**Spec:** `Docs/specs/2026-09-21-library-phase-design.md`

## Global Constraints

- Swift 5.10, iOS 17+, macOS 14+, tvOS 17+, visionOS 1.0+
- No external dependencies
- All networking types `Sendable`
- All UI models `@Observable`
- Spanish UI strings
- Auth token passed via `MediaBrowser Token` header

## Review Focus

- **Image loading failures:** Must show placeholder, not crash
- **Empty library:** Show friendly message, not blank screen
- **Token expiry mid-session:** 401 from library endpoints must trigger re-login
- **Large image payloads:** Use maxWidth parameter to limit bandwidth
- **Concurrent row loading:** Multiple rows load simultaneously — no races

---

### Task 1: MediaItem + LibraryView Models

**Files:**
- Create: `Sources/ThisJellyFixCore/JellyfinMediaItem.swift`

- [ ] **Step 1: Create models**

```swift
// Sources/ThisJellyFixCore/JellyfinMediaItem.swift
import Foundation

public struct JellyfinMediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let overview: String?
    public let seriesName: String?
    public let year: Int?
    public let imageTags: [String: String]?
    public let officialRating: String?
    public let communityRating: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case seriesName = "SeriesName"
        case year = "Year"
        case imageTags = "ImageTags"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
    }

    public var hasImage: Bool {
        imageTags?["Primary"] != nil
    }

    public var imageURL: URL? {
        // Constructed at call site with serverURL
        nil
    }
}

public struct LibraryView: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }
}

// Wrapper for API responses
struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinMediaItem]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinViewsResponse: Decodable {
    let items: [LibraryView]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `swift build --target ThisJellyFixCore 2>&1 | tail -3`

- [ ] **Step 3: Commit**

```bash
git add Sources/ThisJellyFixCore/JellyfinMediaItem.swift
git commit -m "feat(core): add JellyfinMediaItem and LibraryView models"
```

---

### Task 2: Library API Client

**Files:**
- Create: `Sources/ThisJellyFixNetworking/JellyfinLibraryClient.swift`
- Test: `Tests/ThisJellyFixNetworkingTests/JellyfinLibraryClientTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/ThisJellyFixNetworkingTests/JellyfinLibraryClientTests.swift
import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class JellyfinLibraryClientTests: XCTestCase {
    func testFetchViews() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[{"Id":"v1","Name":"Movies","CollectionType":"movies"},{"Id":"v2","Name":"TV Shows","CollectionType":"tvshows"}]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        let views = try await client.fetchViews(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "tok"
        )

        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(views[0].name, "Movies")
    }

    func testFetchItems() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[{"Id":"m1","Name":"Inception","Type":"Movie","Year":2010}]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        let items = try await client.fetchItems(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "tok",
            parentId: "v1",
            includeTypes: "Movie",
            limit: 20,
            orderBy: "DateCreated",
            filters: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Inception")
    }

    func testAuthHeaderContainsToken() async throws {
        let session = MockNetworkSession(data: """
        {"Items":[]}
        """.data(using: .utf8)!, statusCode: 200)

        let client = JellyfinLibraryClient(session: session)
        _ = try await client.fetchViews(
            userId: "u1",
            serverURL: URL(string: "http://localhost:8096")!,
            token: "mytoken"
        )

        let request = session.capturedRequest
        let auth = request?.value(forHTTPHeaderField: "MediaBrowser") ?? ""
        XCTAssertTrue(auth.contains("Token=mytoken"))
    }
}
```

- [ ] **Step 2: Run tests — verify RED**

Run: `swift test --filter JellyfinLibraryClientTests 2>&1 | grep "error:" | head -3`
Expected: cannot find type errors

- [ ] **Step 3: Implement JellyfinLibraryClient**

```swift
// Sources/ThisJellyFixNetworking/JellyfinLibraryClient.swift
import Foundation
import ThisJellyFixCore

public protocol JellyfinLibraryProviding: Sendable {
    func fetchViews(userId: String, serverURL: URL, token: String) async throws -> [LibraryView]
    func fetchItems(userId: String, serverURL: URL, token: String, parentId: String?, includeTypes: String?, limit: Int, orderBy: String, filters: String?) async throws -> [JellyfinMediaItem]
}

public struct JellyfinLibraryClient: JellyfinLibraryProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func fetchViews(userId: String, serverURL: URL, token: String) async throws -> [LibraryView] {
        let url = serverURL.appending(path: "Users/\(userId)/Views")
        let data = try await fetchData(from: url, token: token)
        let response = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
        return response.items
    }

    public func fetchItems(
        userId: String,
        serverURL: URL,
        token: String,
        parentId: String?,
        includeTypes: String?,
        limit: Int,
        orderBy: String,
        filters: String?
    ) async throws -> [JellyfinMediaItem] {
        var components = URLComponents(
            url: serverURL.appending(path: "Users/\(userId)/Items"),
            resolvingAgainstBaseURL: false
        )!

        var queryItems = [
            URLQueryItem(name: "OrderBy", value: orderBy),
            URLQueryItem(name: "Descending", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]

        if let parentId {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        if let includeTypes {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes))
        }
        if let filters {
            queryItems.append(URLQueryItem(name: "Filters", value: filters))
        }

        components.queryItems = queryItems

        let data = try await fetchData(from: components.url!, token: token)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }

    // MARK: - Private

    private func fetchData(from url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\", Version=\"0.1\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "MediaBrowser")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        return data
    }

    private var deviceOS: String {
        #if os(macOS) "macOS"
        #elseif os(iOS) "iOS"
        #elseif os(tvOS) "tvOS"
        #elseif os(visionOS) "visionOS"
        #else "unknown"
        #endif
    }
}

public enum LibraryError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Respuesta inválida del servidor."
        case .unauthorized: "Sesión expirada. Inicia sesión de nuevo."
        case .serverError(let code): "Error del servidor (código \(code))."
        }
    }
}
```

- [ ] **Step 4: Run tests — verify GREEN**

Run: `swift test --filter JellyfinLibraryClientTests 2>&1 | grep -E "(passed|failed|Executed)"`

- [ ] **Step 5: Commit**

```bash
git add Sources/ThisJellyFixNetworking/JellyfinLibraryClient.swift Tests/ThisJellyFixNetworkingTests/JellyfinLibraryClientTests.swift
git commit -m "feat(networking): add JellyfinLibraryClient for views and items"
```

---

### Task 3: LibraryModel

**Files:**
- Create: `Sources/ThisJellyFixFeature/LibraryModel.swift`

- [ ] **Step 1: Create LibraryModel**

```swift
// Sources/ThisJellyFixFeature/LibraryModel.swift
import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking

struct ContentRow: Identifiable {
    let id = UUID()
    let title: String
    let items: [JellyfinMediaItem]
}

@MainActor
@Observable
final class LibraryModel {
    var rows: [ContentRow] = []
    var isLoading = false
    var errorMessage: String?

    private let libraryClient: any JellyfinLibraryProviding
    private let serverURL: URL
    private let userId: String
    private let token: String

    init(
        libraryClient: any JellyfinLibraryProviding = JellyfinLibraryClient(),
        serverURL: URL,
        userId: String,
        token: String
    ) {
        self.libraryClient = libraryClient
        self.serverURL = serverURL
        self.userId = userId
        self.token = token
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Fetch all views first
            let views = try await libraryClient.fetchViews(
                userId: userId,
                serverURL: serverURL,
                token: token
            )

            var allRows: [ContentRow] = []

            // 1. Recently added (all libraries combined)
            let recentItems = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: nil
            )
            if !recentItems.isEmpty {
                allRows.append(ContentRow(title: "Últimos agregados", items: recentItems))
            }

            // 2. Movies
            if let moviesView = views.first(where: { $0.collectionType == "movies" }) {
                let movies = try await libraryClient.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: moviesView.id, includeTypes: "Movie",
                    limit: 20, orderBy: "DateCreated", filters: nil
                )
                if !movies.isEmpty {
                    allRows.append(ContentRow(title: "Películas", items: movies))
                }
            }

            // 3. Series
            if let seriesView = views.first(where: { $0.collectionType == "tvshows" }) {
                let series = try await libraryClient.fetchItems(
                    userId: userId, serverURL: serverURL, token: token,
                    parentId: seriesView.id, includeTypes: "Series",
                    limit: 20, orderBy: "DateCreated", filters: nil
                )
                if !series.isEmpty {
                    allRows.append(ContentRow(title: "Series", items: series))
                }
            }

            // 4. Favorites
            let favorites = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: "IsFavorite"
            )
            if !favorites.isEmpty {
                allRows.append(ContentRow(title: "Favoritos", items: favorites))
            }

            // 5. Recently played
            let played = try await libraryClient.fetchItems(
                userId: userId, serverURL: serverURL, token: token,
                parentId: nil, includeTypes: "Movie,Series",
                limit: 20, orderBy: "DateCreated", filters: "IsPlayed"
            )
            if !played.isEmpty {
                allRows.append(ContentRow(title: "Visto recientemente", items: played))
            }

            rows = allRows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for item: JellyfinMediaItem) -> URL? {
        guard item.hasImage else { return nil }
        return serverURL
            .appending(path: "Items/\(item.id)/Images/Primary")
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: "300"),
                URLQueryItem(name: "quality", value: "90"),
            ])
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `swift build --target ThisJellyFixFeature 2>&1 | tail -3`

- [ ] **Step 3: Commit**

```bash
git add Sources/ThisJellyFixFeature/LibraryModel.swift
git commit -m "feat(feature): add LibraryModel for home content rows"
```

---

### Task 4: MediaCardView + ImageView

**Files:**
- Create: `Sources/ThisJellyFixFeature/MediaCardView.swift`
- Create: `Sources/ThisJellyFixFeature/ImageView.swift`

- [ ] **Step 1: Create ImageView**

```swift
// Sources/ThisJellyFixFeature/ImageView.swift
import SwiftUI

struct MareaImageView: View {
    let url: URL?
    let placeholder: String
    let width: CGFloat
    let height: CGFloat

    init(url: URL?, placeholder: String = "?", width: CGFloat = 150, height: CGFloat = 220) {
        self.url = url
        self.placeholder = placeholder
        self.width = width
        self.height = height
    }

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderView
                case .empty:
                    ProgressView()
                        .frame(width: width, height: height)
                @unknown default:
                    placeholderView
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color(red: 0.12, green: 0.14, blue: 0.22)
            Text(placeholder)
                .font(.title2.bold())
                .foregroundStyle(.cyan.opacity(0.6))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Create MediaCardView**

```swift
// Sources/ThisJellyFixFeature/MediaCardView.swift
import SwiftUI
import ThisJellyFixCore

struct MediaCardView: View {
    let item: JellyfinMediaItem
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MareaImageView(
                url: imageURL,
                placeholder: String(item.name.prefix(1)),
                width: 150,
                height: 220
            )

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)

            if let year = item.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Verify compilation**

Run: `swift build --target ThisJellyFixFeature 2>&1 | tail -3`

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixFeature/MediaCardView.swift Sources/ThisJellyFixFeature/ImageView.swift
git commit -m "feat(feature): add MediaCardView and MareaImageView"
```

---

### Task 5: HomeView + Integrate in RootView

**Files:**
- Create: `Sources/ThisJellyFixFeature/HomeView.swift`
- Modify: `Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift`

- [ ] **Step 1: Create HomeView**

```swift
// Sources/ThisJellyFixFeature/HomeView.swift
import SwiftUI
import ThisJellyFixCore

struct HomeView: View {
    let libraryModel: LibraryModel
    let userName: String
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("La Marea")
                            .font(.largeTitle.bold())
                        Text("Hola, \(userName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onLogout()
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                    }
                }
                .padding(.horizontal, 32)

                if libraryModel.isLoading && libraryModel.rows.isEmpty {
                    ProgressView("Cargando biblioteca…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = libraryModel.errorMessage, libraryModel.rows.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                        Button("Reintentar") {
                            Task { await libraryModel.load() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    // Content rows
                    ForEach(libraryModel.rows) { row in
                        ContentRowView(row: row, libraryModel: libraryModel)
                    }
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct ContentRowView: View {
    let row: ContentRow
    let libraryModel: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title)
                .font(.title3.bold())
                .padding(.horizontal, 32)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(row.items) { item in
                        MediaCardView(
                            item: item,
                            imageURL: libraryModel.imageURL(for: item)
                        )
                    }
                }
                .padding(.horizontal, 32)
            }
        }
    }
}
```

- [ ] **Step 2: Update RootView to use HomeView**

Replace `MareaHomeView` with `HomeView` in `ThisJellyFixRootView.swift`. The RootView needs to:
1. Pass auth info (userId, token) to LibraryModel
2. Show HomeView when authenticated
3. Handle logout → disconnect

Update the authenticated branch:

```swift
if authModel.isAuthenticated {
    HomeView(
        libraryModel: LibraryModel(
            serverURL: server.baseURL,
            userId: authModel.currentUser?.id ?? "",
            token: keychain.read(key: KeychainKey.accessToken) ?? ""
        ),
        userName: authModel.currentUser?.name ?? "",
        onLogout: {
            authModel.logout()
        }
    )
    .task {
        await libraryModel.load()
    }
}
```

Wait — the LibraryModel needs to be created as a `@State` in the view. Let me restructure:

```swift
// In ThisJellyFixRootView
@State private var libraryModel: LibraryModel?

// When authenticated, create and task-load it
if let server = model.server, authModel.isAuthenticated {
    if let model = libraryModel {
        HomeView(libraryModel: model, userName: authModel.currentUser?.name ?? "", onLogout: { ... })
    } else {
        ProgressView()
            .task {
                libraryModel = LibraryModel(
                    serverURL: server.baseURL,
                    userId: authModel.currentUser?.id ?? "",
                    token: keychainStore.read(key: KeychainKey.accessToken) ?? ""
                )
                await libraryModel?.load()
            }
    }
}
```

This is getting complex. Simpler: pass the token from AuthModel directly.

- [ ] **Step 3: Implement the full RootView update**

- [ ] **Step 4: Verify full build**

Run: `swift build 2>&1 | tail -3`

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | grep -E "(Executed|failed)" | tail -3`

- [ ] **Step 6: Commit**

```bash
git add Sources/ThisJellyFixFeature/HomeView.swift Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift
git commit -m "feat(feature): add HomeView and integrate library into RootView"
```

---

### Task 6: Regenerate xcodeproj + Verify macOS

- [ ] **Step 1: Run xcodegen**

Run: `xcodegen generate 2>&1`

- [ ] **Step 2: Build macOS**

Run: `xcodebuild -project thisjellyfix.xcodeproj -scheme thisjellyfix-macOS build 2>&1 | tail -3`

- [ ] **Step 3: Commit if needed**

```bash
git add thisjellyfix.xcodeproj
git commit -m "chore: regenerate xcodeproj for library phase"
```
