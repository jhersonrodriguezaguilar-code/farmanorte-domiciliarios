/// Fuera del navegador no hay nada que hacer: la APK usa audioplayers.
class WebAlertAudio {
  WebAlertAudio._();

  static bool get supported => false;
  static bool get unlocked => true;

  static void installGestureUnlock(void Function() onUnlocked) {}

  static bool unlockNow([String? assetPath]) => true;

  static Future<bool> play(String assetPath, {int repeat = 1}) async => false;
}
