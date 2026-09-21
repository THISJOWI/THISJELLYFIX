# Plan: Fase 5 — Reproductor VLCKit

**Fecha:** 2026-09-21
**Spec:** `Docs/specs/2026-09-21-vlc-player-phase-design.md`

---

## Resumen

Reemplazar AVPlayer con VLCKit para máximo soporte de formatos. Agregar selección de audio, subtítulos, calidad, velocidad y gestos táctiles.

## Dependencias

- Fase 4 (Playback) completada ✓
- VLCKit SPM package

---

## Tareas

### Tarea 1: VLCKit Dependency
**Archivos:** `Package.swift`
**Acción:**
1. Agregar `.package(url: "https://github.com/nicklama/VLCKit.git", from: "3.6.0")` a `Package.swift`
2. Agregar `"VLCKit"` como dependency de `ThisJellyFixPlayback` target
3. Verificar que `swift build` compila

**Verificación:** `swift build` sin errores

---

### Tarea 2: Track Models
**Archivos:** `Sources/ThisJellyFixCore/Tracks.swift`
**Acción:**
1. Crear `AudioTrack` struct (id, name, language) con `Identifiable`, `Sendable`, `Equatable`
2. Crear `SubtitleTrack` struct (id, name, language, isExternal) con `Identifiable`, `Sendable`, `Equatable`

**Verificación:** `swift build` compila

---

### Tarea 3: Actualizar PlaybackEngine Protocol
**Archivos:** `Sources/ThisJellyFixPlayback/PlaybackEngine.swift`
**Acción:**
1. Agregar métodos al protocolo: `seek(to:)`, `setPlaybackRate(_:)`, `selectAudioTrack(index:)`, `selectSubtitleTrack(index:)`, `loadExternalSubtitle(url:)`
2. Agregar propiedades: `availableAudioTracks`, `availableSubtitleTracks`, `currentTime`, `duration`, `isPlaying`

**Verificación:** `swift build` compila (AVPlaybackEngine se actualizará para conformar)

---

### Tarea 4: Actualizar AVPlaybackEngine
**Archivos:** `Sources/ThisJellyFixPlayback/AVPlaybackEngine.swift`
**Acción:**
1. Conformar a protocolo actualizado
2. Implementar `seek(to:)` existente
3. Métodos de subtítulos/audio → no-op (AVPlayer no soporta selección)
4. `availableAudioTracks`/`availableSubtitleTracks` → array vacío
5. `setPlaybackRate` → `player?.rate = rate`

**Verificación:** `swift build` compila

---

### Tarea 5: VLCPlaybackEngine
**Archivos:** `Sources/ThisJellyFixPlayback/VLCPlaybackEngine.swift`
**Acción:**
1. Crear clase que conforma `PlaybackEngine` usando `VLCMediaPlayer`
2. Implementar `prepare()` → crear `VLCMedia(url:)` y asignar a player
3. Implementar `play()`, `pause()`, `stop()`
4. Implementar `seek(to:)` → `VLCTime(int: Int32(seconds * 1000))`
5. Implementar `setPlaybackRate(_:)` → `mediaPlayer.rate = rate`
6. Implementar `selectAudioTrack(index:)` → `mediaPlayer.currentAudioTrackIndex`
7. Implementar `selectSubtitleTrack(index:)` → `mediaPlayer.currentVideoSubTitleIndex`
8. Implementar `loadExternalSubtitle(url:)` → `mediaPlayer.addPlaybackSlave`
9. Implementar propiedades computadas para tracks, currentTime, duration, isPlaying

**Verificación:** `swift build` compila

---

### Tarea 6: PlayerViewModel
**Archivos:** `Sources/ThisJellyFixFeature/PlayerViewModel.swift`
**Acción:**
1. Crear `@Observable` class con estado del reproductor
2. Propiedades: isPlaying, currentTime, duration, playbackRate, tracks, showControls, brightness, volume
3. Métodos: togglePlayPause(), seek(), setRate(), selectAudio(), selectSubtitle()
4. Timer para actualizar currentTime cada 0.5s
5. Bridge entre SwiftUI y VLCPlaybackEngine

**Verificación:** `swift build` compila

---

### Tarea 7: PlayerView — UI Base
**Archivos:** `Sources/ThisJellyFixFeature/PlayerView.swift`
**Acción:**
1. Reescribir PlayerView con VLCVideoView (UIViewRepresentable)
2. Crear ControlsOverlay con top bar (cerrar), center (play/pause), bottom (seek bar, tiempo)
3. Crear GestureOverlay con gesture modifiers
4. Integrar PlayerViewModel
5. Auto-play al aparecer

**Verificación:** `swift build` compila, app abre reproductor

---

### Tarea 8: Gestos Táctiles
**Archivos:** `Sources/ThisJellyFixFeature/PlayerView.swift` (continuación)
**Acción:**
1. Implementar tap gesture → toggle controles
2. Implementar swipe left/right → seek ±15s
3. Implementar swipe up/down left side → brillo
4. Implementar swipe up/down right side → volumen
5. Agregar feedback visual (HUD de seek, brillo, volumen)

**Verificación:** `swift build` compila, gestos responden

---

### Tarea 9: Track Selection UI
**Archivos:** `Sources/ThisJellyFixFeature/PlayerView.swift` (continuación)
**Acción:**
1. Crear AudioPicker sheet con lista de pistas de audio
2. Crear SubtitlePicker sheet con lista de subtítulos + opción "Desactivados" + "Externo"
3. Crear SpeedPicker sheet con opciones 0.5x, 1x, 1.5x, 2x
4. Agregar botones de acción en la barra inferior del reproductor

**Verificación:** `swift build` compila, sheets se abren

---

### Tarea 10: Quality Selection
**Archivos:** `Sources/ThisJellyFixFeature/PlayerView.swift` + `DetailView.swift`
**Acción:**
1. Agregar botón de calidad en reproductor
2. Mostrar opciones de MediaSource (direct stream vs transcoded)
3. Al seleccionar, cambiar URL de stream y recargar player
4. Integrar con DetailView para pasar MediaSource info

**Verificación:** `swift build` compila, cambio de calidad funciona

---

### Tarea 11: Tests
**Archivos:** `Tests/ThisJellyFixPlaybackTests/VLCPlaybackEngineTests.swift`
**Acción:**
1. Crear test target `ThisJellyFixPlaybackTests`
2. Test VLCPlaybackEngine: prepare, play, pause, stop
3. Test track selection methods
4. Test seek and playback rate

**Verificación:** `swift test` pasa

---

## Orden de ejecución

```
Tarea 1 (dependency) → Tarea 2 (models) → Tarea 3 (protocol) → Tarea 4 (AV conform) →
Tarea 5 (VLC engine) → Tarea 6 (ViewModel) → Tarea 7 (UI base) → Tarea 8 (gestos) →
Tarea 9 (track UI) → Tarea 10 (quality) → Tarea 11 (tests)
```

## Verificación final

1. `swift build` compila sin errores
2. `swift test` pasa
3. App abre reproductor con VLCKit
4. Gestos táctiles funcionan
5. Selección de audio/subtítulos/velocidad funciona
6. Selección de calidad funciona
7. MKV, FLAC se reproducen correctamente
