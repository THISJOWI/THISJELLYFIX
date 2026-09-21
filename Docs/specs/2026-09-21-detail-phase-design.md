# Spec: Fase 3 — Detalle de Item

**Fecha:** 2026-09-21
**Estado:** Aprobado
**Alcance:** Pantalla de detalle para películas y series con información completa

---

## Objetivo

Al tocar una tarjeta en la Home, mostrar una pantalla de detalle con: imagen grande, título, año, sinopsis, rating, y botón de reproducción (placeholder).

## API Jellyfin

### Detalle de item
```
GET /Users/{userId}/Items/{itemId}
Headers: X-Emby-Authorization, MediaBrowser Token
```

Respuesta: objeto `JellyfinMediaItem` extendido con campos adicionales.

### Imagen backdrop
```
GET /Items/{itemId}/Images/Backdrop?maxWidth=1200&quality=90
```

## Modelos

```swift
// Extended detail (en Core)
public struct JellyfinItemDetail: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let overview: String?
    public let year: Int?
    public let officialRating: String?
    public let communityRating: Double?
    public let genres: [String]?
    public let runTimeTicks: Int64?
    public let premiereDate: String?
    public let seriesName: String?  // Para episodios
    public let parentIndexNumber: Int?  // Número de episodio
    public let indexNumber: Int?  // Número de episodio
    public let imageTags: [String: String]?
}
```

### Networking

```swift
public protocol JellyfinItemDetailProviding: Sendable {
    func fetchItemDetail(userId: String, serverURL: URL, token: String, itemId: String) async throws -> JellyfinItemDetail
}
```

## UI

### DetailView
- Imagen backdrop (fondo, con overlay degradado)
- Imagen poster superpuesta
- Título + año + rating
- Géneros como badges
- Sinopsis
- Botón "Reproducir" (placeholder — fase 4)
- En series: lista de episodios por temporada

### Navegación
- `NavigationStack` en HomeView
- `.navigationDestination` para `JellyfinMediaItem`

## Archivos

| Archivo | Acción | Módulo |
|---------|--------|--------|
| `Sources/ThisJellyFixCore/JellyfinItemDetail.swift` | **Crear** | Core |
| `Sources/ThisJellyFixNetworking/JellyfinItemDetailClient.swift` | **Crear** | Networking |
| `Sources/ThisJellyFixFeature/DetailView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/EpisodeRowView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/HomeView.swift` | **Modificar** — NavigationStack |
| `Tests/ThisJellyFixNetworkingTests/JellyfinItemDetailClientTests.swift` | **Crear** | NetworkingTests |

## Criterios de aceptación

1. Tap en tarjeta → pantalla de detalle con imagen, título, sinopsis
2. Películas muestran año, duración, rating
3. Series muestran lista de episodios
4. Botón "Reproducir" visible (sin acción aún)
5. Botón "Volver" o swipe para regresar
6. Tests para el cliente de detalle
7. Compila en macOS, iOS
