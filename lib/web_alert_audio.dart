// Audio de alertas para la PWA (Safari en iPhone). En Android y en pruebas se
// usa la implementación vacía y la app sigue con audioplayers.
export 'web_alert_audio_stub.dart'
    if (dart.library.js_interop) 'web_alert_audio_web.dart';
