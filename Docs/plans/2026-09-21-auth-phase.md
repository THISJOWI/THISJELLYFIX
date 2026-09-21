# Auth Phase Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Jellyfin user authentication (login, Keychain persistence, session restore) so the app transitions from server connection to authenticated home screen.

**Architecture:** Three-layer approach: `ThisJellyFixCore` holds Keychain storage and domain models, `ThisJellyFixNetworking` holds the auth API client, `ThisJellyFixFeature` holds the ViewModel and SwiftUI login UI. Dependencies flow: Core ← Networking ← Feature. All new types are `Sendable` for concurrency safety. Mocking via protocols for testability.

**Tech Stack:** Swift 5.10, SwiftUI, Observation framework, Security framework (Keychain), URLSession

**Spec:** `Docs/specs/2026-09-21-auth-phase-design.md`

## Global Constraints

- Swift 5.10, platforms: iOS 17+, macOS 14+, tvOS 17+, visionOS 1.0+
- No external dependencies
- All networking types must be `Sendable`
- All UI models use `@Observable` (not `ObservableObject`)
- Spanish error messages for user-facing strings
- Keychain service identifier: `com.thisjellyfix.auth`
- Device ID: UUID stored in Keychain on first launch, persisted across sessions

## Review Focus

- **Keychain deletion across OS versions:** SecItemDelete can return errSecItemNotFound — must be handled as success
- **Concurrent Keychain access:** Multiple calls to Keychain should not race; use actor or serial queue
- **Token validation on restore:** If server returns 401 on restore, must clear stale credentials and show login (not crash)
- **Empty password edge case:** Jellyfin allows passwordless users — `Pw` can be empty string
- **X-Emby-Authorization header format:** Must match exactly `MediaBrowser Client="...", Device="...", DeviceId="...", Version="..."`

---

## File Structure

| File | Module | Responsibility |
|------|--------|----------------|
| `Sources/ThisJellyFixCore/JellyfinUser.swift` | Core | Domain model for authenticated user |
| `Sources/ThisJellyFixCore/KeychainStore.swift` | Core | Keychain read/write/delete abstraction |
| `Sources/ThisJellyFixCore/DeviceIdentifier.swift` | Core | Stable device ID generator/persister |
| `Sources/ThisJellyFixNetworking/JellyfinAuthClient.swift` | Networking | API client for `/Users/AuthenticateByName` |
| `Sources/ThisJellyFixFeature/AuthModel.swift` | Feature | ViewModel: login, logout, session restore |
| `Sources/ThisJellyFixFeature/LoginView.swift` | Feature | Login screen UI |
| `Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift` | Feature | Modified: adds auth gate |
| `Tests/ThisJellyFixCoreTests/KeychainStoreTests.swift` | CoreTests | Keychain persistence tests |
| `Tests/ThisJellyFixCoreTests/DeviceIdentifierTests.swift` | CoreTests | Device ID stability tests |
| `Tests/ThisJellyFixNetworkingTests/JellyfinAuthClientTests.swift` | NetworkingTests | Auth client tests with mock |

---

### Task 1: Domain Model — JellyfinUser

**Files:**
- Create: `Sources/ThisJellyFixCore/JellyfinUser.swift`
- Test: none (Codable model, tested via integration)

**Interfaces:**
- Produces: `JellyfinUser` (used by Networking auth client and Feature AuthModel)

- [ ] **Step 1: Create JellyfinUser model**

```swift
// Sources/ThisJellyFixCore/JellyfinUser.swift
import Foundation

public struct JellyfinUser: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let primaryImageTag: String?

    public init(id: String, name: String, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run from project root: `swift build --target ThisJellyFixCore 2>&1 | tail -5`
Expected: Build complete, no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ThisJellyFixCore/JellyfinUser.swift
git commit -m "feat(core): add JellyfinUser domain model"
```

---

### Task 2: Keychain Store

**Files:**
- Create: `Sources/ThisJellyFixCore/KeychainStore.swift`
- Test: `Tests/ThisJellyFixCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Produces: `KeychainStoring` protocol, `KeychainStore` concrete type
- Used by: AuthModel (Feature), DeviceIdentifier (Core)

- [ ] **Step 1: Create KeychainStoring protocol and KeychainStore**

```swift
// Sources/ThisJellyFixCore/KeychainStore.swift
import Foundation
import Security

