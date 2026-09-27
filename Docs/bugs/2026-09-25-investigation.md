# Investigación de bugs — ThisJellyFix

Fecha: 2026-09-25 · HEAD: `f145cc7` · Método: systematic-debugging (Phase 1: causa raíz, sin tocar código)

Fuente complementaria: Notion "THISJELLYFIX" (Prioridad 2 ya listaba: carga al avanzar, subtítulos, reproductor flotante).

---

## BUG 1 — Tarda en cargar

### Causas raíz confirmadas

| # | Causa | Evidencia | Por qué | Fix |
|---|---|---|---|---|
| 1.1 | **Home bloqueado hasta cargar TODA la biblioteca** | `ThisJellyFixRootView.swift:28-31,168-174` | `libraryModel` se asigna tras `await load()` → 6 peticiones antes del primer píxel; peor caso 6×15s timeout | Asignar modelo tras primera fila + skeleton; quitar el gate `isLoadingLibrary` |
| 1.2 | **6 `await` secuenciales, filas publicadas de golpe** | `LibraryModel.swift:44-109` | Latencia = suma de RTTs; solo `views` es dependencia real | `async let` (patrón ya usado en `FavoritesView.swift:107-118`) + publicar filas incrementalmente |
| 1.3 | **Caché de imágenes solo en memoria** | `ImageView.swift:10-24` | NSCache se vacía en cada arranque → re-descarga ~100 pósters; `totalCostLimit` inerte porque no se pasa `cost:` | Caché con disco (o `URLCache`) + `cost = bytes` |
| 1.4 | **Decode JPEG en MainActor** | `ImageView.swift:47,65-71` | `Task{}` dentro de clase `@MainActor` hereda actor → 20-30 decodes en serie en main | `Task.detached` / helper no aislado |
| 1.5 | **Petición de resume duplicada** | `HomeView.swift:168-172` + `LibraryModel.swift:53` | `onAppear` repite `/Items/Resume` tras `load()` (y en cada vuelta al tab) | Un solo dueño de esa fila |
| 1.6 | **Recarga completa (6 peticiones + 2s sleep) tras cada reproducción** | `HomeView.swift:24-29,202-208` | Solo cambió la fila "Estás viendo" | Llamar `refreshResume()` en vez de `load()` |
| 1.7 | **Restore de sesión DESPUÉS del primer frame → parpadeo de login** | `ThisJellyFixRootView.swift:53-60 vs 75-79`, `AuthModel.swift:24-32` | Primer frame = LoginView, luego 3 re-layouts completos | Restaurar sesión en `init` (solo 3 lecturas de Keychain) o gate con `isRestoring` |
| 1.8 | **Una petición fallida destruye todo el Home** | `LibraryModel.swift:66-112` | Solo resume tiene `do/catch` propio; un 401/timeout en la última tira las 5 respuestas recibidas | `do/catch` por fila, render parcial |

### Sospechosas (no verificadas en runtime)
- Lecturas síncronas de Keychain dentro de `body` — `ThisJellyFixRootView.swift:38,85`
- Keychain por petición (`DeviceIdentifier`) — `JellyfinLibraryClient.swift:167`
- `TJFLog` con `fopen` síncrono desde MainActor — `DeviceIdentifier.swift:7-16`
- Consultas de fila sin `Recursive=true` — `JellyfinLibraryClient.swift:69-95`
- Imagen fallida nunca reintenta (`currentURL` no se limpia) — `ImageView.swift:61-86`
- Filas sin `tag` en URL de imagen → arte obsoleta

---

## BUG 2 — Subtítulos predeterminados no funcionan

Cadena: locale → persistencia → normalización → matching → selección. **Rotos: persistencia, normalización, matching.**

| # | Causa | Evidencia | Mecanismo |
|---|---|---|---|
| 2.1 | **El idioma del sistema nunca llega al reproductor** | `ProfileView.swift:155-163` (único escritor de `lang.subtitles`) vs `PlayerViewModel.swift:681-705` | El seed solo ocurre si el usuario abre Perfil. Si `preferredSubtitles == nil` → `LanguagePreferences.selectTrack` devuelve nil por el `guard` de `LanguagePreferences.swift:82` → nunca se selecciona pista |
| 2.2 | **Matching solo acepta códigos ISO, no nombres** | `LanguagePreferences.swift:87-96` | `"Spanish"`→`spanish`≠`es` falla; `"Español"` no pliega diacríticos (`ñ` se queda) → falla; `"Inglés"`, `"English"`, `"und"`, `"mul"` → fallan. La tabla nombre↔código EXISTE en `TrackNaming.swift:156-259` pero es privada y solo para display |
| 2.3 | **Se usa el `language` crudo del motor, se descarta el del servidor** | `PlayerViewModel.swift:609-628`, `VLCPlaybackEngine.swift:140-144` | Pistas externas `.srt` (addPlaybackSlave) tienen `language` nil → nunca matchean aunque Jellyfin sí tiene `MediaStream.language` |
| 2.4 | **Siempre arranca en "Desactivados"** | `PlayerView.swift:884-895` | Consecuencia de 2.1-2.3: sin match, VLC queda con SPU off |
| 2.5 | Re-poll solo si aumenta el conteo de pistas | `PlayerViewModel.swift:451-460` | Pista que aparece tarde o cuyo `language` se rellena después no re-dispara `applyLanguagePreferences` |
| 2.6 | "Sin preferencia" se revierte | `ProfileView.swift:155-163` | Elegir nil → siguiente `onAppear` re-siembra el sistema (bug distinto pero mismo fichero) |

