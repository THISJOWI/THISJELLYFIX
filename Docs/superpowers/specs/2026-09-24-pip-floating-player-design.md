# Design: Reproductor flotante (Picture-in-Picture) — iOS/iPadOS

**Date:** 2026-09-24
**Status:** approved (approach A — híbrido VLC + AVPlayer)

## Goal

Salir de la app (o minimizar el reproductor) mientras un episodio/película sigue
reproduciéndose en una ventana flotante del sistema (PiP nativo de iOS).

## Scope

- **v1:** iOS/iPadOS únicamente (`#if os(iOS)`). tvOS no tiene PiP; macOS/visionOS fuera de scope.
- Reproductor normal = VLC, sin cambios de comportamiento ni regresiones.
- PiP = AVPlayer con stream **HLS** servido por Jellyfin (VLC no puede mostrar PiP).

## Non-goals

- Migrar la reproducción principal a AVPlayer.
- PiP en macOS (panel NSWindow) / visionOS.
- Subtítulos externos (SRT) dentro de la ventana PiP (solo los embebidos del HLS).

## Architecture

### 1. HLS DeviceProfile + resolver (Networking/Core)

- `PlaybackDeviceProfile` (Core, Codable): perfil Jellyfin **HLS-only**
  (`DirectPlayProfiles: []`, `TranscodingProfiles: [hls, ts, h264+aac]`) →
  el servidor siempre devuelve `TranscodingUrl` (master.m3u8).
- `JellyfinPlaybackClient.fetchPlaybackInfo(..., deviceProfile:)` — variante con
  perfil; la firma del protocolo existente no cambia.
- `HlsStreamResolver` (Networking): resuelve el `TranscodingUrl` de un item y
  devuelve URL (añade `ApiKey` si falta). `nil` si el server no ofrece HLS →
  PiP no disponible (fallback: audio en background vía VLC + UIBackgroundModes).

### 2. `PipSession` (Feature, solo iOS)

Objeto `@MainActor` con `static let shared` — **independiente de la vista** para
sobrevivir a cambios de scenePhase durante el handoff.

Responsabilidades:
- Crea `AVPlayer` + `AVPlayerLayer` + `AVPictureInPictureController`.
- `start(hlsURL:position:context:)` — context = (itemId, serverURL, token,
  userId, playSessionId) para reporting.
- Reporting de progreso cada 10 s con `JellyfinPlaybackReporter` (misma sesión).
- Delegate:
  - **restore** (tap en ventana PiP) → `onRestore` (VM reanuda VLC) →
    `completionHandler(true)`.
  - **didStop sin restore** (X o swipe-close) → `reportStopped` + `onClosed`
    (VM cierra el player si sigue vivo).
- `didStart` no llega en 2 s → cancela (fallback a VLC en background).
- `stop(capturePosition:)` — detiene AVPlayer, devuelve posición AVPlayer.

### 3. `PlayerViewModel` — wiring

- `hlsURL` (prefetch en `onAppear` vía `resolvePipSupport()`, no bloquea inicio).
- `pipState: idle | active`, `pipAvailable: Bool`.
- `startPictureInPicture()`:
  1. guard hlsURL + reportingConfigured + reproducción activa
  2. `reportProgress(pos)` → `stopUpdating()` → `engine.pause()`
  3. `PipSession.shared.start(...)` (async: AVPlayer seek(pos) + play + PiP)
- `resumeFromPictureInPicture()`:
  1. `session.stop(capturePosition:)` → T2
  2. `prepareStream(url, startPosition: T2)` + play + `verifyResume` (VLC puede
     haber parado en `onDisappear` — camino uniforme de reanudación)
  3. `startUpdating()`
- `onPiPClosed` closure → `dismissPlayer()`.
- `onDisappear` con PiP activo: **no** `reportStopped` (la sesión sigue viva),
  pero sí `detachDrawable()` + `engine.stopSync()` (evita el crash VLC).
  `stopSync(reportStopped:)` gana parámetro.

### 4. `PlayerView` — activación

- `@Environment(\.scenePhase)`:
  - `.background` + reproducción activa → `startPictureInPicture()` (automático)
  - `.active` + `pipState == .active` → `resumeFromPictureInPicture()`
    (vuelta vía app switcher; el tap en PiP lo gestiona el delegate)
- Botón PiP en `ControlsOverlay` (solo iOS, visible si `pipAvailable`).
- `PipLayerHostView` (UIViewRepresentable): aloja el `AVPlayerLayer` de la
  sesión dentro del árbol de vistas mientras el player está montado; oculto
  cuando la app está en foreground con PiP activo (evita vídeo duplicado).

### 5. Entitlements / Info.plist

- `Apps/iOS/Info.plist` (nuevo) con `UIBackgroundModes: [audio]`
  (modo "Audio, AirPlay, and Picture in Picture").
- `project.yml`: iOS app target → `INFOPLIST_FILE: Apps/iOS/Info.plist`
  (merge con `GENERATE_INFOPLIST_FILE: YES`).
- Regenerar proyecto con `xcodegen`.
- `AVAudioSession` categoría `.playback` al arrancar PiP.

## Data flow

```
Auto:  scenePhase .background ──► VM.startPictureInPicture
Manual: botón PiP ───────────────┘
         │
         ├─ reportProgress(T) ; stopUpdating() ; VLC pause
         ├─ PipSession.start(hlsURL, T, ctx)
         │    AVPlayer(HLS).seek(T) → play → PiPC.start()
         │    didStart en 2s ──no──► cancel + resume VLC (audio background)
         ▼
      PiP activo (AVPlayer reporta progreso cada 10s)
         │
    tap en PiP ──► delegate restore ──► VM.resumeFromPictureInPicture
    X / swipe  ──► didStop sin restore ──► reportStopped + onClosed
    .active    ──► VM.resumeFromPictureInPicture (mismo camino)
```

## Error handling

| Fallo | Comportamiento |
|---|---|
| Server sin HLS (`TranscodingUrl` null) | `pipAvailable = false`, botón oculto, sin auto-PiP; VLC sigue en background (audio) |
| `didStart` no llega (2 s) | Cancela PiP, reanuda VLC → audio en background |
| AVPlayer item falla | `reportStopped`, notifica cierre, no deja la app sin reproducción |
| PiP no soportado (simulador) | `isPictureInPictureSupported == false` → degradación silenciosa |
| Restore con VM muerto (player cerrado) | `completionHandler(false)` → PiP termina, `reportStopped` |

## Testing

- **Unit:** encoding del `PlaybackDeviceProfile` (claves DirectPlay/Transcoding
  Profiles), `HlsStreamResolver` con `MockNetworkSession` (ApiKey añadido,
  TranscodingUrl null → nil), `fetchPlaybackInfo(deviceProfile:)` envía
  `DeviceProfile` en el body.
- **Build:** `swift build` (macOS/SwiftPM) + `xcodebuild` target iOS.
- **Manual (device):** auto-PiP al salir, tap→restore, X→cierre+progreso,
  volver por app switcher, server sin HLS, episodio con subtítulos externos.

## Risks

- **Handoff VLC→AVPlayer:** 1-3 s de rebuffer al entrar/salir de PiP (aceptado).
- **Transcoding:** todo item genera job HLS en el server al hacer PiP (prefetch
  al inicio de reproducción para calentar; carga aceptada en server doméstico).
- **AVPlayerLayer fuera de pantalla:** si iOS rechaza arrancar PiP con la capa
  no visible, adjuntarla al layer del player VLC (fallback documentado).