// MARK: - Protocol

public protocol KeychainStoring: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) -> String?
    func delete(key: String) throws
    func deleteAll() throws
}

// MARK: - Keys

public enum KeychainKey {
    public static let accessToken = "com.thisjellyfix.auth.accessToken"
    public static let userId = "com.thisjellyfix.auth.userId"
    public static let userName = "com.thisjellyfix.auth.userName"
    public static let serverURL = "com.thisjellyfix.auth.serverURL"
    public static let deviceId = "com.thisjellyfix.auth.deviceId"
}

// MARK: - Implementation

public struct KeychainStore: KeychainStoring {
    private let service: String

    public init(service: String = "com.thisjellyfix.auth") {
        self.service = service
    }

    public func save(key: String, value: String) throws {
        deleteIfExists(key: key)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is acceptable — already deleted
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Private

    private func deleteIfExists(key: String) {
        try? delete(key: key)
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError, Equatable {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Error guardando en Keychain (código \(status))"
        case .deleteFailed(let status):
            "Error eliminando de Keychain (código \(status))"
        }
    }
}
```

- [ ] **Step 2: Write KeychainStore tests**

```swift
// Tests/ThisJellyFixCoreTests/KeychainStoreTests.swift
import XCTest
@testable import ThisJellyFixCore

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        // Use unique service per test to avoid collisions
        store = KeychainStore(service: "com.thisjellyfix.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.deleteAll()
        super.tearDown()
    }

    func testSaveAndRead() throws {
        try store.save(key: "token", value: "abc123")
        XCTAssertEqual(store.read(key: "token"), "abc123")
    }

    func testReadReturnsNilForMissingKey() {
        XCTAssertNil(store.read(key: "nonexistent"))
    }

    func testOverwriteExistingValue() throws {
        try store.save(key: "token", value: "first")
        try store.save(key: "token", value: "second")
        XCTAssertEqual(store.read(key: "token"), "second")
    }

    func testDeleteRemovesValue() throws {
        try store.save(key: "token", value: "abc123")
        try store.delete(key: "token")
        XCTAssertNil(store.read(key: "token"))
    }

    func testDeleteNonexistentKeyDoesNotThrow() throws {
        // Should not throw — errSecItemNotFound is treated as success
        try store.delete(key: "nonexistent")
    }