**Fix mínimo en orden:** (1) fallback `?? LanguagePreferences.systemDefault` en `applyLanguagePreferences`; (2) `language = track.language ?? streamDelServidor`; (3) normalizador nombre→código compartido con fold de diacríticos reutilizando la tabla de `TrackNaming`; (4) tests para `"Spanish"`/`"Español"`/nil.

---

## BUG 3 — Seek lento al arrastrar la barra

Diagnóstico: **no** es el cliente (un solo `onSeek` al soltar, sin re-peticiones) ni diseño de peticiones. Es **motor VLC + orquestación del ViewModel**.

| # | Causa | Evidencia | Mecanismo |
|---|---|---|---|
| 3.1 | **`--network-caching=10000` (10 s)** | `VLCPlaybackEngine.swift:36` | Tras cada seek, libVLC rellena 10 s de buffer → congelón de varios segundos en cada scrub. **Causa dominante** |
| 3.2 | **Retry ciego a los 5 s → doble rebuffer** | `PlayerViewModel.swift:291-306` | Si el seek tarda >5s en aterrizar, se emite un segundo `position=` y se reinicia TODO el buffering |
| 3.3 | **Hasta 10 s de espera de `duration` ANTES de buscar, y si no llega se descarta el seek** | `PlayerViewModel.swift:277-289` | `engine.duration`=0 en HLS temprano → spinner+seek mudo, luego `return` silencioso |
| 3.4 | **Sin coalescing de seeks concurrentes** | `PlayerViewModel.swift:272-313` (sin guard) | ±15 tocado dos veces / swipe + scrub / auto-skip superpuestos → N rebuffers |
| 3.5 | Seek por `position=` sobre HTTP progresivo o URL de transcode | `PlayerViewModel.swift:290`, `DirectPlayer.swift:122-140` | Byte-range seek + recarga de caché; con `transcodingUrl` el transcoder de Jellyfin debe re-sincronizarse |
| 3.6 | UI congelada durante todo el seek | `PlayerViewModel.swift:392-395` (`guard !isSeeking`) | Hasta ~16s sin actualizar tiempo/estado y sin indicador → percepción aún peor |
| 3.7 | Auto-skip puede dispararse 5s tras un scrub al intro | `PlayerViewModel.swift:508-531` + `SegmentMarker.swift:70` | Segundo seek no solicitado |

**Fix de mayor apalancamiento:** bajar `network-caching` (1500-3000ms) → eliminar el retry ciego → seek independiente de `duration` (`time`/`jumpForward`, ya existe `seekRelative` sin usar) → coalescing last-write-wins → spinner de seek + seguir actualizando el timer.

---

## BUG 4 — PiP / volver al inicio / mini-reproductor

### (a) Volver al inicio o cambiar de app corta la reproducción

| # | Causa | Evidencia | Estado |
|---|---|---|---|
| 4.1 | **`onDisappear` siempre para VLC** al cerrar la cover (back/Inicio) | `PlayerView.swift:271-287`; `allowStop` (`:9`) nunca se pone false; PiP solo arranca con `.background` o botón | Confirmado — la navegación mata la reproducción por diseño |
| 4.2 | **PiP falla en silencio** si `hlsURL` aún no resolvió | `PlayerViewModel.swift:913-916` (guard con `return` mudo) | Confirmado |
| 4.3 | La app **nunca configura `AVAudioSession .playback`** (solo lo hace VLCKit por dentro y `PipSession:87-89`) | grep: única ocurrencia en `PipSession.swift` | Confirmado (funciona de forma implícita, frágil) |
| 4.4 | PiP se intenta en `.background` y no en `.inactive` → puede fallar/timeout de 8s | `PlayerView.swift:299-309` | Sospechoso alto |
| 4.5 | **Los callbacks de restore viven en el VM de la vista** → al descartar la cover, `onRestore` muere → el sistema termina el PiP | `PlayerViewModel.swift:998-1013`, `PipSession.swift:308-326` | Confirmado |
| 4.6 | `UIBackgroundModes=audio` **sí está** y cableado | `Apps/iOS/Info.plist:9-12`, `project.yml:65` | No es causa |

