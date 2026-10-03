# Migración VLC → AVPlayer — checklist de ejecución

- [ ] 1. Core: `SRTParser` + `SubtitleCue` + `AVPlayerCapability` (ladder direct-play) + `PlaybackDeviceProfile.avPlayer` + tests
- [ ] 2. Networking: `StreamURLResolver` ladder por capacidad + tests; call sites pasan profile `.avPlayer`
- [ ] 3. Playback: protocolo ampliado (`seekRelative`, `setVideoFill`, `stopSync`, `videoSize`, state callbacks, `renderingLayer`, subs) + `AVPlaybackEngine` completo + borrar `VLCPlaybackEngine`
- [ ] 4. Feature: `PlayerViewModel` desacoplado (sin VLCKit, PiP nativo AVPlayer, sin PipSession/PipPreload) + `PlayerView` bridge `AVPlayerLayer` + overlay subtítulos + root view slim
- [ ] 5. Borrar `PipSession.swift`, `PipPreload.swift`, `HlsStreamResolver`(+tests); fix E8 (close tvOS/visionOS), E17 (KVC orientation)
- [ ] 6. Config: `Package.swift` + `project.yml` sin VLCKit; xcodegen
- [ ] 7. Verificación: `swift build`, `swift test`, xcodebuild 4 plataformas