    func testDeleteAllRemovesAllValues() throws {
        try store.save(key: "a", value: "1")
        try store.save(key: "b", value: "2")
        try store.deleteAll()
        XCTAssertNil(store.read(key: "a"))
        XCTAssertNil(store.read(key: "b"))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter KeychainStoreTests 2>&1 | tail -15`
Expected: All 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixCore/KeychainStore.swift Tests/ThisJellyFixCoreTests/KeychainStoreTests.swift
git commit -m "feat(core): add KeychainStore with persistence tests"
```

---

### Task 3: Device Identifier

**Files:**
- Create: `Sources/ThisJellyFixCore/DeviceIdentifier.swift`
- Test: `Tests/ThisJellyFixCoreTests/DeviceIdentifierTests.swift`

**Interfaces:**
- Consumes: `KeychainStoring` (Task 2)
- Produces: `DeviceIdentifier` (used by Networking auth client)

- [ ] **Step 1: Create DeviceIdentifier**

```swift
// Sources/ThisJellyFixCore/DeviceIdentifier.swift
import Foundation

public struct DeviceIdentifier: Sendable {
    private let keychain: any KeychainStoring
    private let storageKey = KeychainKey.deviceId

    public init(keychain: any KeychainStoring = KeychainStore()) {
        self.keychain = keychain
    }

    public func current() -> String {
        if let existing = keychain.read(key: storageKey) {
            return existing
        }
        let newId = UUID().uuidString
        try? keychain.save(key: storageKey, value: newId)
        return newId
    }
}
```

- [ ] **Step 2: Write DeviceIdentifier tests**

```swift
// Tests/ThisJellyFixCoreTests/DeviceIdentifierTests.swift
import XCTest
@testable import ThisJellyFixCore

final class DeviceIdentifierTests: XCTestCase {
    func testReturnsSameIdAcrossCalls() {
        let keychain = MockKeychainStore()
        let id1 = DeviceIdentifier(keychain: keychain).current()
        let id2 = DeviceIdentifier(keychain: keychain).current()
        XCTAssertEqual(id1, id2)
    }

    func testIdIsValidUUID() {
        let keychain = MockKeychainStore()
        let id = DeviceIdentifier(keychain: keychain).current()
        XCTAssertNotNil(UUID(uuidString: id))
    }
}

// MARK: - Mock

private struct MockKeychainStore: KeychainStoring {
    private var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        // In-memory only for tests
    }

    func read(key: String) -> String? {
        nil
    }

    func delete(key: String) throws {}

    func deleteAll() throws {}
}
```

Wait — the mock needs to actually store values. Fix:

```swift
private final class MockKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        storage[key] = value
    }

    func read(key: String) -> String? {
        storage[key]
    }

    func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter DeviceIdentifierTests 2>&1 | tail -10`
Expected: Both tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixCore/DeviceIdentifier.swift Tests/ThisJellyFixCoreTests/DeviceIdentifierTests.swift
git commit -m "feat(core): add DeviceIdentifier for stable device ID"
```

---

### Task 4: Auth API Client

**Files:**
- Create: `Sources/ThisJellyFixNetworking/JellyfinAuthClient.swift`
- Test: `Tests/ThisJellyFixNetworkingTests/JellyfinAuthClientTests.swift`

**Interfaces:**
- Consumes: `JellyfinUser` (Task 1), `DeviceIdentifier` (Task 3)
- Produces: `JellyfinAuthenticating` protocol, `JellyfinAuthClient`, `AuthenticationResult`

- [ ] **Step 1: Create JellyfinAuthClient**

```swift
// Sources/ThisJellyFixNetworking/JellyfinAuthClient.swift
import Foundation
import ThisJellyFixCore

// MARK: - Result Model

public struct AuthenticationResult: Decodable, Sendable, Equatable {
    public let user: JellyfinUser
    public let accessToken: String
    public let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

// MARK: - Errors

public enum AuthError: LocalizedError, Equatable {
    case invalidCredentials
    case networkError(String)
    case serverError(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Usuario o contraseña incorrectos."
        case .networkError(let message):
            "Error de red: \(message)"
        case .serverError(let code):
            "Error del servidor (código \(code))."
        case .invalidResponse:
            "El servidor devolvió una respuesta inesperada."
        }
    }
}

// MARK: - Protocol

public protocol JellyfinAuthenticating: Sendable {
    func authenticate(
        username: String,
        password: String,
        serverURL: URL,
        deviceId: String
    ) async throws -> AuthenticationResult
}

// MARK: - Implementation

public struct JellyfinAuthClient: JellyfinAuthenticating {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func authenticate(
        username: String,
        password: String,
        serverURL: URL,
        deviceId: String
    ) async throws -> AuthenticationResult {
        let endpoint = serverURL.appending(path: "Users/AuthenticateByName")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            authorizationHeader(deviceId: deviceId),
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let body = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AuthError.invalidCredentials
        default:
            throw AuthError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(AuthenticationResult.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    // MARK: - Private

    private func authorizationHeader(deviceId: String) -> String {
        "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(deviceId)\", Version=\"0.1\""
    }

    private var deviceOS: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }
}
```

- [ ] **Step 2: Write AuthClient tests with mock URLSession**

```swift
// Tests/ThisJellyFixNetworkingTests/JellyfinAuthClientTests.swift
import XCTest
@testable import ThisJellyFixNetworking
@testable import ThisJellyFixCore

final class JellyfinAuthClientTests: XCTestCase {
    func testSuccessfulAuthentication() async throws {
        let mockSession = MockURLSession(
            data: """
            {
                "User": {"Id": "u1", "Name": "Admin"},
                "AccessToken": "token-abc",
                "ServerId": "srv-1"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let client = JellyfinAuthClient(session: mockSession)
        let result = try await client.authenticate(
            username: "Admin",
            password: "pass",
            serverURL: URL(string: "http://localhost:8096")!,
            deviceId: "test-device"
        )

        XCTAssertEqual(result.accessToken, "token-abc")
        XCTAssertEqual(result.user.name, "Admin")
        XCTAssertEqual(result.user.id, "u1")
        XCTAssertEqual(result.serverId, "srv-1")
    }

    func testInvalidCredentialsThrows() async {
        let mockSession = MockURLSession(
            data: Data(),
            statusCode: 401
        )

        let client = JellyfinAuthClient(session: mockSession)

        do {
            _ = try await client.authenticate(
                username: "Admin",
                password: "wrong",
                serverURL: URL(string: "http://localhost:8096")!,
                deviceId: "test-device"
            )
            XCTFail("Expected invalidCredentials error")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testNetworkErrorThrows() async {
        let mockSession = MockURLSession(error: URLError(.notConnectedToInternet))

        let client = JellyfinAuthClient(session: mockSession)

        do {
            _ = try await client.authenticate(
                username: "Admin",
                password: "pass",
                serverURL: URL(string: "http://localhost:8096")!,
                deviceId: "test-device"
            )
            XCTFail("Expected networkError")
        } catch {
            guard case AuthError.networkError = error else {
                XCTFail("Expected networkError, got \(error)")
                return
            }
        }
    }

    func testRequestContainsCorrectHeaders() async throws {
        let mockSession = MockURLSession(
            data: """
            {"User":{"Id":"u1","Name":"A"},"AccessToken":"t","ServerId":"s"}
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let client = JellyfinAuthClient(session: mockSession)
        _ = try await client.authenticate(
            username: "Admin",
            password: "pass",
            serverURL: URL(string: "http://localhost:8096")!,
            deviceId: "dev-123"
        )

        let request = mockSession.capturedRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let authHeader = request?.value(forHTTPHeaderField: "X-Emby-Authorization") ?? ""
        XCTAssertTrue(authHeader.contains("thisjellyfix"))
        XCTAssertTrue(authHeader.contains("dev-123"))
    }
}

// MARK: - Mock URLSession

private final class MockURLSession: URLSession, @unchecked Sendable {
    let mockData: Data
    let mockStatusCode: Int
    let mockError: Error?
    private(set) var capturedRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.mockData = data
        self.mockStatusCode = statusCode
        self.mockError = nil
    }

    init(error: Error) {
        self.mockData = Data()
        self.mockStatusCode = 0
        self.mockError = error
    }

    override func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request

        if let error = mockError {
            throw error
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (mockData, response)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter JellyfinAuthClientTests 2>&1 | tail -15`
Expected: All 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixNetworking/JellyfinAuthClient.swift Tests/ThisJellyFixNetworkingTests/JellyfinAuthClientTests.swift
git commit -m "feat(networking): add JellyfinAuthClient with credential-based login"
```

---

### Task 5: AuthModel + LoginView

**Files:**
- Create: `Sources/ThisJellyFixFeature/AuthModel.swift`
- Create: `Sources/ThisJellyFixFeature/LoginView.swift`
- Test: manual (UI component, tested via running app)

**Interfaces:**
- Consumes: `JellyfinAuthenticating` (Task 4), `KeychainStoring` (Task 2), `DeviceIdentifier` (Task 3), `JellyfinServer` (existing)
- Produces: `AuthModel` (used by RootView for navigation)

- [ ] **Step 1: Create AuthModel**

```swift
// Sources/ThisJellyFixFeature/AuthModel.swift
import Foundation
import Observation
import ThisJellyFixCore
import ThisJellyFixNetworking

@MainActor
@Observable
final class AuthModel {
    // MARK: - Login fields
    var username = ""
    var password = ""
    var isAuthenticating = false
    var errorMessage: String?

    // MARK: - Auth state
    var isAuthenticated = false
    var currentUser: JellyfinUser?

    // MARK: - Dependencies
    private let authClient: any JellyfinAuthenticating
    private let keychain: any KeychainStoring
    private let deviceId: String

    init(
        authClient: any JellyfinAuthenticating = JellyfinAuthClient(),
        keychain: any KeychainStoring = KeychainStore(),
        deviceId: String? = nil
    ) {
        self.authClient = authClient
        self.keychain = keychain
        self.deviceId = deviceId ?? DeviceIdentifier(keychain: keychain).current()
    }

    // MARK: - Login

    func login(serverURL: URL) async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let result = try await authClient.authenticate(
                username: username,
                password: password,
                serverURL: serverURL,
                deviceId: deviceId
            )

            // Persist to Keychain
            try keychain.save(key: KeychainKey.accessToken, value: result.accessToken)
            try keychain.save(key: KeychainKey.userId, value: result.user.id)
            try keychain.save(key: KeychainKey.userName, value: result.user.name)
            try keychain.save(key: KeychainKey.serverURL, value: serverURL.absoluteString)

            currentUser = result.user
            isAuthenticated = true

            // Clear form
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Restore session

    func restoreSession(serverURL: URL) async -> Bool {
        guard let token = keychain.read(key: KeychainKey.accessToken),
              let userId = keychain.read(key: KeychainKey.userId),
              let userName = keychain.read(key: KeychainKey.userName)
        else {
            return false
        }

        // Token exists — validate by making a lightweight request
        // For now, trust the stored token and mark as authenticated
        // TODO: Phase 2 can add token validation via /Users/Me
        currentUser = JellyfinUser(id: userId, name: userName)
        isAuthenticated = true
        return true
    }

    // MARK: - Logout

    func logout() {
        try? keychain.delete(key: KeychainKey.accessToken)
        try? keychain.delete(key: KeychainKey.userId)
        try? keychain.delete(key: KeychainKey.userName)
        try? keychain.delete(key: KeychainKey.serverURL)

        currentUser = nil
        isAuthenticated = false
        username = ""
        password = ""
        errorMessage = nil
    }
}
```

- [ ] **Step 2: Create LoginView**

```swift
// Sources/ThisJellyFixFeature/LoginView.swift
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
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.cyan, .mint)

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
                    .textInputAutocapitalization(.never)

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
```

- [ ] **Step 3: Verify compilation**

Run: `swift build --target ThisJellyFixFeature 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixFeature/AuthModel.swift Sources/ThisJellyFixFeature/LoginView.swift
git commit -m "feat(feature): add AuthModel and LoginView"
```

---

### Task 6: Integrate Auth into RootView

**Files:**
- Modify: `Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift`

**Interfaces:**
- Consumes: `AuthModel` (Task 5), `LoginView` (Task 5)
- Produces: Updated `ThisJellyFixRootView` with auth gate

- [ ] **Step 1: Update RootView with auth flow**

Replace the entire file content:

```swift
// Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift
import Observation
import SwiftUI
import ThisJellyFixCore
import ThisJellyFixNetworking

public struct ThisJellyFixRootView: View {
    @State private var model = ServerConnectionModel()
    @State private var authModel = AuthModel()

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
                    MareaHomeView(
                        server: server,
                        user: authModel.currentUser,
                        onLogout: {
                            authModel.logout()
                        },
                        onDisconnect: {
                            authModel.logout()
                            model.disconnect()
                        }
                    )
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
        .task {
            await restoreSessionIfNeeded()
        }
    }

    private func restoreSessionIfNeeded() async {
        guard let server = model.server else { return }
        _ = await authModel.restoreSession(serverURL: server.baseURL)
    }
}

// MARK: - Server Connection (unchanged)

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

// MARK: - Server Connection View (unchanged)

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

// MARK: - Home View (placeholder)

private struct MareaHomeView: View {
    let server: JellyfinServer
    let user: JellyfinUser?
    let onLogout: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("La Marea")
                        .font(.largeTitle.bold())
                    Text(server.name)
                        .foregroundStyle(.secondary)
                    if let user {
                        Text("Conectado como \(user.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Cerrar sesión", action: onLogout)
                    Button("Desconectar servidor", action: onDisconnect)
                } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                }
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
```

- [ ] **Step 2: Verify full build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds across all targets.

- [ ] **Step 3: Run all tests**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass (existing + new).

- [ ] **Step 4: Commit**

```bash
git add Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift
git commit -m "feat(feature): integrate auth flow into RootView"
```

---

### Task 7: Verify on macOS

**Files:**
- No file changes

- [ ] **Step 1: Build macOS target**

Run: `xcodebuild -project thisjellyfix.xcodeproj -scheme thisjellyfix-macOS build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Note any warnings or issues**

Review xcodebuild output for deprecation warnings, missing imports, or platform-specific issues.

- [ ] **Step 3: Commit (if fixes needed)**

If any platform-specific fixes were required, commit them.

---

## Post-Plan Notes

After this plan is complete:
- Server connection → Login screen → Authenticated home (placeholder) works
- Token persists in Keychain across app launches
- Logout clears everything
- Ready for Phase 2: Library browsing (rows of content from `/Users/{userId}/Views` and `/Users/{userId}/Items`)