### (b) Botón de salir del mini-reproductor

| # | Causa | Evidencia |
|---|---|---|
| 4.7 | **No existe rama de UI para `pipState == .active`** — el botón solo aparece en `.idle` | `PlayerView.swift:566-576` |
| 4.8 | **No existe ningún mini-player en el proyecto** (grep 0 hits) — tras cerrar la cover la app queda sin UI de control del PiP | `ThisJellyFixRootView.swift:17-80` |
| 4.9 | El botón de entrar a PiP se oculta si la resolución HLS falla/lenta, y al pulsarlo los guards salen sin log | `PlayerViewModel:913-923` |

**Fix de mayor apalancamiento:** sesión de reproducción de nivel raíz (no atada a la vista) + barra mini-player en `ThisJellyFixRootView` con expandir (`resumeFromPictureInPicture()`, ya existe sin cablear) y cerrar (`closeAndReport()`); no parar en `onDisappear` si hay sesión activa; `AVAudioSession .playback` en el arranque de la app.

---

## BUGS EXTRA encontrados (fuera de los 4 reportados)

### Altos
- **E1 · Zombi tras descartar**: Tasks sin cancelar en `startPlayback`/`onChange(streamURL)`/`seek` → `engine.play()` tras `stopSync()` → audio fantasma. `PlayerView.swift:69-81,250-266`, `PlayerViewModel.swift:272-313`
- **E2 · Errores de VLC nunca se muestran**: 0 implementaciones de `VLCMediaPlayerDelegate` → pantalla negra permanente sin mensaje. `PlayerViewModel.errorMessage` solo alimentado por `prepareStream`
- **E3 · `directStreamUrl`/`transcodingUrl` relativos no se resuelven** en `DetailView.swift:379-397` y `DirectPlayer.swift:122-146` (el propio test `HlsStreamResolverTests.swift:10` demuestra que llegan relativos) → error o muerte silenciosa
- **E4 · 401 = callejón sin salida**: `restoreSession` no valida token (`AuthModel.swift:67-80`), ninguna vista mapea `.unauthorized` a logout → "Reintentar" con token muerto para siempre
- **E5 · Tokens en logs en texto plano** con fichero sin rotar: `HlsStreamResolver.swift:71`, `PipSession.swift:141`, `JellyfinPlaybackClient.swift:57-79`, `DeviceIdentifier.swift:7-16`

### Medios
- **E6** ATS no configurado → servidores `http://LAN` bloqueados en dispositivo
- **E7** tvOS/visionOS sin Perfil/Búsqueda/logout (`ThisJellyFixRootView.swift:32-46`)
- **E8** visionOS/tvOS sin botón de cierre del reproductor (`PlayerView.swift:541-549` es `#if os(iOS)`)
- **E9** `NavigationStack` anidado en caja de 300pt en Favoritos (`FavoritesView.swift:29`, `ProfileView.swift:36`)
- **E10** Spinner de búsqueda puede quedarse pegado + task no cancelada al salir (`SearchView.swift:123-155`)
- **E11** Keychain `save` = delete-then-add no atómico → pérdida de token si falla (`KeychainStore.swift:32-48`)
- **E12** Siguiente episodio se para en frontera de temporada (`DetailView.swift:428-432`, `DirectPlayer.swift:169-207`)
- **E13** Cierre de PiP puede mandar `PositionTicks:0` y borrar el resume (`PipSession.swift:270-281`)
- **E14** Retry storm de resolución HLS en cada `.inactive` si el server no da HLS (`PlayerViewModel.swift:877-880`)
- **E15** `togglePlayPause` en carrera con el timer de 500ms (`PlayerViewModel.swift:148-155,398`)
- **E16** `deinit` de VLC puede correr off-main (`VLCPlaybackEngine.swift:60-65`)
- **E17** API privada `setValue(_:forKey:"orientation")` → riesgo de rechazo en App Store (`PlayerView.swift:405,422`)
- **E18** Cero tests de Feature/Playback (la URL relativa E3 se habría detectado)

