# Spec: Fase 4 — Reproducción

**Fecha:** 2026-09-21
**Estado:** Aprobado
**Alcance:** Reproducción de vídeo con AVPlayer, botón de play funcional, pantalla de reproducción

---

## Objetivo

Al pulsar "Reproducir" en el detalle, abrir un reproductor de vídeo que use AVFoundation para reproducir el contenido desde el servidor Jellyfin.

## API Jellyfin

### Obtener info de reproducción
```
POST /Items/{itemId}/PlaybackInfo
Headers: X-Emby-Authorization, MediaBrowser Token
Body: {"UserId": "{userId}", "DeviceProfile": {...}}
```

### URL de stream
```
GET /Videos/{itemId}/stream?Static=true&MediaSourceId={mediaSourceId}
Headers: MediaBrowser Token
```

## Modelos

```swift
// Core
public struct PlaybackInfo: Codable, Sendable {
    public let mediaSources: [MediaSource]
    
    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

public struct MediaSource: Codable, Sendable {
    public let id: String
    public let name: String
    public let container: String?
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
    }
}
```

### Networking

```swift
public protocol JellyfinPlaybackProviding: Sendable {
    func fetchPlaybackInfo(userId: String, serverURL: URL, token: String, itemId: String) async throws -> PlaybackInfo
}
```

### PlaybackEngine

Implementar `PlaybackEngine` protocol existente con `AVPlayer`:
- `AVPlaybackEngine`: usa `AVPlayer` nativo
- Soporte para direct stream y transcoding
- Controles básicos: play, pause, seek, stop

## UI

### PlayerView
- Pantalla a pantalla completa con `AVPlayerViewController` (iOS) o `VideoPlayer` (macOS)
- Controles nativos del sistema
- Botón cerrar para volver al detalle
- Auto-play al abrir

### Integración
- DetailView → tap "Reproducir" → fetch playback info → abrir PlayerView
- PlayerView recibe URL del stream

## Archivos

| Archivo | Acción | Módulo |
|---------|--------|--------|
| `Sources/ThisJellyFixCore/PlaybackInfo.swift` | **Crear** | Core |
| `Sources/ThisJellyFixNetworking/JellyfinPlaybackClient.swift` | **Crear** | Networking |
| `Sources/ThisJellyFixPlayback/AVPlaybackEngine.swift` | **Crear** | Playback |
| `Sources/ThisJellyFixFeature/PlayerView.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/DetailView.swift` | **Modificar** | Feature |
| `Tests/ThisJellyFixNetworkingTests/JellyfinPlaybackClientTests.swift` | **Crear** | NetworkingTests |

## Criterios de aceptación

1. Tap "Reproducir" → obtiene URL de stream → abre reproductor
2. El vídeo se reproduce con controles nativos
3. Play/pause funciona
4. Botón cerrar regresa al detalle
5. Manejo de errores (sin stream disponible, red)
6. Tests para el cliente de reproducción
7. Compila en macOS, iOS

## Fuera de alcance

- Selección de calidad/subtítulos/audio
- Reproducción en segundo plano
- AirPlay
- Chromecast
- Offline/download
