# thisjellyfix

Cliente Jellyfin nativo para los sistemas Apple, con una experiencia cinematográfica propia llamada **La Marea**.

## Estado inicial

La base actual contiene cuatro aplicaciones SwiftUI (iOS, iPadOS mediante el destino iOS, macOS, tvOS y visionOS) y módulos compartidos para dominio, conexión Jellyfin, interfaz y reproducción. El primer flujo valida una URL con `System/Info/Public` y muestra el servidor encontrado; todavía no guarda credenciales ni reproduce medios.

## Abrir el proyecto

1. Instala [XcodeGen](https://github.com/yonaskolb/XcodeGen) si no está disponible.
2. Ejecuta `xcodegen` en la raíz.
3. Abre `thisjellyfix.xcodeproj` y ejecuta el destino que corresponda a tu dispositivo o simulador.

## Límites intencionados de esta entrega

- Sin inicio de sesión todavía: evita almacenar o tratar tokens antes de definir el flujo de Keychain.
- Sin reproductor todavía: `PlaybackEngine` es el límite estable que permitirá implementar AVFoundation y el motor universal sin acoplar la interfaz.
- Sin dependencias externas: la prueba de compatibilidad decidirá el motor universal y su estrategia de licencia.