### Bajos
`width=0 → NaN → seek al final` (`PlayerView.swift:712`) · imágenes sin `tag`/ApiKey · `hasImage` vs Thumb/Backdrop · `ContentRow.id = UUID()` rompe identidad · `Image("AppIcon")` vacío en builds SPM · `Assets.xcassets` duplicado por target · `connect()` no persiste / `disconnect()` no limpia servidor · catch silencioso en Favoritos · "Visto recientemente" ordena por `DateCreated` · `components.url!` force-unwrap · timer con delta fijo · timer no invalidado en `deinit` · `refreshResume` con `sleep(2s)` · sin `accessibilityLabel` · `@State` con inits `@MainActor` (error en Swift 6) · `static var drawableAttachCount` con carrera · código muerto (`AVPlaybackEngine`, `allowStop`, `stop()`) · `ChapterClassifier` con match por subcadena.

### Verificado limpio
Conversión ticks↔segundos (10_000_000) correcta en todo el código · sin `try!`/`as!`/`fatalError` · tokens en Keychain y claves consistentes · búsqueda con debounce 300ms y cancelación · sin sondeos síncronos de servidor al arrancar · decodificación JSON off-main · `UIBackgroundModes` presente.

---

## Plan de arreglo por fases

### Fase A — Los 4 bugs reportados (raíz, cambios mínimos)
| Orden | Item | Ficheros | Riesgo | Estado |
|---|---|---|---|---|
| A1 | Subtítulos: fallback a `systemDefault` + nombre→código + idioma del servidor | `PlayerViewModel.swift`, `LanguagePreferences.swift`, `TrackNaming.swift` | Bajo + tests nuevos | ✅ Hecho (8 tests nuevos) |
| A2 | Seek: bajar `network-caching`, quitar retry ciego, seek sin `duration`, coalescing | `VLCPlaybackEngine.swift`, `PlayerViewModel.swift` | Medio (requiere prueba en dispositivo) | ✅ Hecho (pendiente prueba en dispositivo) |
| A3 | Carga: gate + peticiones en paralelo + filas incrementales + `refreshResume` en vez de `load()` | `ThisJellyFixRootView.swift`, `LibraryModel.swift`, `HomeView.swift` | Bajo | ✅ Hecho |
| A4 | PiP: sesión a nivel raíz, no parar en `onDisappear`, botón salir/expandir, `AVAudioSession` | `ThisJellyFixRootView.swift`, `PlayerView.swift`, `PlayerViewModel.swift`, `PipSession.swift` | Alto (reestructuración) | ✅ Hecho (pendiente prueba en dispositivo) |

### Fase B — Bugs altos extra (E1-E5)
| Item | Estado |
|---|---|
| E1 Tasks zombi | ✅ `playbackTask`/`episodeSwapTask` cancelados en `onDisappear` + guards `engineStopped` |
| E2 Errores VLC invisibles | ✅ `VLCStateRelay` (dueño fuerte del delegate débil) → `errorMessage` + `isPlaying=false` |
| E3 URLs relativas sin resolver | ✅ `StreamURLResolver` compartido por `DetailView`, `DirectPlayer`, `HlsStreamResolver` (+7 tests) |
| E4 401 = callejón sin salida | ✅ `LibraryModel.sessionExpired` → Home ofrece "Cerrar sesión" en vez de "Reintentar" |
| E5 Tokens en logs | ✅ `TJFLog` con redacción + fichero con cap 512KB; `JellyfinPlaybackClient` ya no hace `fopen` directo |

### Fase C — Medios/bajos + tests (E6-E18, tabla low)

Cada fase: test fallido → fix mínimo → `swift build && swift test` → verificación en dispositivo.

---

## Estado de la ejecución — 2026-09-25

**Verificación:** `swift build` (macOS) ✅ · `xcodebuild`-style cross-build iOS `arm64-apple-ios17.0` ✅ ·
`swift test` ✅ 106 tests, 0 fallos (73 Core + 33 Networking; 8 subtítulos y 7 de URL son nuevos).

### A4 — qué cambió exactamente (el fix más involucrado)

