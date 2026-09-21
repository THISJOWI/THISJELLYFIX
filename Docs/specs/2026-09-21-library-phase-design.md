# Spec: Fase 2 — Biblioteca y Home

**Fecha:** 2026-09-21
**Estado:** Aprobado
**Alcance:** Home tipo Netflix con 5 filas de contenido, tarjetas con imágenes, navegación por categorías

---

## Objetivo

Mostrar el contenido de la biblioteca Jellyfin en una pantalla Home tipo Netflix: filas horizontales de tarjetas con imágenes, organizadas por categoría. El usuario puede hacer tap en una tarjeta para ver detalles (fase 3).

## API Jellyfin

### Obtener vistas del usuario
```
GET /Users/{userId}/Views
Headers:
  X-Emby-Authorization: MediaBrowser Client="thisjellyfix", Device="...", DeviceId="...", Version="0.1"
  MediaBrowser Token="{accessToken}"
```

Respuesta:
```json
{
  "Items": [
    { "Id": "...", "Name": "Movies", "CollectionType": "movies" },
    { "Id": "...", "Name": "TV Shows", "CollectionType": "tvshows" }
  ]
}
```

### Obtener items de una vista
```
GET /Users/{userId}/Items?ParentId={folderId}&IncludeItemTypes=Movie,Series&OrderBy=DateCreated&Descending=true&Limit=20
Headers: mismos que arriba
```

### Obtener imagen de un item
```
GET /Items/{itemId}/Images/Primary?maxWidth=300&quality=90
Headers: MediaBrowser Token="{accessToken}"
```
Sin imagen → placeholder con首字母 del nombre.

## Categorías Home

1. **Últimos agregados** — Items de todas las vistas, ordenados por fecha de creación
2. **Películas** — Solo de la vista de películas
3. **Series** — Solo de la vista de series
4. **Favoritos** — `GET /Users/{userId}/Items?Filters=IsFavorite&Limit=20`
5. **Visto recientemente** — `GET /Users/{userId}/Items?Filters=IsPlayed&Limit=20`

## Modelos

```swift
// Core
public struct JellyfinMediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String  // "Movie", "Series", "Episode"
    public let overview: String?
    public let seriesName: String?  // Para episodios
    public let year: Int?
    public let imageTags: [String: String]?
    public let officialRating: String?
    public let communityRating: Double?
}

public struct LibraryView: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let collectionType: String?
}
```

### Networking

```swift
// Protocolo
public protocol JellyfinLibraryProviding: Sendable {
    func fetchViews(userId: String, serverURL: URL, token: String) async throws -> [LibraryView]
    func fetchItems(userId: String, serverURL: URL, token: String, parentId: String?, includeTypes: String?, limit: Int, orderBy: String, filters: String?) async throws -> [JellyfinMediaItem]
}
```

### Image Loading

- `AsyncImage` con cache simple en memoria
- URL: `{serverURL}/Items/{itemId}/Images/Primary?maxWidth=300&quality=90`
- Fallback:首字母 del nombre sobre fondo de color oscuro

## Archivos

| Archivo | Acción | Módulo |
|---------|--------|--------|
| `Sources/ThisJellyFixCore/JellyfinMediaItem.swift` | **Crear** | Core |
| `Sources/ThisJellyFixNetworking/JellyfinLibraryClient.swift` | **Crear** | Networking |
| `Sources/ThisJellyFixFeature/LibraryModel.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/HomeView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/MediaCardView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/ImageView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/ThisJellyFixRootView.swift` | **Modificar** | Feature |
| `Tests/ThisJellyFixNetworkingTests/JellyfinLibraryClientTests.swift` | **Crear** | NetworkingTests |

## Criterios de aceptación

1. Home muestra 5 filas de contenido con imágenes
2. Cada fila tiene título y scroll horizontal
3. Las imágenes cargan de la URL del servidor
4. Sin imagen → placeholder con首字母
5. Manejo de errores (sin conexión, sin datos) con retry
6. Pull-to-refresh recarga el contenido
7. Tests para el cliente de biblioteca (mock)
8. Compila en macOS, iOS

## Fuera de alcance

- Detalle de item (fase 3)
- Búsqueda
- Filtros avanzados
- Paginación infinita
