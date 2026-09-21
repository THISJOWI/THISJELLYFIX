# Spec: Fase 5 — Reproductor VLCKit

**Fecha:** 2026-09-21
**Estado:** Aprobado
**Alcance:** Reproductor de vídeo con VLCKit, subtítulos, pistas de audio, calidad, gestos, velocidad

---

## Objetivo

Reemplazar AVPlayer nativo con VLCKit para máxima compatibilidad de formatos. Soporte completo para subtítulos (embebidos y externos), pistas de audio múltiples, selección de calidad, gestos táctiles y velocidad de reproducción.

## Dependencia

VLCKit se agrega como dependencia SPM en `Package.swift`:
```swift
.package(url: "https://github.com/nicklama/VLCKit.git", from: "3.6.0")
```

Plataformas soportadas: iOS 13+, macOS 10.15+. Para tvOS/visionOS se mantiene AVPlayer como fallback.

## API Jellyfin

### URLs de stream

```
GET /Videos/{itemId}/stream?Static=true&MediaSourceId={mediaSourceId}
Headers: X-Emby-Authorization
```

```
GET /Videos/{itemId}/master.m3u8?MediaSourceId={mediaSourceId}
Headers: X-Emby-Authorization
```

### PlaybackInfo (ya implementado)

```
POST /Items/{itemId}/PlaybackInfo
Body: {"UserId": "{userId}"}
```

Devuelve `mediaSources` con `directStreamUrl`, `transcodingUrl`, `container`, y `mediaStreams` (tracks de audio, video, subtítulos).

## Modelos Core

```swift
// Sources/ThisJellyFixCore/Tracks.swift

public struct AudioTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let language: String?
    
    public init(id: Int, name: String, language: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
    }
}

public struct SubtitleTrack: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let language: String?
    public let isExternal: Bool
    
    public init(id: Int, name: String, language: String? = nil, isExternal: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.isExternal = isExternal
    }
}
```

## PlaybackEngine Protocol (actualizado)

```swift
public protocol PlaybackEngine: Sendable {
    var kind: PlaybackEngineKind { get }
    func prepare(_ request: PlaybackRequest) async throws
    func play() async
    func pause() async
    func stop() async
    func seek(to seconds: Double) async
    func setPlaybackRate(_ rate: Float) async
    func selectAudioTrack(index: Int) async
    func selectSubtitleTrack(index: Int) async
    func loadExternalSubtitle(url: URL) async
    var availableAudioTracks: [AudioTrack] { get async }
    var availableSubtitleTracks: [SubtitleTrack] { get async }
    var currentTime: Double { get async }
    var duration: Double { get async }
    var isPlaying: Bool { get async }
}
```

## VLCPlaybackEngine

Implementación del protocolo `PlaybackEngine` usando VLCKit:

```swift
// Sources/ThisJellyFixPlayback/VLCPlaybackEngine.swift
import Foundation
import ThisJellyFixCore
import VLCKit

public final class VLCPlaybackEngine: PlaybackEngine {
    public let kind: PlaybackEngineKind = .universal
    
    private let mediaPlayer = VLCMediaPlayer()
    
    public init() {}
    
    public func prepare(_ request: PlaybackRequest) async throws {
        let media = VLCMedia(url: request.streamURL)
        mediaPlayer.media = media
    }
    
    public func play() async { mediaPlayer.play() }
    public func pause() async { mediaPlayer.pause() }
    public func stop() async { mediaPlayer.stop() }
    
    public func seek(to seconds: Double) async {
        mediaPlayer.time = VLCTime(int: Int32(seconds * 1000))
    }
    
    public func setPlaybackRate(_ rate: Float) async {
        mediaPlayer.rate = rate
    }
    
    public func selectAudioTrack(index: Int) async {
        mediaPlayer.currentAudioTrackIndex = Int32(index)
    }
    
    public func selectSubtitleTrack(index: Int) async {
        mediaPlayer.currentVideoSubTitleIndex = Int32(index)
    }
    
    public func loadExternalSubtitle(url: URL) async {
        mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: false)
    }
    
    public var availableAudioTracks: [AudioTrack] {
        mediaPlayer.audioTrackNames.enumerated().map { idx, name in
            AudioTrack(id: idx, name: name)
        }
    }
    
    public var availableSubtitleTracks: [SubtitleTrack] {
        mediaPlayer.videoSubTitlesNames.enumerated().map { idx, name in
            SubtitleTrack(id: idx, name: name)
        }
    }
    
    public var currentTime: Double { mediaPlayer.time.intValue.doubleValue / 1000.0 }
    public var duration: Double { mediaPlayer.length.intValue.doubleValue / 1000.0 }
    public var isPlaying: Bool { mediaPlayer.isPlaying }
}
```