| Sub-causa | Fix | Fichero |
|---|---|---|
| 4.1 `onDisappear` mataba la reproducción | `handleViewExit()`: si PiP activo → suelta VLC sin reportar stop; si está reproduciendo → **auto-handoff a PiP** y solo para VLC cuando AVPlayer tiene el audio (o al fallar el handoff) | `PlayerViewModel.swift`, `PlayerView.swift: onDisappear` |
| 4.2 PiP falla en silencio sin `hlsURL` | `startPictureInPicture() -> Bool` ahora **resuelve HLS en el momento** si no estaba cacheado y loguea cada guard | `PlayerViewModel.swift` |
| 4.3 Sin `AVAudioSession .playback` | Categoría `.playback/.moviePlayback` al arrancar la app (activación la siguen haciendo los reproductores) | `ThisJellyFixRootView.swift` |
| 4.4 PiP arrancaba en `.background` | Arranque en `.inactive` (antes de que iOS suspenda), `.background` queda como fallback | `PlayerView.swift: scenePhase` |
| 4.5 Restore atado al VM de la vista | **Handlers con registro/desregistro** (`addRestoreHandler`/`addClosedHandler`, LIFO): el VM de la vista se da de baja al desaparecer y el **root conserva uno permanente** que re-presenta el `PlayerView` con stream/título/pistas del `PipSession.Context` | `PipSession.swift`, `ThisJellyFixRootView.swift` |
| 4.7 Sin rama para `pipState == .active` | Botón `pip.exit` → `resumeFromPictureInPicture()` (volver a fullscreen); botón `pip` siempre visible y con retry en el tap | `PlayerView.swift: controles` |
| 4.8 Sin anfitrión de la capa fuera del player | `PipLayerHostView` ahora vive en el root (y `PipSession` es `@Observable` para que el root repinte al activarse) | `ThisJellyFixRootView.swift`, `PlayerView.swift` |
| 4.9 Botón oculto si HLS lento | Ver 4.2 + botón deshabilitado solo si no está reproduciendo | `PlayerView.swift` |

**Pendiente de verificación en dispositivo/servidor** (no reproducible aquí): A2 seek, A3 carga, A4 PiP
(handoff al salir, restore desde la ventana flotante, `.inactive`), E2 (stream inválido → mensaje).

---

## 2ª ronda — síntomas probados en iPhone (2026-09-26)

Dos síntomas reportados tras probar en el dispositivo, más una revisión por
subagente en 2 pasadas (la 2ª verificó a la 1ª) que encontró 3 HIGH / 8 MED /
5 LOW y 12 puntos descartados por no ser defectos reales.

### Síntoma 1 — swipe-up debe abrir PiP solo; botón PiP "exige esperas"

| Causa raíz | Fix |
|---|---|
| `scenePhase == .inactive` arrancaba PiP (centro de notificaciones, Control Centre, capturas, llamadas = falsos positivos: la ventana se abría "sola") | `.inactive` solo hace `warmPictureInPicture()`; el arranque real es en `.background` |
| En `.background` se arrancaba sin comprobar nada: partida pausada → la app reanudaba sola en segundo plano | `guard viewModel.isPlaying` antes de arrancar |
| La cadena de arranque era un `Task {}` suelto: seguía vivo tras volver a primer plano y abría la ventana SOBRE el reproductor, y sobrevivía al desmontaje | `pipLeaveTask` cancelable + `leavingApp` + `guard !Task.isCancelled` + cancelación en `onDisappear` |
| Botón PiP con `.disabled(!isPlaying)`: VLCKit miente (`isPlaying == false` mientras avanza el tiempo) → parecía que "hay que esperar" | `.disabled(!isPlaying && currentTime <= 0)` + spinner `pipStarting` mientras prepara |
| Dos llamadas simultáneas a `startPictureInPicture()` (fondo + salida) pasaban ambas los guards y la perdedora paraba VLC a mitad de handoff | latch síncrono `pipStartInFlight` (`defer` lo libera) |

### Síntoma 2 — "Estás viendo" queda negro / no refleja el progreso

| Causa raíz | Fix |
|---|---|
| Las filas se leían con `refreshResume()` → cooldown 5 s + `isLoading` frenaban el refresh y se quedaba el estado anterior (progreso "perdido") | `refreshResume(force: true)` en los 4 callers de Home |
| El refresh se hacía ANTES de que el POST de stop llegara al servidor → se leía el estado pre-stop y luego el cooldown bloqueaba la corrección | `refreshResumeSoon()` (fuerza con 2 s de retardo) en el closed handler de PiP y en el `onDismiss` de la cover restaurada |
| `PositionTicks: 0` en los reportes = Jellyfin **borra** el resume | guards: no reportar parada/progreso con `ticks > 0` falso |
| Portada sin arte → caja negra | fallback Thumb → Poster en `MareaImageView`/`MediaCardView` |
| La capa PiP era un `.overlay` en el root → caja negra pintada SOBRE Home | host como primer hijo del ZStack, detrás del gradiente opaco |

### Defectos encontrados por las revisiones y su estado

