# Spec: Fase 1 — Sistema de Autenticación

**Fecha:** 2026-09-21
**Estado:** Aprobado
**Alcance:** Login de usuario Jellyfin, persistencia de sesión en Keychain, UI de login

---

## Objetivo

Implementar autenticación completa contra un servidor Jellyfin: login con usuario y contraseña, persistencia de token en Keychain, y restauración automática de sesión al iniciar la app. La fase deja la app lista para pasar de la pantalla de login a la pantalla principal (Home), que se implementa en la fase siguiente.

## Contexto actual

- La app conecta a un servidor Jellyfin y muestra "Servidor encontrado"
- No hay login, no hay Keychain, no hay persistencia
- `ServerConnectionModel` maneja la conexión y guarda `JellyfinServer` en memoria
- Al cerrar la app se pierde la conexión

## Decisiones de diseño

### API Jellyfin

Se usa el endpoint estándar:

```
POST /Users/AuthenticateByName
Headers:
  X-Emby-Authorization: MediaBrowser Client="thisjellyfix", Device="macOS", DeviceId="...", Version="0.1"
  Content-Type: application/json
Body:
  { "Username": "usuario", "Pw": "contraseña" }
```

Respuesta exitosa (200):
```json
{
  "User": {
    "Id": "user-id",
    "Name": "Nombre",
    "PrimaryImageTag": "..."
  },
  "AccessToken": "token-largo",
  "ServerId": "server-id"
}
```

### Keychain Store

- Almacena: `accessToken`, `userId`, `serverURL`, `userName`
- Usa `SecItemAdd`/`SecItemUpdate`/`SecItemDelete`/`SecItemCopyMatching`
- Protocol `KeychainStoring` para inyección de dependencias y testeo
- Identificador de servicio: `com.thisjellyfix.auth`
- Singleton con acceso estático, pero inyectable

### Modelos

```swift
// En ThisJellyFixCore
public struct JellyfinUser: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let primaryImageTag: String?
}

// En ThisJellyFixNetworking
public struct AuthenticationResult: Decodable, Sendable {
    public let user: JellyfinUser
    public let accessToken: String
    public let serverId: String
}
```

### Auth Client

```swift
// En ThisJellyFixNetworking
public protocol JellyfinAuthenticating: Sendable {
    func authenticate(
        username: String,
        password: String,
        serverURL: URL,
        deviceId: String
    ) async throws -> AuthenticationResult
}
```

- Implementación concreta: `JellyfinAuthClient`
- Header `X-Emby-Authorization` generado dinámicamente
- Errores: `AuthError.invalidCredentials`, `AuthError.networkError`, `AuthError.serverError`

### Auth Model

```swift
@MainActor
@Observable
final class AuthModel {
    var username = ""
    var password = ""
    var isAuthenticating = false
    var errorMessage: String?
    var isAuthenticated = false
    var currentUser: JellyfinUser?

    func login(serverURL: URL) async { ... }
    func logout() { ... }
    func restoreSession() async { ... }
}
```

### Flujo de navegación (RootView)

```
if server == nil → ServerConnectionView
else if !isAuthenticated → LoginView
else → MareaHomeView (placeholder por ahora)
```

`restoreSession()` se llama al inicio: si hay token guardado, intenta validar contra el servidor. Si falla → muestra login.

## Archivos a crear/modificar

| Archivo | Acción | Módulo |
|---------|--------|--------|
| `Sources/ThisJellyFixCore/KeychainStore.swift` | **Crear** | Core |
| `Sources/ThisJellyFixCore/JellyfinUser.swift` | **Crear** | Core |
| `Sources/ThisJellyFixNetworking/JellyfinAuthClient.swift` | **Crear** | Networking |
| `Sources/ThisJellyFixFeature/AuthModel.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/LoginView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift` | **Modificar** | Feature |
| `Tests/ThisJellyFixCoreTests/KeychainStoreTests.swift` | **Crear** | CoreTests |
| `Tests/ThisJellyFixNetworkingTests/JellyfinAuthClientTests.swift` | **Crear** | NetworkingTests |

## Criterios de aceptación

1. El usuario puede introducir usuario + contraseña e iniciar sesión
2. Credenciales incorrectas muestran error inline
3. Token se almacena en Keychain tras login exitoso
4. Al cerrar y reabrir la app, la sesión se restaura automáticamente
5. Logout limpia Keychain y vuelve a la pantalla de login
6. Tests unitarios pasan para KeychainStore, AuthClient (mock), y AuthModel
7. Compila en macOS, iOS (que cubre iPadOS)

## Fuera de alcance de esta fase

- Pantalla Home con contenido (fase 2)
- Selección de usuario (multi-usuario)
- Biometría (Face ID / Touch ID)
- Refresh automático de token
- Two-factor authentication
