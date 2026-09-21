# Estrategia de compatibilidad

Thisjellyfix elegirá siempre la ruta menos costosa que reproduzca correctamente el contenido:

1. reproducción nativa;
2. remux/direct stream de Jellyfin;
3. conversión de audio o subtítulos;
4. transcodificación de vídeo HLS;
5. motor universal integrado si evita una conversión.

El contrato `PlaybackEngine` permite implementar un motor AVFoundation y otro universal sin cambiar las pantallas ni el reporte de progreso Jellyfin. La selección real deberá usar `PlaybackInfo`, el perfil del dispositivo, la salida de audio, HDR y las pistas de subtítulos disponibles.

No se añadirá un motor universal a distribución hasta que una prueba técnica confirme: soporte por plataforma, tamaño de binario, reproducción de ASS/PGS/DTS/AV1, integración con AirPlay y cumplimiento de licencia.