| # | Defecto | Estado |
|---|---|---|
| 1 | Refresco de "Estás viendo" a veces no llega (cooldown) | ✅ forzado + retardo 2 s |
| 2-7, 9-10, 12-13 | (ronda 1) | ✅ verificados como resueltos en la revisión 2 |
| 8 | **Teardown por error dispara auto-PiP**: un fallo de stream desmontaba `PlayerView` y `handleViewExit()` flotaba el episodio roto sobre la pantalla de error | ✅ flag `PlayerTeardown.noteError()` que el padre pone al desmontar por fallo; `onDisappear` lo consume al momento (un parámetro `Bool` no valdría: SwiftUI coescribe el error y el desmonte en el mismo render) |
| 14 | Reapertura de PiP tras cerrar la ventana (se reanudaba solo) | ✅ el closed handler pone `isPlaying = false` |
| 15 | Swipe a la app con la partida **pausada** reanudaba | ✅ `guard viewModel.isPlaying` |
| 16 | `switchToEpisode` sin cancelación (swap pisado) | ✅ guards `Task.isCancelled` en `switchToEpisode`/`prepareStream` |
| 17 | `pipWarmed` no se limpiaba tras fallo de resolve | ✅ reset en el `catch` |
| 18 | Start concurrente | ✅ latch `pipStartInFlight` |
| 19 | Botón PiP deshabilitado por la mentira de VLCKit | ✅ condición con `currentTime` |
| 20 | `hostView == nil` en `attachLayerToHost` fallaba en silencio (= "la ventana nunca aparece") | ✅ log FATAL |
| 21 | `presentedCount` podía quedarse >0 y bloquear restores para siempre | ⚠️ parcial: clamp `max(0, …)`; sin repro |
| 22 | Handlers de PiP no acotados al ítem · restore-failure sin `notifyClosed` · sin `DidPlayToEndTime` · API `canStartPictureInPictureAutomaticallyFromInline` (App Store) | ⚠️ abiertos (LOW) |

**Verificación 2026-09-26:** `swift build` ✅ · cross-build iOS
`arm64-apple-ios17.0` ✅ · `swift test` ✅ 106 tests, 0 fallos.

**Sigue sin reproducirse aquí:** la franja izquierda estrecha del screenshot
(candidatos: relayout por `forceLandscape`/`restoreOrientation` con ancho de
landscape dentro de ventana portrait, o el `Color.black` a pantalla completa de
`DirectPlayer` en el path de error) → hace falta repro/foto nueva.

---

## 3ª ronda — 2 síntomas nuevos (2026-09-26)

### Síntoma 3 — "salgo de la app y no me persigue; el botón continúa con la imagen bloqueada"

Diagnóstico (revisión estática de TODO el pipeline PiP, dos subagentes independientes):

| Causa raíz | Fix |
|---|---|
| El arranque en `.background` estaba tras `guard viewModel.isPlaying` **sin log**: VLCKit puede reportar `false` mientras avanza el tiempo → guard fallaba en silencio y la ventana nunca se abría | Gate nuevo `canAutoHandoffToPiP` = `PiPHandoffPolicy` (Core, **8 tests**): `isPlaying` **o** posición entre inicio y fin, salvo que el usuario hubiera pausado (`userPaused`). Cada rama del scenePhase y del skip se loguea |
| Arranque frío de la playlist en `.background` podía superar la suspensión del proceso (3 GETs con timeout de 5 s) | `beginBackgroundTask("tjf.pipHandoff")` con `defer { endBackgroundTask }` alrededor de la cadena warm→start |
| **VLC se congelaba al ponerse listo el item AÚN SIN ventana del sistema**: si el start fallaba después, pantalla congelada + audio en manos de nadie = "imagen bloqueada" | Invariante nuevo: `onVideoReady` (congelar VLC y ceder audio) SOLO se dispara con `maybeHandoffOver()` = item listo **y** seek terminado **y** `didStart` de la ventana |
| El recovery de un start fallido dependía de `pipState == .active`, que una carrera (resume/closed) podía poner a `.idle` → VLC congelado para siempre | Rama de fallo: si no hay ventana del sistema (`!PipSession.shared.isActive`) → `engine.play() + isPlaying + startUpdating()` siempre |
| `isPictureInPicturePossible` **nunca se leía** (controlador recién creado puede tardar en ponerse a `true` → `failedToStart` en seco) | Espera de hasta 1.5 s por `possible == true` antes de llamar al sistema (con guard anti-hang si la sesión se cierra durante la espera) + log con `possible`, `appState` y tamaño de la capa |
| Ciegas de log: transiciones de scenePhase, gates, bounds del host, estado del item — un repro en dispositivo no decía nada | Logs añadidos: scenePhase, skip del gate, `host.bounds`, `possible`, `item ready`, handoff confirmado, item sin listo a 12 s, `didStart` perdido con `possible` |
| (Evidencia) no había forma de sacar el log del dispositivo | **Perfil → Diagnóstico → "Compartir registro de reproducción"** (`ShareLink` sobre `tjf_playback.log`, sin secretos, cap 512 KB) |