## UI — PlayerView

### Estructura de vistas

```
PlayerView (SwiftUI)
├── VLCVideoView (UIViewRepresentable) — renderizado de vídeo
├── GestureOverlay — gestos táctiles
├── ControlsOverlay — controles superpuestos
│   ├── TopBar: botón cerrar, título
│   ├── CenterControls: play/pause grande
│   ├── BottomBar: seek bar, tiempo
│   └── ActionButtons: subtítulos, audio, calidad, velocidad
└── Sheets: AudioPicker, SubtitlePicker, QualityPicker, SpeedPicker
```

### Gestos táctiles

| Gesture | Acción |
|---------|--------|
| Tap | Mostrar/ocultar controles |
| Swipe left | Seek -15s |
| Swipe right | Seek +15s |
| Swipe up (izquierda) | Subir brillo |
| Swipe down (izquierda) | Bajar brillo |
| Swipe up (derecha) | Subir volumen |
| Swipe down (derecha) | Bajar volumen |

### PlayerViewModel

```swift
@Observable
final class PlayerViewModel {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var selectedAudioTrack: Int?
    var selectedSubtitleTrack: Int?
    var availableAudioTracks: [AudioTrack] = []
    var availableSubtitleTracks: [SubtitleTrack] = []
    var showControls = true
    var showAudioPicker = false
    var showSubtitlePicker = false
    var showSpeedPicker = false
    var brightness: CGFloat = 0.5
    var volume: Float = 1.0
}
```

## Archivos

| Archivo | Acción | Módulo |
|---------|--------|--------|
| `Package.swift` | **Modificar** — agregar VLCKit | Root |
| `Sources/ThisJellyFixCore/Tracks.swift` | **Crear** | Core |
| `Sources/ThisJellyFixPlayback/PlaybackEngine.swift` | **Modificar** — actualizar protocolo | Playback |
| `Sources/ThisJellyFixPlayback/AVPlaybackEngine.swift` | **Modificar** — conformar a protocolo actualizado | Playback |
| `Sources/ThisJellyFixPlayback/VLCPlaybackEngine.swift` | **Crear** | Playback |
| `Sources/ThisJellyFixFeature/PlayerView.swift` | **Reescribir** | Feature |
| `Sources/ThisJellyFixFeature/PlayerViewModel.swift` | **Crear** | Feature |
| `Sources/ThisJellyFixFeature/DetailView.swift` | **Modificar** — integrar nuevo PlayerView | Feature |
| `Docs/specs/2026-09-21-vlc-player-phase-design.md` | **Crear** | Docs |

## Criterios de aceptación

1. VLCKit reproduce contenido en lugar de AVPlayer
2. Selección de pista de audio funciona
3. Selección de subtítulos funciona (embebidos y externos SRT)
4. Selección de calidad funciona (elegir MediaSource)
5. Velocidad de reproducción funciona (0.5x, 1x, 1.5x, 2x)
6. Gestos táctiles funcionan (seek, brillo, volumen)
7. Controles se muestran/ocultan con tap
8. Compatibilidad: MKV, FLAC, AVI, MP4, SRT, ASS
9. Build en macOS + iOS con `swift build`
10. Tests unitarios para VLCPlaybackEngine (mock de tracks)

## Fuera de alcance

- AirPlay / Chromecast
- Descargas offline
- Picture-in-Picture
- tvOS / visionOS (mantienen AVPlayer)
