import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Reproductor de alertas para la PWA en iPhone.
///
/// Safari solo deja sonar un elemento de audio que se activó con un toque del
/// usuario. Por eso se usa UN solo `<audio>` durante toda la sesión: se activa
/// en el primer toque en cualquier parte de la app y después se reutiliza
/// cambiando el archivo. Además se pide la sesión de audio "playback" (Safari
/// 16.4+) para que la alerta no quede muda con el interruptor de silencio.
class WebAlertAudio {
  WebAlertAudio._();

  static web.HTMLAudioElement? _element;
  static bool _unlocked = false;
  static bool _listening = false;

  static bool get supported => true;
  static bool get unlocked => _unlocked;

  static web.HTMLAudioElement get _audio => _element ??= () {
    final element = web.HTMLAudioElement()
      ..preload = 'auto'
      ..setAttribute('playsinline', 'true');
    element.style.display = 'none';
    web.document.body?.append(element);
    return element;
  }();

  /// Clip WAV de 0,1 s de silencio. Desbloquear con audio real sin silenciar
  /// es lo que Safari cuenta como permiso; el clip no se oye.
  static final String _silentClip = () {
    const sampleRate = 8000;
    const samples = 800;
    final bytes = BytesBuilder();
    void u32(int v) =>
        bytes.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255]);
    void u16(int v) => bytes.add([v & 255, v >> 8 & 255]);
    bytes.add(ascii.encode('RIFF'));
    u32(36 + samples);
    bytes.add(ascii.encode('WAVEfmt '));
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate);
    u16(1);
    u16(8);
    bytes.add(ascii.encode('data'));
    u32(samples);
    bytes.add(List<int>.filled(samples, 128));
    return 'data:audio/wav;base64,${base64Encode(bytes.toBytes())}';
  }();

  /// Las rutas de Flutter Web quedan en assets/assets/...
  static String _url(String assetPath) => 'assets/assets/$assetPath';

  static void _useLoudAudioSession() {
    try {
      final navigator = web.window.navigator as JSObject;
      final session = navigator.getProperty<JSObject?>('audioSession'.toJS);
      session?.setProperty('type'.toJS, 'playback'.toJS);
    } catch (_) {
      // Safari anterior a 16.4: el audio sigue sonando con el timbre activo.
    }
  }

  /// Activa el audio con el primer toque en cualquier parte de la PWA.
  static void installGestureUnlock(void Function() onUnlocked) {
    if (_listening || _unlocked) return;
    _listening = true;
    late final JSFunction handler;
    handler = ((web.Event _) {
      if (unlockNow()) {
        for (final type in const [
          'touchend',
          'pointerup',
          'click',
          'keydown',
        ]) {
          web.document.removeEventListener(type, handler);
        }
        _listening = false;
        onUnlocked();
      }
    }).toJS;
    for (final type in const ['touchend', 'pointerup', 'click', 'keydown']) {
      web.document.addEventListener(type, handler);
    }
  }

  /// Debe llamarse dentro de un toque (sin await antes): reproduce en silencio
  /// y pausa, lo que deja el elemento habilitado para sonar después.
  static bool unlockNow([String? _]) {
    if (_unlocked) return true;
    try {
      _useLoudAudioSession();
      final audio = _audio
        ..muted = false
        ..src = _silentClip;
      final promise = audio.play();
      _unlocked = true;
      unawaited(
        promise.toDart
            .then((_) {
              audio.pause();
            })
            .catchError((Object _) {
              _unlocked = false;
            }),
      );
      return true;
    } catch (_) {
      _unlocked = false;
      return false;
    }
  }

  /// Reproduce la alerta [repeat] veces seguidas.
  static Future<bool> play(String assetPath, {int repeat = 1}) async {
    if (!_unlocked) return false;
    try {
      _useLoudAudioSession();
      final audio = _audio
        ..muted = false
        ..volume = 1
        ..src = _url(assetPath);
      for (var i = 0; i < repeat; i++) {
        audio.currentTime = 0;
        await audio.play().toDart;
        if (i < repeat - 1) {
          await audio.onEnded.first.timeout(
            const Duration(seconds: 6),
            onTimeout: () => web.Event('ended'),
          );
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