### Síntoma 4 — "Estás viendo" sin series empezadas en otra aplicación

El endpoint **ya es transversal** (`GET /Users/{id}/Items/Resume?IncludeItemTypes=Movie,Episode`, ordenado por `DatePlayed desc`, datos del servidor) y no hay ningún filtro cliente que quite episodios. El problema es de **frescura**:

| Causa raíz | Fix |
|---|---|
| Al volver de otra app (u otro cliente), Home sigue montado → **no hay ningún `onAppear`**, así que la fila nunca se refrescaba con el progreso hecho fuera | `onChange(of: scenePhase)` en el root: `.active` → `refreshResume()` |
| Un request fallido quemaba el cooldown (sellado antes del `await`) → el siguiente trigger natural se descartaba en silencio y la fila se quedaba vieja | En el `catch`: `lastResumeRefresh = nil` |
| `URLSession` podía servir la fila desde caché HTTP | Resume con `.reloadIgnoringLocalCacheData` |

Si tras estos fixes la fila sigue sin mostrarlos **con la app recién abierta**, el problema es del servidor (item marcado `Played` al 90 % en el otro cliente → ya no es resumible y no hay fallback `/Shows/NextUp`) — pendiente de confirmar con el usuario.

**Verificación 2026-09-26 (ronda 3):** `swift build` ✅ · cross-build iOS ✅ · `swift test` ✅ **114 tests, 0 fallos** (8 nuevos de `PiPHandoffPolicy`).

### Revisión del lote de la 3ª ronda (1 HIGH / 5 MED / 4 LOW → todos corregidos)

| # | Hallazgo | Fix |
|---|---|---|
| H1 | Tras CERRAR la ventana flotante, el `onDisappear` volvía a abrir PiP (el nuevo gate por posición superaba la protección que daba `isPlaying == false`) | `handleViewExit` exige `!pipSessionReportedStop` (se reinicia en cada ítem nuevo) |
| M1 | El unfreeze de un start fallido podía reanimar un engine ya detenido en el path de abort | `else if !isActive, !engineStopped` |
| M2 | El fast path `isPlaying` ignoraba `userPaused` (timer de VLCKit con 0,5 s de retardo tras el tap de pausa) | `guard !userPaused` antes de todo |
| M3 | Episodio terminado podía flotar (últimos 1,5 s) | umbral `position >= duration - 1.5` (el mismo del natural end) |
| M4 | `beginBackgroundTask` sin expiration handler: riesgo de terminación si la cadena supera ~30 s | handler que suelta `leavingApp` y termina la tarea |
| M5 | La tarea de background terminaba en `didStart`, antes de que el item estuviera listo (ventana negra si VLC no daba audio) | tarea propia de `PipSession` desde el call del sistema hasta `maybeHandoffOver()`/`cleanup()` |
| L1 | `player.play()` quedaba tras un `guard let notify` (ventana abierta congelada si el callback era nil) | notify y play desacoplados |
| L2 | El watchdog de 12 s sobrevivía al `cleanup()` y podía dar un falso alarm | `DispatchWorkItem` cancelado en `cleanup()` |
| L3 | El `Task` cancelado (vuelta a primer plano) no abortaba un start en vuelo | `!Task.isCancelled` en la espera + `cleanup()` antes de la llamada al sistema |
| L4 | Un fallo tardío borraba el sello de cooldown de un refresh concurrente ya exitoso | clear comparativo (`== stampedAt`) |

Verificación: `swift build` ✅ · cross-build iOS ✅ · `swift test` ✅ **117 tests, 0 fallos** (11 de `PiPHandoffPolicy`).

## Ronda 4 — 2026-09-27 (log extraído del dispositivo vía `devicectl device copy from`)

Evidencia: `tmp/tjf_playback.log` copiado directamente del iPhone (sin intervención del usuario).

### "Estás viendo" no aparece NUNCA → causa raíz en el servidor, no en el cliente

Toda la evidencia del log: `load: Estás viendo items=0` y `refreshResume items=0` **siempre**, con la tubería cliente sana (`Sessions/Playing` → 204, `Progress` → 204, `Stopped` con `PositionTicks=61260000` → 204, sin `refreshResume FAILED`, mismo `JellyfinItemsResponse` que sí devuelve 13 series). El server **devuelve `Items: []` legítimamente**.

Causa raíz (código de Jellyfin, `Emby.Server.Implementations/Library/UserDataManager.cs:439`):

```csharp
if (pctIn < _config.Configuration.MinResumePct)        // default = 5 (%)
    positionTicks = 0;                                 // "ignore progress during the beginning"
...
if (durationSeconds < _config.Configuration.MinResumeDurationSeconds)  // default = 300 s
    positionTicks = 0;
```

La única sesión del log: **6,1 s de 1452 s = 0,4 %** → por debajo de `MinResumePct=5` → el servidor descarta la posición → `UserData.PlaybackPositionTicks = 0` → la consulta `IsResumable=true` (`TranslateQuery.cs:562`, exige `PlaybackPositionTicks > 0`) no lo devuelve. La película del 06:40 salió a los 1 s (sin progreso reportado, guards `position=0` funcionando) → tampoco.

Conclusión: para que la fila aparezca hay que superar el 5 % de duración (o ver ≥5 min de un ítem < 300 s... no: ese caso se marca `Played`). Pendiente de verificación empírica: ver >1-2 min en la app y comprobar `refreshResume items=N`; y comparar con "Continue Watching" en Jellyfin Web (si Web muestra ítems y la app no → seguimos aquí).

### Swipe-up no abre PiP → `startPictureInPicture()` llamado con `possible == false`

Log (06:40, salida de reproductor en background):

```
pip: system possible=false waited=1500ms state=2
pip: item ready (window started=false)
pip: didStart never arrived → cancelling (possible=true)
pip: start result=false
```

`AVPictureInPictureController.startPictureInPicture()` con `isPictureInPicturePossible == false` es un **no-op silencioso** (sin error, sin delegate, sin retry). En frío (HLS) `possible` solo se pone `true` cuando el item está listo (~10 s); el viejo budget de espera era 1,5 s → se llamaba en falso y nadie volvía a llamar cuando `possible` se ponía `true`. El botón funcionaba porque en primer plano `possible` se pone `true` dentro de esos 1,5 s.

Fix: espera de `isPictureInPicturePossible` hasta **15 s** (cubierta por la background lease de `PipSession` + `tjf.pipHandoff`), con log cada 2 s, y llamada al sistema SOLO con `possible == true` — el mismo estado en que funciona el botón. La cancelación del caller (vuelta a primer plano) sigue ganando al instante.

Otro hallazgo del log: la sesión de las 17:21 canceló a los 1 s porque el usuario volvió antes de que arrancara el pipeline — la ventana tarda varios segundos en frío; hay que esperar ~3-5 s tras deslizar.

### Borrado de progreso (refuerzo, ronda 4a)

- Choke point en `JellyfinPlaybackClient`: `positionTicks <= 0` → skip en `reportProgress`/`reportStopped` (PositionTicks:0 hace Jellyfin descartar el resume).
- `PipSession.tick` con el mismo guard.
- Handoff PiP en `max(currentTime, pendingResumePosition)` — si el seek de VLC no ha aterrizado, se entrega en la posición guardada.
- `refreshResume` loguea `ids=…:tipo:segundos`.

**Verificación 2026-09-27:** `xcodebuild` iOS (scheme `thisjellyfix-iOS`, tu iPhone) → **BUILD SUCCEEDED** → instalada vía `devicectl`. `swift build`/`swift test` **bloqueados por `ThisJellyFixDiscovery`** (módulo en desarrollo paralelo: `ArrClients.swift` + `ArrClientTests`) — no tocado.

### Ronda 4b — 2026-09-27 (log 09:36-09:42)

**#1 (fila):** sesión completa del usuario: **9,2 s** de 1452 s (09:42:16→09:42:29). Otras: 6,1 s y 1 s. Todas por debajo de `MinResumePct=5 %` = **73 s** para este episodio → el servidor descarta, correctamente y igual que cualquier cliente oficial. Todavía NO se ha hecho ninguna sesión ≥5 %. Añadido `resume raw (Nb): …` en `fetchResumeItems` para ver el JSON exacto del servidor en el próximo log.

**#2 (PiP al salir):** el usuario volvió a la app a los **2 s** (`waiting… 2000ms` → `inactive` → `start cancelled by caller`). Además `HlsResolver: warm failed — -1011` (HTTP 5xx: el transcode aún no estaba listo) y **el flag `pipWarmed` se ponía `true` ANTES del fetch** → un warm fallido dejaba la sesión "calentada" en falso y todo handoff posterior arrancaba en frío (ventana a ~10 s). Fixes:
- `warmUp` → 3 intentos con 1,5 s de espera, log de paso + HTTP status, devuelve `Bool`.
- `pipWarmed` solo se marca en éxito → el siguiente trigger reintenta.
- (ya en 4a) espera de `possible` hasta 15 s antes de llamar al sistema.

Pendiente: **test con espera** — deslizar y esperar ~10 s sin volver; y sesión ≥75 s para la fila.
