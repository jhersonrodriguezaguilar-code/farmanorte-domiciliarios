import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // Precalienta el cliente mientras se pinta el login. La autenticación real
  // sigue siendo obligatoria, pero ya no espera a que el usuario toque el
  // botón para inicializar Supabase por primera vez.
  unawaited(SupabaseOperationsService.instance.initialize());
  unawaited(_startNotifications());
  runApp(const FarmaNorteApp());
}

/// Carga el sonido elegido antes de crear los canales Android, para que el
/// canal del sonido seleccionado exista desde el arranque.
Future<void> _startNotifications() async {
  try {
    await AppNotificationAudio.initialize();
  } catch (_) {}
  await BackgroundNotificationService.initialize();
}

class AppColors {
  AppColors._();
  // FarmaNorte: azul de marca sobre superficies blancas y azul muy claro.
  // El cambio vive en estos tokens para conservar la estructura actual de la app.
  static const primary = Color(0xFF003399);
  static const primaryDark = Color(0xFF002875);
  static const mint = Color(0xFFEDF4FF);
  static const ink = Color(0xFF14212B);
  static const muted = Color(0xFF6D7B86);
  static const canvas = Color(0xFFF4F7FC);
  static const line = Color(0xFFDCE6F3);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFE55353);
  // Estados: verde solo para entregado, ámbar solo para pendientes.
  static const success = Color(0xFF17784F);
  static const successSoft = Color(0xFFE3F4EC);
  static const blue = Color(0xFF4E7FD0);
  static const pharmacyBlue = Color(0xFF003399);
  static const pharmacyBlueDeep = Color(0xFF003399);
  static const pharmacyBlueSoft = Color(0xFFEDF4FF);
  static const pharmacyCanvas = Color(0xFFF3F7FC);
  // Secondary blue for purchase states; avoids introducing a purple accent.
  static const violet = Color(0xFF6688C9);
}

class MapsConfig {
  MapsConfig._();
  static const apiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  static const hasApiKey =
      apiKey != '' && apiKey != 'REPLACE_WITH_GOOGLE_MAPS_API_KEY';
  static const monteria = LatLng(8.7575, -75.8857);
}

const farmanorteBrandName = 'farmanorte';
const farmanorteSupportName = 'Andrés Vargas';
const farmanorteSupportPhone = '3045530618';

class CourierAlertSoundOption {
  const CourierAlertSoundOption({
    required this.id,
    required this.label,
    required this.description,
    required this.assetPath,
    required this.androidRawSound,
  });

  final String id;
  final String label;
  final String description;
  final String assetPath;

  /// Copia del sonido en `android/app/src/main/res/raw`. Los canales de
  /// Android solo pueden sonar con recursos nativos, no con assets de Flutter.
  final String androidRawSound;
}

const courierAlertSoundOptions = <CourierAlertSoundOption>[
  CourierAlertSoundOption(
    id: 'fast_ping',
    label: 'Fast ping',
    description: 'Tono enviado para las alertas nuevas.',
    assetPath: 'sounds/fast-ping-notification.mp3',
    androidRawSound: 'fast_ping_notification',
  ),
  CourierAlertSoundOption(
    id: 'delivery_alert',
    label: 'Alerta de domicilio',
    description: 'Tono de operación de farmanorte.',
    assetPath: 'sounds/delivery-alert.mp3',
    androidRawSound: 'delivery_alert',
  ),
  CourierAlertSoundOption(
    id: 'message_alert',
    label: 'Mensaje',
    description: 'Tono corto para chat nuevo.',
    assetPath: 'sounds/message-alert.mp3',
    androidRawSound: 'message_alert',
  ),
  CourierAlertSoundOption(
    id: 'koiroylers_shop',
    label: 'Tienda',
    description: 'Tono alternativo para un domicilio nuevo.',
    assetPath: 'sounds/koiroylers-shop-notification-355746.mp3',
    androidRawSound: 'koiroylers_shop_notification',
  ),
  CourierAlertSoundOption(
    id: 'akshai_orders',
    label: 'Pedidos',
    description: 'Tono alternativo para alertas de pedidos nuevos.',
    assetPath: 'sounds/akshai26-notification-for-orders-313025.mp3',
    androidRawSound: 'akshai_orders_notification',
  ),
];

class AppNotificationAudio {
  AppNotificationAudio._();

  static final AudioPlayer _player = AudioPlayer();
  static const _preferenceKey = 'courier_alert_sound_id';
  static const _enabledPreferenceKey = 'courier_alert_sound_enabled';
  static const _volumePreferenceKey = 'courier_alert_sound_volume';
  static String _selectedSoundId = 'fast_ping';
  static bool _enabled = true;
  static double _volume = .8;

  static bool get enabled => _enabled;
  static double get volume => _volume;

  static CourierAlertSoundOption get selectedSound =>
      courierAlertSoundOptions.firstWhere(
        (option) => option.id == _selectedSoundId,
        orElse: () => courierAlertSoundOptions.first,
      );

  static CourierAlertSoundOption soundById(String id) =>
      courierAlertSoundOptions.firstWhere(
        (option) => option.id == id,
        orElse: () => courierAlertSoundOptions.first,
      );

  static final Map<String, DateTime> _recentAlerts = {};
  static const _alertDedupeWindow = Duration(seconds: 30);

  /// Evita que el mismo domicilio suene dos veces cuando la app está abierta
  /// (una vez por el push y otra por la escucha en tiempo real). Devuelve
  /// `true` solo para el primer aviso de esa clave dentro de la ventana.
  static bool claimAlert(String key) {
    final now = DateTime.now();
    _recentAlerts.removeWhere(
      (_, at) => now.difference(at) > _alertDedupeWindow,
    );
    if (_recentAlerts.containsKey(key)) return false;
    _recentAlerts[key] = now;
    return true;
  }

  /// Suena una sola vez aunque el push y el tiempo real lleguen juntos.
  static Future<void> playDeliveryAlertFor(
    Iterable<String> deliveryIds, {
    required bool assigned,
  }) {
    var firstTime = false;
    for (final id in deliveryIds) {
      final kind = assigned ? 'assigned' : 'newDelivery';
      if (claimAlert('delivery:$kind:$id')) firstTime = true;
    }
    return firstTime ? playDeliveryAlert() : Future.value();
  }

  static CourierAlertSoundOption get messageSound =>
      courierAlertSoundOptions.firstWhere(
        (option) => option.id == 'message_alert',
        orElse: () => courierAlertSoundOptions.first,
      );

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    _selectedSoundId = preferences.getString(_preferenceKey) ?? 'fast_ping';
    _enabled = preferences.getBool(_enabledPreferenceKey) ?? true;
    _volume = (preferences.getDouble(_volumePreferenceKey) ?? .8)
        .clamp(.1, 1.0)
        .toDouble();
  }

  static Future<void> selectSound(String id) async {
    final option = courierAlertSoundOptions.firstWhere(
      (candidate) => candidate.id == id,
      orElse: () => courierAlertSoundOptions.first,
    );
    final changed = _selectedSoundId != option.id;
    _selectedSoundId = option.id;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferenceKey, option.id);
    // El sonido de un canal Android es fijo: al cambiarlo se crean los
    // canales del nuevo sonido para que también suene con la app cerrada.
    if (changed) unawaited(BackgroundNotificationService.applySelectedSound());
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledPreferenceKey, value);
  }

  static Future<void> setVolume(double value) async {
    _volume = value.clamp(.1, 1.0).toDouble();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_volumePreferenceKey, _volume);
  }

  static bool _webAudioUnlocked = false;

  /// iPhone bloquea el audio de la PWA hasta que suene algo dentro de un
  /// toque. Se llama al iniciar sesión y al tocar "Activar" para que las
  /// alertas con la app abierta suenen después.
  static void unlockForWeb() {
    if (!kIsWeb || _webAudioUnlocked) return;
    _webAudioUnlocked = true;
    unawaited(() async {
      try {
        await _player.play(AssetSource(selectedSound.assetPath), volume: 0);
        await _player.stop();
      } catch (_) {
        _webAudioUnlocked = false;
      }
    }());
  }

  static Future<void> playDeliveryAlert() => _play(selectedSound.assetPath);

  static Future<void> playMessageAlert() => _play(messageSound.assetPath);

  static Future<void> preview(String id) async {
    final option = courierAlertSoundOptions.firstWhere(
      (candidate) => candidate.id == id,
      orElse: () => courierAlertSoundOptions.first,
    );
    await _play(option.assetPath, vibrate: false, force: true);
  }

  static Future<void> _play(
    String assetPath, {
    bool vibrate = true,
    bool force = false,
  }) async {
    if (!_enabled && !force) return;
    try {
      await _player.stop();
      await _player.setVolume(_volume);
      await _player.play(AssetSource(assetPath), volume: _volume);
      if (vibrate) await HapticFeedback.mediumImpact();
    } catch (_) {
      // La alerta visual y el flujo operativo siguen funcionando si el audio
      // está silenciado o la plataforma no tiene salida de sonido.
    }
  }
}

const courierBasePharmacyCode = String.fromEnvironment(
  'FARMANORTE_BASE_PHARMACY_CODE',
);
String get courierBaseLabel => courierBasePharmacyCode.isEmpty
    ? 'Punto base pendiente de asignación'
    : 'FN $courierBasePharmacyCode';

String normalizeAuthIdentifier(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.contains('@') ? normalized : '$normalized@farmanorte.local';
}

String formatPharmacyDisplay(String code) {
  final normalized = code.trim();
  final compactCode = normalized.toUpperCase().startsWith('FN ')
      ? normalized.substring(3).trim()
      : normalized;
  return compactCode.isEmpty ? 'farmanorte' : 'farmanorte $compactCode';
}

String formatPharmacyCodeLabel(dynamic code) {
  final normalized = '$code'.trim();
  if (normalized.isEmpty || normalized == 'null') return 'FN';
  final compactCode = normalized.toUpperCase().startsWith('FN ')
      ? normalized.substring(3).trim()
      : normalized;
  return 'FN ${compactCode.toUpperCase()}';
}

String formatDeliveryPublicCode(dynamic value) {
  final raw = '$value'.trim();
  if (raw.isEmpty || raw == 'null') return '';
  final compact = raw.toUpperCase().replaceAll(RegExp(r'[\s_-]+'), '');
  return RegExp(r'^FN\d{4,}$').hasMatch(compact) ? compact : raw.toUpperCase();
}

class FirebaseConfig {
  FirebaseConfig._();

  // La configuración cliente web de Firebase (API key, app ID, sender y
  // project ID) es pública por diseño; la autorización depende de Auth/RLS.
  // La clave privada FCM nunca se incluye aquí: vive solo en Supabase Secrets.
  static const webApiKey = 'AIzaSyDWuuoCCc430zTLnsi5zTJYSLhYCwcYdCc';
  static const webAppId = '1:348754050469:web:b265fc86d2172127a73c4c';
  static const commonApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  // Configuración pública de la aplicación Android registrada en Firebase.
  // También puede reemplazarse en una compilación mediante --dart-define.
  static const androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
    defaultValue: 'AIzaSyBxHp_5Wg9QAovkvQlavbyWQ_iklhFBieQ',
  );
  static const iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const commonAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
    defaultValue: '1:348754050469:android:debae16e4f6cd842a73c4c',
  );
  static const iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const webVapidKey = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');
  static const messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '348754050469',
  );
  static const projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'farmanorte-notificaciones',
  );
  static const databaseUrl = String.fromEnvironment('FIREBASE_DATABASE_URL');

  static String get apiKey => kIsWeb
      ? webApiKey
      : defaultTargetPlatform == TargetPlatform.iOS
      ? (iosApiKey.isEmpty ? commonApiKey : iosApiKey)
      : (androidApiKey.isEmpty ? commonApiKey : androidApiKey);

  static String get appId => kIsWeb
      ? webAppId
      : defaultTargetPlatform == TargetPlatform.iOS
      ? (iosAppId.isEmpty ? commonAppId : iosAppId)
      : (androidAppId.isEmpty ? commonAppId : androidAppId);

  static bool get isConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty &&
      databaseUrl.isNotEmpty;

  static bool get messagingConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
    databaseURL: databaseUrl.isEmpty ? null : databaseUrl,
  );
}

class PushNotificationAction {
  const PushNotificationAction({
    required this.type,
    required this.deliveryId,
    this.openChat = false,
  });

  final String type;
  final String deliveryId;
  final bool openChat;
}

class AppNotificationNavigation {
  AppNotificationNavigation._();

  static final pending = ValueNotifier<PushNotificationAction?>(null);

  static void publish(PushNotificationAction? action) {
    if (action == null || action.deliveryId.trim().isEmpty) return;
    pending.value = action;
  }
}

/// Recepción push para cuando la APK está minimizada o el proceso fue cerrado
/// normalmente. El sistema operativo sigue siendo quien decide cuándo puede
/// despertar la app: una detención forzada desde Ajustes no puede saltarse.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!FirebaseConfig.messagingConfigured) return;
  // Si el mensaje trae el bloque `notification`, Android ya lo mostró en la
  // bandeja con el canal indicado por el servidor. Mostrarlo otra vez desde
  // aquí generaba una segunda notificación duplicada.
  if (message.notification != null) return;
  try {
    await AppNotificationAudio.initialize();
  } catch (_) {}
  await BackgroundNotificationService.initialize(listenForMessages: false);
  await BackgroundNotificationService.showRemoteMessage(
    message,
    foreground: false,
  );
}

enum NotificationPermissionStatus { unknown, granted, denied }

enum PushAlertKind { newDelivery, assigned, chat }

class BackgroundNotificationService {
  BackgroundNotificationService._();

  static final _localNotifications = FlutterLocalNotificationsPlugin();

  /// Estado del permiso del sistema. La interfaz lo usa para mostrar el aviso
  /// "Activa las notificaciones" con acceso directo a los ajustes del sistema.
  static final permissionStatus = ValueNotifier<NotificationPermissionStatus>(
    NotificationPermissionStatus.unknown,
  );

  static Future<bool>? _initializing;
  static bool _firebaseReady = false;
  static bool _localReady = false;
  static bool _listenersAttached = false;
  static bool _launchDetailsHandled = false;
  static StreamSubscription<RemoteMessage>? _foregroundSubscription;
  static StreamSubscription<RemoteMessage>? _openedSubscription;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static String? _registeredToken;
  static bool _askedThisSession = false;
  static Future<bool>? _permissionRequestInFlight;

  static const _notificationIcon = 'ic_notification';

  // Canales v3. Los canales v2 se crearon con un sonido `res/raw` que el
  // reductor de recursos había eliminado del APK, por lo que quedaron sin
  // sonido válido; Android no permite corregir un canal existente, así que se
  // eliminan y se reemplazan. El id incluye el sonido elegido porque el sonido
  // de un canal tampoco se puede cambiar después de creado.
  static const _legacyChannelIds = [
    'farmanorte_operations_v2',
    'farmanorte_messages_v2',
  ];
  static const defaultSoundId = 'fast_ping';
  static const chatChannelId = 'fn_chat_v3';
  static const silentChannelId = 'fn_silent_v3';

  /// Debe coincidir con `default_notification_channel_id` del
  /// AndroidManifest: es el canal que usa Android cuando el servidor envía un
  /// canal que no existe en el teléfono.
  static const defaultChannelId = 'fn_new_delivery_fast_ping_v3';

  static String newDeliveryChannelId(String soundId) =>
      'fn_new_delivery_${soundId}_v3';

  static String assignedChannelId(String soundId) =>
      'fn_assigned_${soundId}_v3';

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> initialize({bool listenForMessages = true}) {
    if (!FirebaseConfig.messagingConfigured) return Future.value(false);
    if (_firebaseReady &&
        _localReady &&
        (!listenForMessages || _listenersAttached)) {
      return Future.value(true);
    }
    final current = _initializing;
    if (current != null) return current;
    final initialization = _initialize(listenForMessages: listenForMessages);
    _initializing = initialization;
    return initialization.whenComplete(() => _initializing = null);
  }

  static Future<bool> _ensureFirebase() async {
    if (_firebaseReady) return true;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: FirebaseConfig.options);
      }
      _firebaseReady = true;
    } catch (error) {
      try {
        Firebase.app();
        _firebaseReady = true;
      } catch (_) {
        debugPrint('Notificaciones: Firebase no se pudo inicializar: $error');
      }
    }
    return _firebaseReady;
  }

  static Future<bool> _initialize({required bool listenForMessages}) async {
    if (!await _ensureFirebase()) return false;

    // 1. Escuchas de FCM. Van primero y no dependen de las notificaciones
    // locales: antes, un fallo del ícono impedía registrar la apertura al
    // tocar la notificación.
    if (listenForMessages && !_listenersAttached) {
      _listenersAttached = true;
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen((message) {
        unawaited(showRemoteMessage(message, foreground: true));
      });
      _openedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
        _publishRemoteAction,
      );
      try {
        final initialMessage = await FirebaseMessaging.instance
            .getInitialMessage();
        if (initialMessage != null) _publishRemoteAction(initialMessage);
      } catch (error) {
        debugPrint('Notificaciones: no se leyó el mensaje inicial: $error');
      }
    }

    // 2. Notificaciones locales y canales Android.
    if (!_localReady) {
      try {
        final initialized = await _localNotifications.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings(_notificationIcon),
            iOS: DarwinInitializationSettings(),
          ),
          onDidReceiveNotificationResponse: _onLocalNotificationResponse,
        );
        _localReady = initialized != false;
      } catch (error, stackTrace) {
        debugPrint('Notificaciones locales no disponibles: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      if (_localReady) await _ensureAndroidChannels();
    }

    if (_localReady && listenForMessages && !_launchDetailsHandled) {
      _launchDetailsHandled = true;
      try {
        final launchDetails = await _localNotifications
            .getNotificationAppLaunchDetails();
        final response = launchDetails?.notificationResponse;
        if (launchDetails?.didNotificationLaunchApp == true &&
            response != null) {
          _publishPayload(response.payload);
        }
      } catch (_) {}
    }
    return _localReady;
  }

  static Future<void> _createChannel(
    AndroidFlutterLocalNotificationsPlugin android,
    AndroidNotificationChannel channel,
  ) async {
    try {
      await android.createNotificationChannel(channel);
    } catch (error) {
      debugPrint('Notificaciones: no se creó el canal ${channel.id}: $error');
    }
  }

  static Future<void> _ensureAndroidChannels() async {
    if (!_isAndroid) return;
    final android = _android;
    if (android == null) return;

    for (final legacyId in _legacyChannelIds) {
      try {
        await android.deleteNotificationChannel(channelId: legacyId);
      } catch (_) {}
    }

    final selectedId = AppNotificationAudio.selectedSound.id;
    final activeSoundIds = {defaultSoundId, selectedId};
    for (final option in courierAlertSoundOptions) {
      if (activeSoundIds.contains(option.id)) continue;
      // Libera los canales de sonidos que ya no están seleccionados.
      try {
        await android.deleteNotificationChannel(
          channelId: newDeliveryChannelId(option.id),
        );
        await android.deleteNotificationChannel(
          channelId: assignedChannelId(option.id),
        );
      } catch (_) {}
    }

    for (final soundId in activeSoundIds) {
      final option = AppNotificationAudio.soundById(soundId);
      final suffix = soundId == defaultSoundId && selectedId != defaultSoundId
          ? ' (respaldo)'
          : '';
      await _createChannel(
        android,
        AndroidNotificationChannel(
          newDeliveryChannelId(soundId),
          'Domicilios nuevos$suffix',
          description: 'Un domicilio nuevo está disponible para aceptar.',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(option.androidRawSound),
          enableVibration: true,
        ),
      );
      await _createChannel(
        android,
        AndroidNotificationChannel(
          assignedChannelId(soundId),
          'Domicilios asignados$suffix',
          description: 'La farmacia te asignó un domicilio directamente.',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(option.androidRawSound),
          enableVibration: true,
        ),
      );
    }

    await _createChannel(
      android,
      AndroidNotificationChannel(
        chatChannelId,
        'Mensajes del chat',
        description: 'Mensajes nuevos del chat de un domicilio.',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
          AppNotificationAudio.messageSound.androidRawSound,
        ),
        enableVibration: true,
      ),
    );
    await _createChannel(
      android,
      const AndroidNotificationChannel(
        silentChannelId,
        'Alertas ya avisadas en pantalla',
        description:
            'Se usa cuando la app abierta ya sonó por el mismo domicilio.',
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  /// Se llama al cambiar el sonido en Configuración: crea los canales del
  /// sonido elegido y actualiza el registro del dispositivo.
  static Future<void> applySelectedSound() async {
    if (!FirebaseConfig.messagingConfigured) return;
    if (_localReady) {
      await _ensureAndroidChannels();
    } else {
      await initialize(listenForMessages: false);
    }
    final token = _registeredToken;
    if (token != null &&
        SupabaseConfig.isConfigured &&
        SupabaseOperationsService.instance.hasAuthenticatedUser) {
      try {
        await _saveToken(token);
      } catch (error) {
        debugPrint('Notificaciones: no se actualizó el sonido: $error');
      }
    }
  }

  /// Solo PWA: falso cuando el navegador no admite push. En iPhone pasa si la
  /// PWA no se abrió desde el ícono de la pantalla de inicio.
  static final webPushSupported = ValueNotifier<bool>(true);

  /// Solo PWA: deja Firebase listo antes del toque en "Activar", para que la
  /// solicitud de permiso ocurra dentro del gesto del usuario.
  static Future<void> prepareWebPush() async {
    if (!kIsWeb || !FirebaseConfig.messagingConfigured) return;
    try {
      if (!await _ensureFirebase()) return;
      webPushSupported.value = await FirebaseMessaging.instance.isSupported();
      await refreshPermissionStatus();
    } catch (error) {
      debugPrint('Notificaciones: no se preparó el push web: $error');
    }
  }

  /// Botón "Activar". En Android abre los ajustes de la app; en la PWA pide
  /// el permiso del navegador, que iPhone solo muestra tras un toque.
  static Future<bool> enableFromUserTap() async {
    if (!kIsWeb) return openNotificationSettings();
    AppNotificationAudio.unlockForWeb();
    if (!FirebaseConfig.messagingConfigured ||
        FirebaseConfig.webVapidKey.trim().isEmpty) {
      return false;
    }
    try {
      if (!await _ensureFirebase()) return false;
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      _askedThisSession = true;
      permissionStatus.value = granted
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
      if (granted &&
          SupabaseConfig.isConfigured &&
          SupabaseOperationsService.instance.hasAuthenticatedUser) {
        await registerForCurrentUser();
      }
      return granted;
    } catch (error) {
      debugPrint('Notificaciones: no se pudo activar el push web: $error');
      return false;
    }
  }

  /// Lee el permiso actual sin mostrar ningún diálogo.
  static Future<NotificationPermissionStatus> refreshPermissionStatus() async {
    var status = NotificationPermissionStatus.unknown;
    try {
      if (_isAndroid) {
        final enabled = await _android?.areNotificationsEnabled();
        if (enabled != null) {
          status = enabled
              ? NotificationPermissionStatus.granted
              : NotificationPermissionStatus.denied;
        }
      } else if (FirebaseConfig.messagingConfigured &&
          await _ensureFirebase()) {
        final settings = await FirebaseMessaging.instance
            .getNotificationSettings();
        status = switch (settings.authorizationStatus) {
          AuthorizationStatus.authorized || AuthorizationStatus.provisional =>
            NotificationPermissionStatus.granted,
          AuthorizationStatus.denied => NotificationPermissionStatus.denied,
          _ => NotificationPermissionStatus.unknown,
        };
      }
    } catch (_) {
      status = NotificationPermissionStatus.unknown;
    }
    permissionStatus.value = status;
    return status;
  }

  /// Abre los ajustes de notificaciones de la app (Android 8+), para cuando el
  /// usuario negó el permiso y Android ya no vuelve a mostrar el diálogo.
  static Future<bool> openNotificationSettings() async {
    try {
      if (_isAndroid) {
        return await _android?.openAppNotificationSettings() ?? false;
      }
    } catch (error) {
      debugPrint('Notificaciones: no se abrieron los ajustes: $error');
    }
    return false;
  }

  /// Solicita el permiso del sistema. Android 13+ y iOS requieren esta
  /// decisión del usuario para mostrar alertas en segundo plano.
  static Future<bool> requestPermissionForEntry() {
    if (!FirebaseConfig.messagingConfigured) return Future.value(false);
    if (kIsWeb && FirebaseConfig.webVapidKey.trim().isEmpty) {
      return Future.value(false);
    }

    final running = _permissionRequestInFlight;
    if (running != null) return running;

    final request = _requestPermissionForEntry();
    _permissionRequestInFlight = request;
    return request.whenComplete(() {
      if (identical(_permissionRequestInFlight, request)) {
        _permissionRequestInFlight = null;
      }
    });
  }

  static Future<bool> _requestPermissionForEntry() async {
    try {
      final current = await refreshPermissionStatus();
      if (current == NotificationPermissionStatus.granted) {
        unawaited(initialize());
        return true;
      }
      // En la PWA el navegador solo muestra el diálogo tras un toque (iPhone
      // ignora cualquier otra solicitud); lo pide el botón "Activar".
      if (kIsWeb) return false;
      // Un mismo arranque no insiste con el diálogo: si el usuario lo negó,
      // la app muestra el aviso con el botón para abrir los ajustes.
      if (_askedThisSession) return false;

      final startedAt = DateTime.now();
      var granted = false;
      if (_isAndroid) {
        // En Android se usa una sola solicitud (la del plugin local). Antes se
        // pedía dos veces seguidas (Firebase y luego el plugin local) y la
        // segunda podía cancelarse si la primera seguía abierta.
        final android = _android;
        // Sin el plugin nativo (por ejemplo, en pruebas) no hay decisión del
        // usuario que registrar.
        if (android == null) return false;
        granted = await android.requestNotificationsPermission() ?? false;
      } else {
        if (!await _ensureFirebase()) return false;
        final settings = await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        granted =
            settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
      }

      // Si la respuesta llegó casi de inmediato, el diálogo no se mostró
      // (otra solicitud de permiso en curso o un rechazo permanente). En ese
      // caso no se marca como preguntado para poder reintentar al iniciar
      // sesión o al volver a la app.
      final elapsed = DateTime.now().difference(startedAt);
      if (granted || elapsed >= const Duration(milliseconds: 700)) {
        _askedThisSession = true;
      }
      permissionStatus.value = granted
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
      if (granted) unawaited(initialize());
      return granted;
    } catch (error, stackTrace) {
      // Un fallo transitorio (por ejemplo, la Activity todavía no estaba
      // lista) no cuenta como respuesta del usuario: se reintenta luego.
      debugPrint('No se pudo solicitar permiso de notificaciones: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  static Future<void> registerForCurrentUser() async {
    if (!FirebaseConfig.messagingConfigured || !SupabaseConfig.isConfigured) {
      return;
    }
    final allowed = await requestPermissionForEntry();

    try {
      if (!await _ensureFirebase()) return;
      unawaited(initialize());
      final messaging = FirebaseMessaging.instance;
      await messaging.setAutoInitEnabled(true);

      String? token;
      if (kIsWeb) {
        // En la PWA el navegador solo entrega el token con permiso concedido.
        if (!allowed || FirebaseConfig.webVapidKey.trim().isEmpty) return;
        token = await messaging.getToken(
          vapidKey: FirebaseConfig.webVapidKey,
          serviceWorkerScriptPath: 'push/firebase-messaging-sw.js',
        );
      } else {
        // En Android el token se registra aunque el permiso esté pendiente:
        // en cuanto el usuario lo active, las alertas llegan sin otro login.
        token = await messaging.getToken();
      }
      if (token != null && token.trim().isNotEmpty) {
        _registeredToken = token;
        await _saveToken(token);
      } else {
        debugPrint('Notificaciones: Firebase no entregó token FCM.');
      }

      _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen((token) {
        if (token.trim().isEmpty) return;
        _registeredToken = token;
        unawaited(
          _saveToken(token).catchError((Object error) {
            debugPrint('Notificaciones: no se renovó el token: $error');
          }),
        );
      });
    } catch (error) {
      // Un dispositivo sin Firebase/APNs configurado no debe bloquear el
      // inicio de sesión ni la operación en primer plano.
      debugPrint('Notificaciones: no se pudo registrar el token FCM: $error');
    }
  }

  static Future<void> _saveToken(String token) =>
      SupabaseOperationsService.instance.upsertPushToken(
        token: token,
        platform: _platformName,
        alertSound: AppNotificationAudio.selectedSound.id,
      );

  static Future<void> unregisterCurrentDevice() async {
    var token = _registeredToken;
    _registeredToken = null;
    _askedThisSession = false;
    if ((token == null || token.isEmpty) && !kIsWeb && _firebaseReady) {
      try {
        token = await FirebaseMessaging.instance.getToken();
      } catch (_) {}
    }
    if (token == null || token.isEmpty) return;
    try {
      await SupabaseOperationsService.instance.removePushToken(token);
    } catch (_) {}
  }

  static String get _platformName => kIsWeb
      ? 'web'
      : defaultTargetPlatform == TargetPlatform.iOS
      ? 'ios'
      : 'android';

  static PushAlertKind _kindFromData(Map<String, dynamic> data) =>
      switch ('${data['type'] ?? ''}'.trim()) {
        'chat_message' => PushAlertKind.chat,
        'delivery_assigned' => PushAlertKind.assigned,
        _ => PushAlertKind.newDelivery,
      };

  static String _dataText(Map<String, dynamic> data, String key) {
    final value = '${data[key] ?? ''}'.trim();
    return value == 'null' ? '' : value;
  }

  static Future<void> showRemoteMessage(
    RemoteMessage message, {
    bool foreground = true,
  }) async {
    if (!await initialize(listenForMessages: false)) return;
    final data = <String, dynamic>{...message.data};
    final kind = _kindFromData(data);
    final action = _actionFromData(data);
    final deliveryId = action?.deliveryId ?? _dataText(data, 'delivery_id');
    final code = formatDeliveryPublicCode(_dataText(data, 'public_code'));
    final pharmacyCode = _dataText(data, 'pharmacy_code');
    final pharmacy = pharmacyCode.isEmpty
        ? ''
        : formatPharmacyDisplay(pharmacyCode);
    final codeLabel = [
      code,
      pharmacy,
    ].where((part) => part.isNotEmpty).join(' · ');

    final title =
        message.notification?.title ??
        (_dataText(data, 'title').isNotEmpty
            ? _dataText(data, 'title')
            : switch (kind) {
                PushAlertKind.chat => 'Nuevo mensaje del domicilio',
                PushAlertKind.assigned => 'Domicilio asignado',
                PushAlertKind.newDelivery => 'Nuevo domicilio disponible',
              });
    final body =
        message.notification?.body ??
        (_dataText(data, 'body').isNotEmpty
            ? _dataText(data, 'body')
            : switch (kind) {
                PushAlertKind.chat =>
                  '${_dataText(data, 'sender_name').isEmpty ? 'La operación' : _dataText(data, 'sender_name')} te escribió en el chat.',
                PushAlertKind.assigned =>
                  '${codeLabel.isEmpty ? 'Domicilio' : codeLabel} · La farmacia te asignó este domicilio.',
                PushAlertKind.newDelivery =>
                  codeLabel.isEmpty
                      ? 'Abre farmanorte para ver y aceptar el domicilio.'
                      : '$codeLabel · Toca para ver y aceptar.',
              });

    // Con la app abierta, la escucha en tiempo real también suena. Se usa una
    // sola alerta por domicilio/mensaje: la que llegue primero.
    final alertKey = kind == PushAlertKind.chat
        ? 'chat:${_dataText(data, 'message_id').isEmpty ? message.messageId ?? deliveryId : _dataText(data, 'message_id')}'
        : 'delivery:${kind.name}:$deliveryId';
    final firstAlert =
        !foreground ||
        deliveryId.isEmpty ||
        AppNotificationAudio.claimAlert(alertKey);
    final playSound = firstAlert && AppNotificationAudio.enabled;

    final soundOption = kind == PushAlertKind.chat
        ? AppNotificationAudio.messageSound
        : AppNotificationAudio.selectedSound;
    final channelId = !playSound
        ? silentChannelId
        : switch (kind) {
            PushAlertKind.chat => chatChannelId,
            PushAlertKind.assigned => assignedChannelId(soundOption.id),
            PushAlertKind.newDelivery => newDeliveryChannelId(soundOption.id),
          };
    final channelName = !playSound
        ? 'Alertas ya avisadas en pantalla'
        : switch (kind) {
            PushAlertKind.chat => 'Mensajes del chat',
            PushAlertKind.assigned => 'Domicilios asignados',
            PushAlertKind.newDelivery => 'Domicilios nuevos',
          };

    // Un id estable por domicilio y tipo evita varias tarjetas del mismo aviso.
    final notificationKey = kind == PushAlertKind.chat || deliveryId.isEmpty
        ? (message.messageId ?? '${DateTime.now().millisecondsSinceEpoch}')
        : '${kind.name}:$deliveryId';
    final notificationId = notificationKey.hashCode & 0x7fffffff;

    try {
      await _localNotifications.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription:
                'Alertas de domicilios y mensajes de farmanorte.',
            importance: Importance.max,
            priority: Priority.high,
            icon: _notificationIcon,
            color: AppColors.primary,
            playSound: playSound,
            enableVibration: playSound,
            sound: playSound
                ? RawResourceAndroidNotificationSound(
                    soundOption.androidRawSound,
                  )
                : null,
            category: kind == PushAlertKind.chat
                ? AndroidNotificationCategory.message
                : AndroidNotificationCategory.event,
            visibility: NotificationVisibility.public,
            ticker: title,
            styleInformation: BigTextStyleInformation(body),
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
          web: WebNotificationDetails(
            iconUrl: Uri.base.resolve('icons/Icon-192.png'),
            badgeUrl: Uri.base.resolve('icons/Icon-192.png'),
            renotify: true,
          ),
        ),
        payload: jsonEncode({
          'type': action?.type ?? data['type'] ?? 'delivery',
          'delivery_id': deliveryId,
          'open_chat': action?.openChat ?? kind == PushAlertKind.chat,
        }),
      );
    } catch (error) {
      debugPrint('Notificaciones: no se pudo mostrar la alerta: $error');
    }
  }

  static void _publishRemoteAction(RemoteMessage message) {
    _publishPayload(jsonEncode(message.data));
  }

  static void _onLocalNotificationResponse(NotificationResponse response) {
    _publishPayload(response.payload);
  }

  static void _publishPayload(String? payload) {
    if (payload == null || payload.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final action = _actionFromData(Map<String, dynamic>.from(decoded));
      AppNotificationNavigation.publish(action);
    } catch (_) {}
  }

  static PushNotificationAction? _actionFromData(Map<String, dynamic> data) {
    final deliveryId = '${data['delivery_id'] ?? data['deliveryId'] ?? ''}'
        .trim();
    if (deliveryId.isEmpty) return null;
    final rawType = '${data['type'] ?? 'delivery'}'.trim();
    final openChat =
        data['open_chat'] == true ||
        '${data['open_chat'] ?? ''}'.toLowerCase() == 'true' ||
        rawType == 'chat_message';
    return PushNotificationAction(
      type: rawType,
      deliveryId: deliveryId,
      openChat: openChat,
    );
  }
}

/// Aviso visible cuando el sistema tiene las notificaciones desactivadas.
/// Android deja de mostrar el diálogo después de dos rechazos, así que la única
/// forma de recuperarlas es abrir los ajustes de la app.
class NotificationPermissionBanner extends StatefulWidget {
  const NotificationPermissionBanner({super.key, required this.child});

  final Widget child;

  @override
  State<NotificationPermissionBanner> createState() =>
      _NotificationPermissionBannerState();
}

class _NotificationPermissionBannerState
    extends State<NotificationPermissionBanner>
    with WidgetsBindingObserver {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) unawaited(BackgroundNotificationService.prepareWebPush());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_recheckAfterResume());
  }

  Future<void> _recheckAfterResume() async {
    if (!FirebaseConfig.messagingConfigured) return;
    final previous = BackgroundNotificationService.permissionStatus.value;
    final status =
        await BackgroundNotificationService.refreshPermissionStatus();
    if (status == NotificationPermissionStatus.granted &&
        previous != NotificationPermissionStatus.granted &&
        SupabaseConfig.isConfigured &&
        SupabaseOperationsService.instance.hasAuthenticatedUser) {
      // El usuario activó el permiso desde Ajustes: se preparan los canales y
      // se confirma el token sin pedir un nuevo inicio de sesión.
      unawaited(BackgroundNotificationService.registerForCurrentUser());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroidApp =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final isWebPush = kIsWeb && FirebaseConfig.messagingConfigured;
    if (!isAndroidApp && !isWebPush) return widget.child;
    final isIphone = defaultTargetPlatform == TargetPlatform.iOS;
    return ValueListenableBuilder<bool>(
      valueListenable: BackgroundNotificationService.webPushSupported,
      builder: (context, webSupported, _) =>
          ValueListenableBuilder<NotificationPermissionStatus>(
            valueListenable: BackgroundNotificationService.permissionStatus,
            child: widget.child,
            builder: (context, status, child) {
              final visible =
                  !_dismissed &&
                  (isAndroidApp
                      ? status == NotificationPermissionStatus.denied
                      : status != NotificationPermissionStatus.granted);
              if (!visible) return child!;
              // En la PWA, iPhone solo admite push si se abre desde el ícono de la
              // pantalla de inicio; en ese caso se explica cómo instalarla.
              final needsInstall = isWebPush && !webSupported;
              final message = needsInstall
                  ? (isIphone
                        ? 'Para recibir avisos en iPhone: toca Compartir → Agregar '
                              'a pantalla de inicio y abre farmanorte desde ese ícono.'
                        : 'Este navegador no admite notificaciones. Instala la app '
                              'o usa Chrome.')
                  : isWebPush && status == NotificationPermissionStatus.denied
                  ? (isIphone
                        ? 'Notificaciones bloqueadas. Actívalas en Ajustes → '
                              'Notificaciones → farmanorte.'
                        : 'Notificaciones bloqueadas. Permítelas en los permisos '
                              'del sitio del navegador.')
                  : isWebPush
                  ? 'Activa las notificaciones para recibir domicilios nuevos y '
                        'asignados aunque no tengas la app abierta.'
                  : 'Las notificaciones están desactivadas. Actívalas '
                        'para recibir domicilios nuevos y asignados.';
              final showAction =
                  isAndroidApp ||
                  (!needsInstall &&
                      status != NotificationPermissionStatus.denied);
              return Column(
                children: [
                  Expanded(child: child!),
                  Material(
                    color: AppColors.primary,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.notifications_off_outlined,
                              color: Colors.white,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                message,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  height: 1.3,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (showAction)
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () => unawaited(
                                  BackgroundNotificationService.enableFromUserTap(),
                                ),
                                child: const Text(
                                  'Activar',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            IconButton(
                              tooltip: 'Ocultar aviso',
                              color: Colors.white70,
                              iconSize: 18,
                              onPressed: () =>
                                  setState(() => _dismissed = true),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

class SupabaseConfig {
  SupabaseConfig._();

  // Solo se usa la clave pública/publishable en la aplicación. La clave
  // secreta de Supabase nunca debe compilarse dentro de una APK o PWA.
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static Uri? get parsedUrl {
    final candidate = url.trim();
    if (candidate.isEmpty) return null;
    final parsed = Uri.tryParse(candidate);
    if (parsed == null || parsed.host.isEmpty) return null;
    if (parsed.scheme != 'https' && parsed.scheme != 'http') return null;
    return parsed;
  }

  static bool get isConfigured =>
      parsedUrl != null && publishableKey.trim().isNotEmpty;

  static String get configurationError {
    if (url.trim().isEmpty) {
      return 'La APK fue compilada sin SUPABASE_URL.';
    }
    if (parsedUrl == null) {
      return 'La APK fue compilada con una SUPABASE_URL inválida. '
          'Genera de nuevo la APK usando la URL de Supabase real.';
    }
    if (publishableKey.trim().isEmpty) {
      return 'La APK fue compilada sin SUPABASE_PUBLISHABLE_KEY.';
    }
    return 'La configuración de Supabase no está disponible.';
  }
}

class SupabaseUserProfile {
  const SupabaseUserProfile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.active,
    this.pharmacyCode,
    this.mustChangePassword = false,
  });

  final String id;
  final String fullName;
  final String role;
  final bool active;
  final String? pharmacyCode;
  final bool mustChangePassword;

  factory SupabaseUserProfile.fromMap(Map<String, dynamic> row) {
    return SupabaseUserProfile(
      id: '${row['id'] ?? ''}',
      fullName: '${row['full_name'] ?? ''}',
      role: '${row['role'] ?? ''}',
      active: row['active'] == true,
      pharmacyCode: row['pharmacy_code']?.toString(),
      mustChangePassword: row['must_change_password'] == true,
    );
  }

  SupabaseUserProfile copyWith({bool? mustChangePassword}) =>
      SupabaseUserProfile(
        id: id,
        fullName: fullName,
        role: role,
        active: active,
        pharmacyCode: pharmacyCode,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );
}

bool isSupportedOperationsAppRole(String role) =>
    role == 'admin' || role == 'courier';

String operationsAppAccessMessage(String role) => switch (role) {
  'pharmacy' =>
    'Esta cuenta pertenece a una farmacia y no puede entrar a la aplicación '
        'de domiciliarios. Usa la página web de la farmacia.',
  'admin' =>
    'Esta cuenta es administrativa. Entra desde el panel de administración.',
  'courier' => 'Este domiciliario debe entrar desde la opción Domiciliario.',
  _ => 'Este usuario no tiene permiso para entrar a esta aplicación.',
};

class DeliveryChatMessage {
  const DeliveryChatMessage({
    required this.id,
    required this.deliveryId,
    required this.senderId,
    required this.senderName,
    required this.senderRole,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String deliveryId;
  final String senderId;
  final String senderName;
  final String senderRole;
  final String body;
  final DateTime createdAt;

  factory DeliveryChatMessage.fromMap(Map<String, dynamic> row) {
    return DeliveryChatMessage(
      id: '${row['id'] ?? ''}',
      deliveryId: '${row['delivery_id'] ?? ''}',
      senderId: '${row['sender_id'] ?? ''}',
      senderName: '${row['sender_name'] ?? 'Usuario'}',
      senderRole: '${row['sender_role'] ?? ''}',
      body: '${row['body'] ?? ''}',
      createdAt:
          DateTime.tryParse('${row['created_at'] ?? ''}') ?? DateTime.now(),
    );
  }
}

class DeliveryEquivalent {
  const DeliveryEquivalent({
    required this.id,
    required this.deliveryId,
    required this.pharmacyCode,
    required this.serviceLabel,
    required this.description,
    required this.amount,
    required this.paymentMethod,
    required this.deliveryStatus,
    required this.status,
    required this.createdAt,
    this.courierId,
    this.courierName,
    this.courierSignatureName,
    this.courierSignatureImage,
    this.courierSignedAt,
    this.pharmacyAcknowledgedAt,
    this.paymentStatus = 'pending',
    this.paidAt,
    this.paidAmount,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String deliveryId;
  final String pharmacyCode;
  final String serviceLabel;
  final String description;
  final double amount;
  final String paymentMethod;
  final String deliveryStatus;
  final String status;
  final DateTime createdAt;
  final String? courierId;
  final String? courierName;
  final String? courierSignatureName;
  final String? courierSignatureImage;
  final DateTime? courierSignedAt;
  final DateTime? pharmacyAcknowledgedAt;
  final String paymentStatus;
  final DateTime? paidAt;
  final double? paidAmount;
  final Map<String, dynamic> metadata;

  factory DeliveryEquivalent.fromMap(Map<String, dynamic> row) {
    final rawMetadata = row['metadata'];
    return DeliveryEquivalent(
      id: '${row['id'] ?? ''}',
      deliveryId: '${row['delivery_id'] ?? ''}',
      pharmacyCode: '${row['pharmacy_code'] ?? ''}',
      serviceLabel: '${row['service_label'] ?? 'Servicio'}',
      description: '${row['description'] ?? ''}',
      amount: _asDouble(row['amount']),
      paymentMethod: '${row['payment_method'] ?? 'none'}',
      deliveryStatus: '${row['delivery_status'] ?? ''}',
      status: '${row['status'] ?? 'draft'}',
      createdAt:
          DateTime.tryParse('${row['created_at'] ?? ''}') ?? DateTime.now(),
      courierId: row['courier_id']?.toString(),
      courierName: row['courier_name']?.toString(),
      courierSignatureName: row['courier_signature_name']?.toString(),
      courierSignatureImage: row['courier_signature_image']?.toString(),
      courierSignedAt: DateTime.tryParse('${row['courier_signed_at'] ?? ''}'),
      pharmacyAcknowledgedAt: DateTime.tryParse(
        '${row['pharmacy_acknowledged_at'] ?? ''}',
      ),
      paymentStatus: '${row['payment_status'] ?? 'pending'}',
      paidAt: DateTime.tryParse('${row['paid_at'] ?? ''}'),
      paidAmount: row['paid_amount'] == null
          ? null
          : _asDouble(row['paid_amount']),
      metadata: rawMetadata is Map
          ? Map<String, dynamic>.from(rawMetadata)
          : const <String, dynamic>{},
    );
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }
}

class CourierFeeSummary {
  const CourierFeeSummary({
    required this.weekStart,
    required this.weekEnd,
    required this.scheduledDays,
    required this.doubleShiftCount,
    required this.baseAmount,
    required this.doubleSurcharge,
    required this.totalDue,
    required this.totalPaid,
    required this.balanceDue,
    required this.dailyAmount,
    required this.doubleShiftSurcharge,
    this.lastPaymentAt,
  });

  final DateTime weekStart;
  final DateTime weekEnd;
  final int scheduledDays;
  final int doubleShiftCount;
  final double baseAmount;
  final double doubleSurcharge;
  final double totalDue;
  final double totalPaid;
  final double balanceDue;
  final double dailyAmount;
  final double doubleShiftSurcharge;
  final DateTime? lastPaymentAt;

  factory CourierFeeSummary.fromMap(Map<String, dynamic> row) {
    return CourierFeeSummary(
      weekStart:
          DateTime.tryParse('${row['week_start'] ?? ''}') ?? _adminToday(),
      weekEnd: DateTime.tryParse('${row['week_end'] ?? ''}') ?? _adminToday(),
      scheduledDays: _asInt(row['scheduled_days']),
      doubleShiftCount: _asInt(row['double_shift_count']),
      baseAmount: _asDouble(row['base_amount']),
      doubleSurcharge: _asDouble(row['double_surcharge']),
      totalDue: _asDouble(row['total_due']),
      totalPaid: _asDouble(row['total_paid']),
      balanceDue: _asDouble(row['balance_due'] ?? row['total_due']),
      dailyAmount: _asDouble(row['daily_amount']),
      doubleShiftSurcharge: _asDouble(row['double_shift_surcharge']),
      lastPaymentAt: DateTime.tryParse('${row['last_payment_at'] ?? ''}'),
    );
  }
}

class AdminCourierFeeSummary {
  const AdminCourierFeeSummary({
    required this.courierId,
    required this.courierName,
    required this.scheduledDays,
    required this.doubleShiftCount,
    required this.totalDue,
    required this.totalPaid,
    required this.balanceDue,
    required this.dailyAmount,
    required this.doubleShiftSurcharge,
    this.lastPaymentAt,
  });

  final String courierId;
  final String courierName;
  final int scheduledDays;
  final int doubleShiftCount;
  final double totalDue;
  final double totalPaid;
  final double balanceDue;
  final double dailyAmount;
  final double doubleShiftSurcharge;
  final DateTime? lastPaymentAt;

  factory AdminCourierFeeSummary.fromMap(Map<String, dynamic> row) {
    return AdminCourierFeeSummary(
      courierId: '${row['courier_id'] ?? ''}',
      courierName: '${row['courier_name'] ?? 'Sin nombre'}',
      scheduledDays: _asInt(row['scheduled_days']),
      doubleShiftCount: _asInt(row['double_shift_count']),
      totalDue: _asDouble(row['total_due']),
      totalPaid: _asDouble(row['total_paid']),
      balanceDue: _asDouble(row['balance_due'] ?? row['total_due']),
      dailyAmount: _asDouble(row['daily_amount']),
      doubleShiftSurcharge: _asDouble(row['double_shift_surcharge']),
      lastPaymentAt: DateTime.tryParse('${row['last_payment_at'] ?? ''}'),
    );
  }
}

class CourierPharmacyBreakdown {
  const CourierPharmacyBreakdown({
    required this.pharmacyCode,
    required this.pharmacyName,
    required this.serviceCount,
    required this.totalEarnings,
    required this.baseCount,
    required this.supportCount,
  });

  final String pharmacyCode;
  final String pharmacyName;
  final int serviceCount;
  final double totalEarnings;
  final int baseCount;
  final int supportCount;

  factory CourierPharmacyBreakdown.fromMap(Map<String, dynamic> row) {
    return CourierPharmacyBreakdown(
      pharmacyCode: '${row['pharmacy_code'] ?? ''}',
      pharmacyName: '${row['pharmacy_name'] ?? 'Farmacia'}',
      serviceCount: _asInt(row['service_count']),
      totalEarnings: _asDouble(row['total_earnings']),
      baseCount: _asInt(row['base_count']),
      supportCount: _asInt(row['support_count']),
    );
  }
}

class PharmacyCourierBreakdown {
  const PharmacyCourierBreakdown({
    required this.courierId,
    required this.courierName,
    required this.serviceCount,
    required this.totalEarnings,
    required this.baseCount,
    required this.supportCount,
  });

  final String courierId;
  final String courierName;
  final int serviceCount;
  final double totalEarnings;
  final int baseCount;
  final int supportCount;

  factory PharmacyCourierBreakdown.fromMap(Map<String, dynamic> row) {
    return PharmacyCourierBreakdown(
      courierId: '${row['courier_id'] ?? ''}',
      courierName: '${row['courier_name'] ?? 'Domiciliario'}',
      serviceCount: _asInt(row['service_count']),
      totalEarnings: _asDouble(row['total_earnings']),
      baseCount: _asInt(row['base_count']),
      supportCount: _asInt(row['support_count']),
    );
  }
}

int _asInt(dynamic value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;

double _asDouble(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

class AdminBackendSnapshot {
  const AdminBackendSnapshot({
    required this.zones,
    required this.pharmacies,
    required this.shifts,
    required this.users,
  });

  final List<AdminZone> zones;
  final List<AdminPharmacy> pharmacies;
  final List<AdminShift> shifts;
  final List<AdminUser> users;
}

class RealtimeOperationsService {
  RealtimeOperationsService._();

  static final instance = RealtimeOperationsService._();

  static const courierId = 'courier-demo-juan';

  FirebaseDatabase? _database;
  Future<bool>? _initializing;

  bool get isReady => _database != null;

  Future<bool> initialize() {
    if (isReady) return Future.value(true);
    if (!FirebaseConfig.isConfigured) return Future.value(false);
    final currentInitialization = _initializing;
    if (currentInitialization != null) return currentInitialization;
    final initialization = _initialize();
    _initializing = initialization;
    return initialization.whenComplete(() => _initializing = null);
  }

  Future<bool> _initialize() async {
    try {
      final app = Firebase.apps.isEmpty
          ? await Firebase.initializeApp(options: FirebaseConfig.options)
          : Firebase.app();
      _database = FirebaseDatabase.instanceFor(
        app: app,
        databaseURL: FirebaseConfig.databaseUrl,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> publishCourierLocation({
    required String courierId,
    required Position position,
  }) async {
    if (!await initialize()) return;
    try {
      await _database!.ref('couriers/$courierId').update({
        'connected': true,
        'lastSeenAt': ServerValue.timestamp,
        'location': {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'heading': position.heading,
          'speed': position.speed,
          'updatedAt': ServerValue.timestamp,
        },
      });
    } catch (_) {
      // La operación local del domiciliario no se detiene si la red falla.
    }
  }

  Future<void> publishCourierConnection({
    required String courierId,
    required bool connected,
  }) async {
    if (!await initialize()) return;
    try {
      await _database!.ref('couriers/$courierId').update({
        'connected': connected,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<void> updateDeliveryStatus({
    required String deliveryId,
    required DeliveryStatus status,
  }) async {
    if (!await initialize()) return;
    try {
      await _database!.ref('deliveries/$deliveryId').update({
        'status': status.name,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<Stream<List<Delivery>>?> watchDeliveries() async {
    if (!await initialize()) return null;
    return _database!.ref('deliveries').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return <Delivery>[];
      final deliveries = <Delivery>[];
      for (final entry in raw.entries) {
        if (entry.value is Map) {
          final data = Map<dynamic, dynamic>.from(entry.value as Map);
          deliveries.add(_deliveryFromMap('${entry.key}', data));
        }
      }
      return deliveries;
    });
  }

  Delivery _deliveryFromMap(String id, Map<dynamic, dynamic> data) {
    final rawPayment = '${data['paymentMethod'] ?? ''}'.toLowerCase();
    final payment = rawPayment == 'transfer' || rawPayment == 'transferencia'
        ? PaymentMethod.qr
        : _enumValue(
            PaymentMethod.values,
            data['paymentMethod'],
            PaymentMethod.cash,
          );
    final kind = _enumValue(
      DeliveryKind.values,
      data['kind'],
      DeliveryKind.pharmacyToHome,
    );
    final status = _enumValue(
      DeliveryStatus.values,
      data['status'],
      DeliveryStatus.offered,
    );
    final origin = _latLngValue(data['origin'], MapsConfig.monteria);
    final destinationPoint = _latLngValue(
      data['destinationPoint'],
      MapsConfig.monteria,
    );
    final service = DeliveryServicePlan.fromMap(data, kind: kind);
    final pickupStops = _pickupStopsFromMap(data['pickupStops']);
    final crossRoutes = _crossRoutesFromMap(data['pickupStops']);
    final firstCrossRoute = crossRoutes.isEmpty ? null : crossRoutes.first;
    final originCode = firstCrossRoute?.originCode;
    final destinationCode = firstCrossRoute?.destinationCode;
    final crossOperation = originCode != null && destinationCode != null;
    final isCrossOnly = crossOperation && !service.hasDomicilio;
    final displayStoreName = originCode == null
        ? '${data['storeName'] ?? farmanorteBrandName}'
        : formatPharmacyCodeLabel(originCode);
    final displayStoreAddress = originCode == null
        ? '${data['storeAddress'] ?? 'Dirección por confirmar'}'
        : formatPharmacyDisplay(originCode);
    final displayDestination = isCrossOnly
        ? formatPharmacyCodeLabel(destinationCode)
        : '${data['destination'] ?? 'Destino por confirmar'}';
    final displayDestinationAddress = isCrossOnly
        ? formatPharmacyDisplay(destinationCode)
        : '${data['destinationAddress'] ?? 'Dirección por confirmar'}';
    final paymentAmount = _doubleValue(data['paymentAmount']);
    final reportedEarnings = _doubleValue(
      data['courierEarnings'] ?? data['earnings'],
    );
    return Delivery(
      id: id,
      storeName: displayStoreName,
      storeAddress: displayStoreAddress,
      destination: displayDestination,
      destinationAddress: displayDestinationAddress,
      recipientName: '${data['recipientName'] ?? 'Cliente'}',
      recipientPhone: '${data['recipientPhone'] ?? 'Sin teléfono'}',
      paymentMethod: payment,
      paymentAmount: paymentAmount,
      courierEarnings: reportedEarnings > 0
          ? reportedEarnings
          : service.fee.toDouble(),
      totalToCollect: _optionalDouble(data['totalToCollect'] ?? data['total']),
      cashReceived: _optionalDouble(data['cashReceived']),
      distance: _doubleValue(data['distance']),
      estimatedTime: _intValue(data['estimatedTime']),
      kind: kind,
      status: status,
      note: '${data['note'] ?? 'Sin instrucciones adicionales.'}',
      origin: origin,
      destinationPoint: destinationPoint,
      service: service,
      productSummary: '${data['productSummary'] ?? 'Productos del pedido'}',
      pickupStops: pickupStops,
      crossRoutes: crossRoutes,
      destinationOptions: _addressOptionsFromMap(
        data['destinationOptions'],
        fallback: DeliveryAddress(
          label: '${data['destination'] ?? 'Destino'}',
          address: '${data['destinationAddress'] ?? 'Dirección por confirmar'}',
          point: destinationPoint,
        ),
      ),
      pharmacyCode: '${data['pharmacyCode'] ?? ''}',
      neighborhood: '${data['neighborhood'] ?? ''}',
      addressReference: '${data['addressReference'] ?? ''}',
      cashExpected: _optionalDouble(data['cashExpected']),
      approvalPending: data['approvalPending'] == true,
      approvalCourierName: data['approvalCourierName']?.toString(),
      assignedAsSupport: data['assignedAsSupport'] == true,
      acceptedCourierId: data['acceptedCourierId']?.toString(),
      deliveryOutcome: data['deliveryOutcome']?.toString(),
      priorityUntil: DateTime.tryParse('${data['priorityUntil'] ?? ''}'),
      expiresAt: DateTime.tryParse('${data['expiresAt'] ?? ''}'),
    );
  }

  double? _optionalDouble(dynamic value) =>
      value == null ? null : _doubleValue(value);

  List<DeliveryPickupStop> _pickupStopsFromMap(dynamic raw) {
    return _listLike(raw).whereType<Map>().map((item) {
      final data = Map<dynamic, dynamic>.from(item);
      final origin =
          data['origin_pharmacy_code'] ??
          data['originPharmacyCode'] ??
          data['pharmacy_code'];
      final destination =
          data['destination_pharmacy_code'] ?? data['destinationPharmacyCode'];
      final isCross = origin != null && destination != null;
      return DeliveryPickupStop(
        title: isCross
            ? formatPharmacyCodeLabel(origin)
            : '${data['title'] ?? data['name'] ?? 'Punto de recogida'}',
        address: isCross
            ? formatPharmacyDisplay('$origin')
            : '${data['address'] ?? 'Dirección por confirmar'}',
        point: _latLngValue(data['point'], MapsConfig.monteria),
        label: isCross
            ? 'Recoger en ${formatPharmacyCodeLabel(origin)} · entregar en ${formatPharmacyCodeLabel(destination)}'
            : '${data['label'] ?? 'Recoger'}',
      );
    }).toList();
  }

  List<DeliveryCrossRoute> _crossRoutesFromMap(dynamic raw) {
    return _listLike(raw)
        .whereType<Map>()
        .map((item) {
          final data = Map<dynamic, dynamic>.from(item);
          final origin =
              data['origin_pharmacy_code'] ??
              data['originPharmacyCode'] ??
              data['pharmacy_code'];
          final destination =
              data['destination_pharmacy_code'] ??
              data['destinationPharmacyCode'];
          if (origin == null || destination == null) return null;
          final originCode = '$origin'.trim();
          final destinationCode = '$destination'.trim();
          if (originCode.isEmpty || destinationCode.isEmpty) return null;
          return DeliveryCrossRoute(
            originCode: originCode,
            destinationCode: destinationCode,
          );
        })
        .whereType<DeliveryCrossRoute>()
        .toList();
  }

  List<DeliveryAddress> _addressOptionsFromMap(
    dynamic raw, {
    required DeliveryAddress fallback,
  }) {
    final options = _listLike(raw).whereType<Map>().map((item) {
      final data = Map<dynamic, dynamic>.from(item);
      return DeliveryAddress(
        label: '${data['label'] ?? data['name'] ?? 'Dirección'}',
        address: '${data['address'] ?? 'Dirección por confirmar'}',
        point: _latLngValue(data['point'], fallback.point),
      );
    }).toList();
    return options.isEmpty ? const [] : options;
  }

  Iterable<dynamic> _listLike(dynamic raw) {
    if (raw is Iterable) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }

  T _enumValue<T extends Enum>(List<T> values, dynamic raw, T fallback) {
    final name = '$raw';
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  double _doubleValue(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  int _intValue(dynamic value) =>
      value is num ? value.round() : int.tryParse('$value') ?? 0;

  LatLng _latLngValue(dynamic value, LatLng fallback) {
    if (value is Map) {
      final latitude = _doubleValue(value['latitude']);
      final longitude = _doubleValue(value['longitude']);
      if (latitude != 0 || longitude != 0) {
        return LatLng(latitude, longitude);
      }
    }
    return fallback;
  }
}

/// Adaptador de Supabase para la operación real de la etapa 1.
///
/// La aplicación todavía puede ejecutarse con la información local de la
/// etapa 0. Cuando se configure SUPABASE_URL y SUPABASE_PUBLISHABLE_KEY, este
/// servicio queda preparado para escuchar domicilios en tiempo real y guardar
/// cambios de estado, presencia y ubicación. La sesión autenticada será
/// obligatoria para escribir datos protegidos por RLS.
class SupabaseOperationsService {
  SupabaseOperationsService._();

  static final instance = SupabaseOperationsService._();

  SupabaseClient? _client;
  Future<bool>? _initializing;
  String? _profileSchemaWarning;

  bool get isReady => _client != null;
  bool get hasAuthenticatedUser => _client?.auth.currentUser != null;
  String? get currentUserId => _client?.auth.currentUser?.id;

  /// Se completa únicamente cuando el proyecto remoto todavía no tiene la
  /// migración de la política de contraseñas temporales. No reemplaza la
  /// migración: sirve para que una APK actualizada pueda identificar el perfil
  /// existente mientras el administrador aplica la reparación en Supabase.
  String? get profileSchemaWarning => _profileSchemaWarning;

  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (!await initialize()) {
      throw StateError('Supabase no está configurado.');
    }
    return _client!.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<SupabaseUserProfile?> loadCurrentProfile() async {
    if (!await initialize()) return null;
    final user = _client!.auth.currentUser;
    if (user == null) return null;
    Map<String, dynamic>? row;
    try {
      row = await _client!
          .from('profiles')
          .select(
            'id, full_name, role, pharmacy_code, active, must_change_password',
          )
          .eq('id', user.id)
          .maybeSingle();
      _profileSchemaWarning = null;
    } catch (error) {
      if (!_isMissingMustChangePasswordColumn(error)) rethrow;

      // Algunas instalaciones del proyecto todavía tienen el esquema previo
      // a la migración 021. Reintentamos solo las columnas base para que el
      // usuario no quede atrapado en una pantalla de error; la migración de
      // reparación vuelve a habilitar la política de contraseña temporal.
      _profileSchemaWarning =
          'Supabase necesita aplicar la migración de contraseñas temporales.';
      row = await _client!
          .from('profiles')
          .select('id, full_name, role, pharmacy_code, active')
          .eq('id', user.id)
          .maybeSingle();
    }
    if (row == null) return null;
    return SupabaseUserProfile.fromMap(row);
  }

  bool _isMissingMustChangePasswordColumn(Object error) {
    final text = '$error';
    return text.contains('42703') &&
        text.contains('profiles.must_change_password');
  }

  Future<void> completePasswordChange({required String password}) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.auth.updateUser(UserAttributes(password: password));
    await _client!.rpc('complete_password_change');
  }

  Future<AdminBackendSnapshot> loadAdminSnapshot() async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }

    final zoneRows = await _client!
        .from('zones')
        .select('id, name, reference, active')
        .order('name');
    final pharmacyRows = await _client!
        .from('pharmacies')
        .select('code, name, zone_name, address, latitude, longitude, active')
        .order('code');
    final profileRows = await _client!
        .from('profiles')
        .select('id, username, full_name, role, pharmacy_code, phone, active')
        .order('full_name');
    final pharmacyProfileRows = await _client!
        .from('pharmacy_profiles')
        .select(
          'id, pharmacy_code, display_name, username, profile_role, active',
        )
        .order('display_name');
    final shiftRows = await _client!
        .from('shifts')
        .select(
          'id, courier_id, pharmacy_code, zone_id, scheduled_for, '
          'starts_at, ends_at, is_double, status, assignment_type',
        )
        .order('scheduled_for')
        .order('starts_at');

    const colors = [
      AppColors.primaryDark,
      AppColors.blue,
      AppColors.violet,
      AppColors.warning,
      AppColors.danger,
    ];
    final zonesById = <String, AdminZone>{};
    for (var index = 0; index < zoneRows.length; index++) {
      final row = zoneRows[index];
      final name = '${row['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      zonesById['${row['id']}'] = AdminZone(
        id: '${row['id']}',
        name: name,
        reference: '${row['reference'] ?? 'Cobertura por definir'}',
        pharmacyCount: 0,
        courierCount: 0,
        active: row['active'] == true,
        color: colors[index % colors.length],
      );
    }

    final pharmacies = <AdminPharmacy>[];
    for (final row in pharmacyRows) {
      final latitude = _adminDouble(row['latitude']);
      final longitude = _adminDouble(row['longitude']);
      pharmacies.add(
        AdminPharmacy(
          code: '${row['code'] ?? ''}',
          name: '${row['name'] ?? ''}',
          address: '${row['address'] ?? ''}'.trim().isEmpty
              ? 'Dirección pendiente'
              : '${row['address']}',
          zone: '${row['zone_name'] ?? 'Sin zona asignada'}',
          location: latitude == null || longitude == null
              ? MapsConfig.monteria
              : LatLng(latitude, longitude),
          active: row['active'] == true,
        ),
      );
    }

    final pharmacyProfilesByCode = <String, List<AdminPharmacyProfile>>{};
    for (final row in pharmacyProfileRows) {
      final code = '${row['pharmacy_code'] ?? ''}'.trim();
      if (code.isEmpty) continue;
      pharmacyProfilesByCode
          .putIfAbsent(code, () => <AdminPharmacyProfile>[])
          .add(
            AdminPharmacyProfile(
              id: '${row['id'] ?? ''}',
              displayName: '${row['display_name'] ?? ''}',
              username: '${row['username'] ?? ''}',
              role: '${row['profile_role'] ?? 'vendedor'}',
              active: row['active'] == true,
            ),
          );
    }

    final users = profileRows.map((row) {
      final id = '${row['id'] ?? ''}';
      final role = '${row['role'] ?? ''}';
      final pharmacyCode = row['pharmacy_code']?.toString();
      return AdminUser(
        id: id,
        name: '${row['full_name'] ?? 'Sin nombre'}',
        username: '${row['username'] ?? ''}'.trim().isEmpty
            ? 'Perfil Auth · ${id.substring(0, id.length < 8 ? id.length : 8)}'
            : '${row['username']}',
        phone: '${row['phone'] ?? ''}'.trim(),
        role: _adminRoleLabel(role),
        pharmacy: pharmacyCode ?? 'Sin farmacia asignada',
        active: row['active'] == true,
        pharmacyProfiles: pharmacyCode == null
            ? const []
            : pharmacyProfilesByCode[pharmacyCode] ?? const [],
      );
    }).toList();
    final profilesById = <String, Map<String, dynamic>>{
      for (final row in profileRows) '${row['id']}': row,
    };

    final shifts = shiftRows.map((row) {
      final zoneIdValue = row['zone_id']?.toString();
      final courierId = '${row['courier_id'] ?? ''}';
      final zone = zoneIdValue == null ? null : zonesById[zoneIdValue];
      final profile = profilesById[courierId];
      final isDouble = row['is_double'] == true;
      final isSupport = '${row['assignment_type'] ?? 'zone'}' == 'support';
      return AdminShift(
        id: '${row['id'] ?? ''}',
        // Nunca conviertas un UUID ausente en un texto vacío. Un valor vacío
        // puede terminar en el filtro de borrado y afectar cero filas sin
        // explicar al administrador qué ocurrió.
        courierId: courierId.trim().isEmpty ? null : courierId.trim(),
        zoneId: isSupport ? null : zoneIdValue,
        courierName: '${profile?['full_name'] ?? 'Domiciliario'}',
        hours:
            '${_adminTime(row['starts_at'])} – ${_adminTime(row['ends_at'])}',
        zone: isSupport ? adminSupportZone : zone?.name ?? 'Zona sin nombre',
        pharmacy: isSupport
            ? adminNoPharmacy
            : row['pharmacy_code']?.toString() ?? adminNoPharmacy,
        isDouble: isDouble,
        secondHours: isDouble ? adminDoubleHours : null,
        isSupport: isSupport,
        scheduledFor: _adminDate(row['scheduled_for']),
        color: zone?.color ?? AppColors.primaryDark,
      );
    }).toList();

    final pharmacyCounts = <String, int>{};
    for (final pharmacy in pharmacies) {
      pharmacyCounts.update(
        pharmacy.zone,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final courierCounts = <String, Set<String>>{};
    for (final shift in shifts) {
      courierCounts
          .putIfAbsent(shift.zone, () => <String>{})
          .add(shift.courierName);
    }
    final normalizedZones = zonesById.values
        .map(
          (zone) => zone.copyWith(
            pharmacyCount: pharmacyCounts[zone.name] ?? 0,
            courierCount: courierCounts[zone.name]?.length ?? 0,
          ),
        )
        .toList();

    return AdminBackendSnapshot(
      zones: normalizedZones,
      pharmacies: pharmacies,
      shifts: shifts,
      users: users,
    );
  }

  Future<List<AdminShift>> loadCourierShifts({
    required String courierId,
    required DateTime weekStart,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }

    final zoneRows = await _client!.from('zones').select('id, name, active');
    final zoneById = <String, AdminZone>{};
    const colors = [
      AppColors.primaryDark,
      AppColors.blue,
      AppColors.violet,
      AppColors.warning,
      AppColors.danger,
    ];
    for (var index = 0; index < zoneRows.length; index++) {
      final row = zoneRows[index];
      zoneById['${row['id']}'] = AdminZone(
        id: '${row['id']}',
        name: '${row['name'] ?? 'Zona sin nombre'}',
        reference: '',
        pharmacyCount: 0,
        courierCount: 0,
        active: row['active'] == true,
        color: colors[index % colors.length],
      );
    }

    final profileRow = await _client!
        .from('profiles')
        .select('full_name')
        .eq('id', courierId)
        .maybeSingle();
    final courierName = '${profileRow?['full_name'] ?? 'Domiciliario'}';
    final end = weekStart.add(const Duration(days: 7));
    final rows = await _client!
        .from('shifts')
        .select(
          'id, courier_id, pharmacy_code, zone_id, scheduled_for, '
          'starts_at, ends_at, is_double, status, assignment_type',
        )
        .eq('courier_id', courierId)
        .gte('scheduled_for', _adminDateIso(weekStart))
        .lt('scheduled_for', _adminDateIso(end))
        .order('scheduled_for')
        .order('starts_at');

    return rows.map((row) {
      final zoneId = row['zone_id']?.toString();
      final zone = zoneId == null ? null : zoneById[zoneId];
      final isDouble = row['is_double'] == true;
      final isSupport = '${row['assignment_type'] ?? 'zone'}' == 'support';
      return AdminShift(
        id: '${row['id'] ?? ''}',
        courierId: '${row['courier_id'] ?? courierId}',
        zoneId: isSupport ? null : zoneId,
        courierName: courierName,
        hours:
            '${_adminTime(row['starts_at'])} – ${_adminTime(row['ends_at'])}',
        zone: isSupport ? adminSupportZone : zone?.name ?? 'Zona sin nombre',
        pharmacy: isSupport
            ? adminNoPharmacy
            : row['pharmacy_code']?.toString() ?? adminNoPharmacy,
        isDouble: isDouble,
        secondHours: isDouble ? adminDoubleHours : null,
        isSupport: isSupport,
        scheduledFor: _adminDate(row['scheduled_for']),
        color: zone?.color ?? AppColors.primaryDark,
      );
    }).toList();
  }

  Future<void> saveAdminZone({
    required AdminZone zone,
    String? originalName,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final payload = <String, dynamic>{
      'name': zone.name,
      'reference': zone.reference,
      'active': zone.active,
    };
    if (originalName == null) {
      await _client!.from('zones').insert(payload);
    } else {
      final zoneFilter = zone.id == null
          ? _client!.from('zones').update(payload).eq('name', originalName)
          : _client!.from('zones').update(payload).eq('id', zone.id!);
      await zoneFilter;
      if (originalName != zone.name) {
        await _client!
            .from('pharmacies')
            .update({'zone_name': zone.name})
            .eq('zone_name', originalName);
      }
    }
  }

  Future<void> saveAdminPharmacy({
    required AdminPharmacy pharmacy,
    String? originalCode,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final payload = <String, dynamic>{
      'code': pharmacy.code,
      'name': pharmacy.name,
      'zone_name': pharmacy.zone,
      'address': pharmacy.address,
      'active': pharmacy.active,
    };
    if (originalCode == null) {
      await _client!.from('pharmacies').insert(payload);
    } else {
      await _client!
          .from('pharmacies')
          .update(payload)
          .eq('code', originalCode);
    }
  }

  Future<void> saveAdminProfile(AdminUser user) async {
    if (!await initialize() || !hasAuthenticatedUser || user.id == null) {
      throw StateError(
        'Este perfil no se puede actualizar desde la sesión actual.',
      );
    }
    final role = switch (user.role) {
      'Administrador' => 'admin',
      'Vendedor de farmacia' || 'Cuenta de farmacia' => 'pharmacy',
      _ => 'courier',
    };
    final pharmacy = user.pharmacy == 'Sin farmacia asignada'
        ? null
        : user.pharmacy;
    await _client!
        .from('profiles')
        .update({
          'full_name': user.name,
          'phone': user.phone.trim().isEmpty ? null : user.phone.trim(),
          'role': role,
          'pharmacy_code': pharmacy,
          'active': user.active,
        })
        .eq('id', user.id!);
    if (role == 'pharmacy' && user.pharmacy != 'Sin farmacia asignada') {
      await managePharmacyProfiles(
        pharmacyCode: user.pharmacy,
        profiles: user.pharmacyProfiles,
      );
    }
  }

  Future<AdminUser> createAdminUser({
    required AdminUser user,
    required String password,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final role = switch (user.role) {
      'Administrador' => 'admin',
      'Vendedor de farmacia' || 'Cuenta de farmacia' => 'pharmacy',
      _ => 'courier',
    };
    final pharmacyCode = user.pharmacy == 'Sin farmacia asignada'
        ? null
        : user.pharmacy;
    final response = await _client!.functions.invoke(
      'admin-create-user',
      body: {
        'username': user.username,
        'full_name': user.name,
        'phone': user.phone.trim().isEmpty ? null : user.phone.trim(),
        'role': role,
        'pharmacy_code': pharmacyCode,
        'password': password,
        'subprofiles': user.pharmacyProfiles
            .map(
              (profile) => {
                'display_name': profile.displayName,
                if (profile.username.trim().isNotEmpty)
                  'username': profile.username,
                'profile_role': 'vendedor',
                'active': profile.active,
              },
            )
            .toList(),
      },
    );
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      throw StateError('${data['error'] ?? 'No se pudo crear el usuario.'}');
    }
    final created = data['user'] is Map
        ? Map<String, dynamic>.from(data['user'] as Map)
        : <String, dynamic>{};
    final createdPharmacyCode = '${created['pharmacy_code'] ?? user.pharmacy}';
    final createdPharmacyProfiles = (data['pharmacy_profiles'] is List
        ? (data['pharmacy_profiles'] as List)
              .whereType<Map>()
              .map(
                (row) => AdminPharmacyProfile.fromMap(
                  Map<String, dynamic>.from(row),
                ),
              )
              .toList()
        : user.pharmacyProfiles);
    return AdminUser(
      id: '${created['id'] ?? ''}',
      name: '${created['full_name'] ?? user.name}',
      username: '${created['username'] ?? user.username}',
      role: user.role,
      pharmacy: createdPharmacyCode,
      active: created['active'] == true,
      temporaryPassword:
          data['temporary_password']?.toString() ?? user.temporaryPassword,
      pharmacyProfiles: createdPharmacyProfiles,
    );
  }

  Future<void> managePharmacyProfiles({
    required String pharmacyCode,
    required List<AdminPharmacyProfile> profiles,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final response = await _client!.functions.invoke(
      'admin-manage-pharmacy-profiles',
      body: {
        'pharmacy_code': pharmacyCode,
        'profiles': profiles
            .map(
              (profile) => {
                if (profile.id != null && profile.id!.isNotEmpty)
                  'id': profile.id,
                'display_name': profile.displayName,
                if (profile.username.trim().isNotEmpty)
                  'username': profile.username,
                'profile_role': 'vendedor',
                'active': profile.active,
              },
            )
            .toList(),
      },
    );
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      throw StateError(
        '${data['error'] ?? 'No se pudieron guardar los perfiles de farmacia.'}',
      );
    }
  }

  Future<void> resetAdminUserPassword({
    required String userId,
    required String password,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final response = await _client!.functions.invoke(
      'admin-reset-user-password',
      body: {'user_id': userId, 'password': password},
    );
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      throw StateError(
        '${data['error'] ?? 'No se pudo restablecer la contraseña.'}',
      );
    }
  }

  Future<void> saveAdminShift({
    required AdminShift shift,
    String? originalId,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final zoneRow = shift.isSupport
        ? null
        : await _client!
              .from('zones')
              .select('id')
              .eq('name', shift.zone)
              .maybeSingle();
    if (!shift.isSupport && zoneRow == null) {
      throw StateError('La zona seleccionada no existe.');
    }

    final profileRows = await _client!
        .from('profiles')
        .select('id, full_name')
        .eq('role', 'courier')
        .eq('active', true);
    Map<String, dynamic>? courierRow;
    for (final row in profileRows) {
      if ('${row['id']}' == shift.courierId ||
          '${row['full_name']}'.trim() == shift.courierName.trim()) {
        courierRow = row;
        break;
      }
    }
    if (courierRow == null) {
      throw StateError(
        'El domiciliario debe existir como perfil activo antes de asignar un turno.',
      );
    }
    final times = RegExp(r'(\d{1,2}:\d{2})')
        .allMatches(shift.hours)
        .map((match) => match.group(1)!)
        .toList();
    if (times.length < 2) {
      throw StateError('El horario del turno no es válido.');
    }
    final payload = <String, dynamic>{
      'courier_id': courierRow['id'],
      'pharmacy_code': shift.isSupport || shift.pharmacy == adminNoPharmacy
          ? null
          : shift.pharmacy,
      'zone_id': shift.isSupport ? null : zoneRow!['id'],
      'assignment_type': shift.isSupport ? 'support' : 'zone',
      'scheduled_for': _adminDateIso(shift.scheduledFor),
      'starts_at': times.first,
      'ends_at': times.last,
      'is_double': shift.isDouble,
      'status': 'scheduled',
      'created_by': _client!.auth.currentUser!.id,
    };
    if (originalId == null || originalId.isEmpty) {
      await _client!.from('shifts').insert(payload);
    } else {
      await _client!.from('shifts').update(payload).eq('id', originalId);
    }
  }

  Future<void> saveAdminShifts({required List<AdminShift> shifts}) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    if (shifts.isEmpty) return;

    final zoneRows = await _client!.from('zones').select('id, name');
    final profileRows = await _client!
        .from('profiles')
        .select('id, full_name')
        .eq('role', 'courier')
        .eq('active', true);
    final zonesByName = <String, dynamic>{
      for (final row in zoneRows) '${row['name']}': row['id'],
    };
    final profilesById = <String, Map<String, dynamic>>{
      for (final row in profileRows) '${row['id']}': row,
    };
    final payloads = <Map<String, dynamic>>[];

    for (final shift in shifts) {
      final zoneId = shift.isSupport ? null : zonesByName[shift.zone];
      if (!shift.isSupport && zoneId == null) {
        throw StateError('La zona ${shift.zone} no existe en Supabase.');
      }
      Map<String, dynamic>? courierRow;
      if (shift.courierId != null) {
        courierRow = profilesById[shift.courierId];
      }
      courierRow ??= profileRows.cast<Map<String, dynamic>?>().firstWhere(
        (row) => '${row?['full_name']}'.trim() == shift.courierName.trim(),
        orElse: () => null,
      );
      if (courierRow == null) {
        throw StateError(
          'El domiciliario ${shift.courierName} no está activo en Supabase.',
        );
      }
      final times = RegExp(r'(\d{1,2}:\d{2})')
          .allMatches(shift.hours)
          .map((match) => match.group(1)!)
          .toList();
      if (times.length < 2) {
        throw StateError('El horario de ${shift.courierName} no es válido.');
      }
      payloads.add({
        'courier_id': courierRow['id'],
        'pharmacy_code': shift.isSupport || shift.pharmacy == adminNoPharmacy
            ? null
            : shift.pharmacy,
        'zone_id': zoneId,
        'assignment_type': shift.isSupport ? 'support' : 'zone',
        'scheduled_for': _adminDateIso(shift.scheduledFor),
        'starts_at': times.first,
        'ends_at': times.last,
        'is_double': shift.isDouble,
        'status': 'scheduled',
        'created_by': _client!.auth.currentUser!.id,
      });
    }

    await _client!
        .from('shifts')
        .upsert(
          payloads,
          onConflict: 'courier_id,scheduled_for,starts_at,ends_at,pharmacy_key',
        );
  }

  Future<void> deleteAdminShift({required String shiftId}) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.from('shifts').delete().eq('id', shiftId);
  }

  Future<int> deleteAdminShiftsForCourierWeek({
    required String courierId,
    required DateTime weekStart,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final end = weekStart.add(const Duration(days: 7));
    final existing = await _client!
        .from('shifts')
        .select('id')
        .eq('courier_id', courierId)
        .gte('scheduled_for', _adminDateIso(weekStart))
        .lt('scheduled_for', _adminDateIso(end));
    if (existing.isEmpty) return 0;

    final deleted = await _client!
        .from('shifts')
        .delete()
        .eq('courier_id', courierId)
        .gte('scheduled_for', _adminDateIso(weekStart))
        .lt('scheduled_for', _adminDateIso(end))
        .select('id');
    if (deleted.length != existing.length) {
      throw StateError(
        'Supabase no confirmó el borrado completo de la semana. '
        'Revisa la política RLS de turnos para administradores.',
      );
    }
    return deleted.length;
  }

  Future<CourierFeeSummary?> loadCourierFeeSummary({
    required DateTime weekStart,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return null;
    final rows = await _client!.rpc(
      'get_courier_fee_summary',
      params: {'requested_week_start': _adminDateIso(weekStart)},
    );
    if (rows is List && rows.isNotEmpty) {
      return CourierFeeSummary.fromMap(
        Map<String, dynamic>.from(rows.first as Map),
      );
    }
    if (rows is Map) {
      return CourierFeeSummary.fromMap(Map<String, dynamic>.from(rows));
    }
    return null;
  }

  Future<List<AdminCourierFeeSummary>> loadAdminCourierFeeSummary({
    required DateTime weekStart,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return const [];
    final rows = await _client!.rpc(
      'get_admin_courier_fee_summary',
      params: {'requested_week_start': _adminDateIso(weekStart)},
    );
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map(
          (row) =>
              AdminCourierFeeSummary.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<void> recordCourierFeePayment({
    required String courierId,
    required DateTime weekStart,
    required double amount,
    required String paymentMethod,
    String? note,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.rpc(
      'record_courier_fee_payment',
      params: {
        'requested_courier_id': courierId,
        'requested_week_start': _adminDateIso(weekStart),
        'requested_amount': amount,
        'requested_payment_method': paymentMethod,
        'requested_note': note?.trim().isEmpty == true ? null : note?.trim(),
      },
    );
  }

  Future<List<CourierPharmacyBreakdown>> loadCourierPharmacyBreakdown() async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError(
        'No hay una sesión autenticada de Supabase para consultar el desglose.',
      );
    }
    final rows = await _client!.rpc('get_courier_pharmacy_breakdown');
    if (rows is! List) {
      throw const FormatException(
        'Supabase devolvió un desglose de domicilios no válido.',
      );
    }
    return rows
        .whereType<Map>()
        .map(
          (row) =>
              CourierPharmacyBreakdown.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<List<PharmacyCourierBreakdown>> loadPharmacyCourierBreakdown({
    required String pharmacyCode,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return const [];
    final rows = await _client!.rpc(
      'get_pharmacy_courier_breakdown',
      params: {'requested_pharmacy_code': pharmacyCode},
    );
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map(
          (row) =>
              PharmacyCourierBreakdown.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<void> updateCourierFeeSettings({
    required double dailyAmount,
    required double doubleShiftSurcharge,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.rpc(
      'update_courier_fee_settings',
      params: {
        'requested_daily_amount': dailyAmount,
        'requested_double_shift_surcharge': doubleShiftSurcharge,
      },
    );
  }

  double? _adminDouble(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

  DateTime _adminDate(dynamic value) =>
      DateTime.tryParse('${value ?? ''}') ?? _adminToday();

  String _adminDateIso(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _adminTime(dynamic value) {
    final raw = '${value ?? ''}';
    final parts = raw.split(':');
    if (parts.length < 2) return raw;
    return '${parts[0].padLeft(2, '0')}:${parts[1].padLeft(2, '0')}';
  }

  String _adminRoleLabel(String role) => switch (role) {
    'admin' => 'Administrador',
    'pharmacy' => 'Cuenta de farmacia',
    _ => 'Domiciliario',
  };

  Future<void> signOut() async {
    if (!await initialize()) return;
    await _client!.auth.signOut();
  }

  Future<void> upsertPushToken({
    required String token,
    required String platform,
    String? alertSound,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return;
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return;
    final normalizedPlatform = switch (platform) {
      'ios' => 'ios',
      'web' => 'web',
      _ => 'android',
    };
    // La función `register_push_token` (migración 038) reasigna el token si
    // el teléfono pasó de un usuario a otro, algo que RLS no permite con un
    // upsert directo. Mientras la migración no esté aplicada se usa el upsert.
    try {
      await _client!.rpc(
        'register_push_token',
        params: {
          'p_token': cleanToken,
          'p_platform': normalizedPlatform,
          'p_alert_sound': alertSound,
        },
      );
      return;
    } on PostgrestException catch (error) {
      final missingFunction = error.code == 'PGRST202' || error.code == '42883';
      if (!missingFunction) rethrow;
    }
    await _client!.from('push_tokens').upsert({
      'user_id': _client!.auth.currentUser!.id,
      'token': cleanToken,
      'platform': normalizedPlatform,
      'active': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }

  Future<void> removePushToken(String token) async {
    if (!await initialize() || !hasAuthenticatedUser) return;
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return;
    await _client!
        .from('push_tokens')
        .delete()
        .eq('user_id', _client!.auth.currentUser!.id)
        .eq('token', cleanToken);
  }

  Future<bool> initialize() {
    if (isReady) return Future.value(true);
    if (!SupabaseConfig.isConfigured) return Future.value(false);
    final currentInitialization = _initializing;
    if (currentInitialization != null) return currentInitialization;
    final initialization = _initialize();
    _initializing = initialization;
    return initialization.whenComplete(() => _initializing = null);
  }

  Future<bool> _initialize() async {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.publishableKey,
        authOptions: const FlutterAuthClientOptions(
          persistSession: true,
          autoRefreshToken: true,
        ),
      );
      _client = Supabase.instance.client;
      return true;
    } catch (_) {
      // Hot reload o una inicialización repetida pueden producir este caso;
      // si el cliente global ya existe, se puede reutilizar de forma segura.
      try {
        _client = Supabase.instance.client;
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  Future<Stream<List<Delivery>>?> watchDeliveries() async {
    if (!await initialize() || !hasAuthenticatedUser) return null;
    try {
      final stream = _client!
          .from('deliveries')
          .stream(primaryKey: ['id'])
          .order('created_at');
      return stream.map((rows) {
        return rows.map((row) {
          final data = <dynamic, dynamic>{
            'paymentMethod': row['payment_method'],
            'storeName': 'FN ${row['pharmacy_code'] ?? ''}'.trim(),
            'storeAddress': row['pharmacy_code'] == null
                ? 'Dirección por confirmar'
                : 'Farmacia FN ${row['pharmacy_code']}',
            'destination': row['neighborhood'] ?? 'Destino por confirmar',
            'destinationAddress': row['address'] ?? 'Dirección por confirmar',
            'recipientName': row['client_name'] ?? 'Cliente',
            'recipientPhone': row['client_phone'] ?? 'Sin teléfono',
            'paymentAmount': row['payment_amount'],
            'courierEarnings': row['courier_earnings'],
            'totalToCollect': row['total_to_collect'],
            'cashExpected': row['cash_expected'],
            'cashReceived': row['cash_received'],
            'distance': row['distance_km'],
            'estimatedTime': row['estimated_minutes'],
            'kind': row['kind'] ?? 'pharmacyToHome',
            'status': row['status'] ?? 'offered',
            'note': row['notes'] ?? 'Sin instrucciones adicionales.',
            'origin': {
              'latitude': row['origin_latitude'],
              'longitude': row['origin_longitude'],
            },
            'destinationPoint': {
              'latitude': row['destination_latitude'],
              'longitude': row['destination_longitude'],
            },
            'serviceType': row['service_type'],
            'crossCount': row['cross_count'],
            'purchaseCount': row['purchase_count'],
            'changeOfMoney': row['change_of_money'],
            'hasDataphone': row['has_dataphone'],
            'productSummary': row['product_summary'],
            'pickupStops': row['pickup_stops'],
            'destinationOptions': row['destination_options'],
            'pharmacyCode': row['pharmacy_code'],
            'neighborhood': row['neighborhood'],
            'addressReference': row['address_reference'],
            'approvalPending': row['approval_pending'],
            'approvalCourierName': row['approval_courier_name'],
            'acceptedCourierId': row['accepted_courier_id'],
            'assignedAsSupport': row['assigned_as_support'],
            'deliveryOutcome': row['delivery_outcome'],
            'priorityUntil': row['priority_until'],
            'expiresAt': row['expires_at'],
          };
          return RealtimeOperationsService.instance._deliveryFromMap(
            '${row['id']}',
            data,
          );
        }).toList();
      });
    } catch (_) {
      return null;
    }
  }

  Future<Stream<List<DeliveryChatMessage>>?> watchDeliveryChat({
    required String deliveryId,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return null;
    try {
      final stream = _client!
          .from('delivery_chat_messages')
          .stream(primaryKey: ['id'])
          .eq('delivery_id', deliveryId)
          .order('created_at');
      return stream.map(
        (rows) => rows
            .map(
              (row) =>
                  DeliveryChatMessage.fromMap(Map<String, dynamic>.from(row)),
            )
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<DeliveryChatMessage> sendDeliveryChat({
    required String deliveryId,
    required String body,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    final cleanBody = body.trim();
    if (cleanBody.isEmpty) {
      throw ArgumentError('El mensaje no puede estar vacío.');
    }
    final row = await _client!
        .from('delivery_chat_messages')
        .insert({
          'delivery_id': deliveryId,
          'sender_id': _client!.auth.currentUser!.id,
          'body': cleanBody,
        })
        .select('*')
        .single();
    final message = DeliveryChatMessage.fromMap(Map<String, dynamic>.from(row));
    // El tiempo real cubre la sesión abierta; la función Edge cubre la web
    // en segundo plano y los dispositivos que tienen push registrado. Un
    // fallo del proveedor de notificaciones nunca debe hacer fallar el chat.
    unawaited(() async {
      try {
        await _client!.functions.invoke(
          'send-push-notification',
          body: {
            'event': 'chat_message',
            'delivery_id': deliveryId,
            'message_id': message.id,
          },
        );
      } catch (_) {
        // La notificación es complementaria; el mensaje ya quedó guardado.
      }
    }());
    return message;
  }

  Future<DeliveryEquivalent?> loadDeliveryEquivalent({
    required String deliveryId,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    var row = await _client!
        .from('delivery_equivalents')
        .select('*')
        .eq('delivery_id', deliveryId)
        .maybeSingle();
    if (row == null) {
      await _client!.rpc(
        'ensure_delivery_equivalent',
        params: {'requested_delivery_id': deliveryId},
      );
      row = await _client!
          .from('delivery_equivalents')
          .select('*')
          .eq('delivery_id', deliveryId)
          .maybeSingle();
    }
    if (row == null) return null;
    return DeliveryEquivalent.fromMap(Map<String, dynamic>.from(row));
  }

  Future<Map<String, String>> loadCourierEquivalentStatuses() async {
    if (!await initialize() || !hasAuthenticatedUser) return const {};
    final courierId = currentUserId;
    if (courierId == null || courierId.isEmpty) return const {};
    final rows = await _client!
        .from('delivery_equivalents')
        .select('delivery_id, status')
        .eq('courier_id', courierId);
    return <String, String>{
      for (final row in rows)
        '${row['delivery_id'] ?? ''}': '${row['status'] ?? 'draft'}',
    }..removeWhere((key, value) => key.isEmpty);
  }

  Future<String> loadEquivalentPaymentTiming() async {
    if (!await initialize() || !hasAuthenticatedUser) {
      return 'end_of_shift';
    }
    final value = await _client!.rpc('get_equivalent_payment_timing');
    final timing = '$value'.trim();
    return timing == 'immediate' ? 'immediate' : 'end_of_shift';
  }

  Future<void> updateEquivalentPaymentTiming({required String timing}) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.rpc(
      'update_equivalent_payment_timing',
      params: {'requested_timing': timing},
    );
  }

  Future<void> signDeliveryEquivalent({
    required String equivalentId,
    required String signatureName,
    required String signatureImage,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError('La sesión real de Supabase no está disponible.');
    }
    await _client!.rpc(
      'sign_delivery_equivalent_with_image',
      params: {
        'requested_equivalent_id': equivalentId,
        'requested_signature_name': signatureName.trim(),
        'requested_signature_image': signatureImage,
      },
    );
  }

  Future<void> updateDeliveryStatus({
    required String deliveryId,
    required DeliveryStatus status,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) {
      throw StateError(
        'No hay una sesión activa de Supabase para guardar el domicilio.',
      );
    }
    await _client!.rpc(
      'transition_delivery_status',
      params: {
        'requested_delivery_id': deliveryId,
        'requested_status': status.name,
      },
    );
  }

  Future<bool> requestDeliveryApproval({required String deliveryId}) async {
    if (!await initialize() || !hasAuthenticatedUser) return false;
    final result = await _client!.rpc(
      'request_delivery_approval',
      params: {'requested_delivery_id': deliveryId},
    );
    return result == true || '$result'.toLowerCase() == 'true';
  }

  Future<bool> approveDeliveryRequest({required String deliveryId}) async {
    if (!await initialize() || !hasAuthenticatedUser) return false;
    final result = await _client!.rpc(
      'approve_delivery_request',
      params: {'requested_delivery_id': deliveryId},
    );
    return result == true || '$result'.toLowerCase() == 'true';
  }

  Future<bool> rejectDeliveryRequest({required String deliveryId}) async {
    if (!await initialize() || !hasAuthenticatedUser) return false;
    final result = await _client!.rpc(
      'reject_delivery_request',
      params: {'requested_delivery_id': deliveryId},
    );
    return result == true || '$result'.toLowerCase() == 'true';
  }

  Future<bool> acceptDelivery({
    required String deliveryId,
    bool asSupport = false,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return false;
    final result = await _client!.rpc(
      'accept_delivery',
      params: {
        'requested_delivery_id': deliveryId,
        'requested_as_support': asSupport,
      },
    );
    return result == true || '$result'.toLowerCase() == 'true';
  }

  Future<void> publishCourierConnection({
    required String courierId,
    required bool connected,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final payload = <String, dynamic>{
        'courier_id': _client!.auth.currentUser!.id,
        'connected': connected,
        'last_seen_at': now,
        'updated_at': now,
      };
      if (courierBasePharmacyCode.isNotEmpty) {
        payload['base_pharmacy_code'] = courierBasePharmacyCode;
      }
      await _client!.from('courier_presence').upsert(payload);
    } catch (_) {}
  }

  Future<void> publishCourierLocation({
    required String courierId,
    required Position position,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final payload = <String, dynamic>{
        'courier_id': _client!.auth.currentUser!.id,
        'connected': true,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'heading': position.heading,
        'speed': position.speed,
        'last_seen_at': now,
        'updated_at': now,
      };
      if (courierBasePharmacyCode.isNotEmpty) {
        payload['base_pharmacy_code'] = courierBasePharmacyCode;
      }
      await _client!.from('courier_presence').upsert(payload);
    } catch (_) {}
  }
}

/// Mantiene el código de pantallas independiente del proveedor de backend.
/// Supabase es la ruta de producción de la etapa 1; Firebase queda como
/// compatibilidad temporal para las compilaciones anteriores.
class OperationsBackend {
  OperationsBackend._();

  static final instance = OperationsBackend._();
  static const courierId = RealtimeOperationsService.courierId;

  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) => SupabaseOperationsService.instance.signInWithPassword(
    email: email,
    password: password,
  );

  Future<SupabaseUserProfile?> loadCurrentProfile() =>
      SupabaseOperationsService.instance.loadCurrentProfile();

  Future<void> completePasswordChange({required String password}) =>
      SupabaseOperationsService.instance.completePasswordChange(
        password: password,
      );

  Future<void> resetAdminUserPassword({
    required String userId,
    required String password,
  }) => SupabaseOperationsService.instance.resetAdminUserPassword(
    userId: userId,
    password: password,
  );

  Future<void> signOut() async {
    await BackgroundNotificationService.unregisterCurrentDevice();
    if (!SupabaseConfig.isConfigured) return;
    await SupabaseOperationsService.instance.signOut();
  }

  Future<void> registerPushNotifications() =>
      BackgroundNotificationService.registerForCurrentUser();

  Future<bool> requestNotificationPermission() =>
      BackgroundNotificationService.requestPermissionForEntry();

  Future<void> publishCourierLocation({
    required String courierId,
    required Position position,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.publishCourierLocation(
          courierId: courierId,
          position: position,
        )
      : RealtimeOperationsService.instance.publishCourierLocation(
          courierId: courierId,
          position: position,
        );

  Future<void> publishCourierConnection({
    required String courierId,
    required bool connected,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.publishCourierConnection(
          courierId: courierId,
          connected: connected,
        )
      : RealtimeOperationsService.instance.publishCourierConnection(
          courierId: courierId,
          connected: connected,
        );

  Future<void> updateDeliveryStatus({
    required String deliveryId,
    required DeliveryStatus status,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.updateDeliveryStatus(
          deliveryId: deliveryId,
          status: status,
        )
      : RealtimeOperationsService.instance.updateDeliveryStatus(
          deliveryId: deliveryId,
          status: status,
        );

  Future<bool> requestDeliveryApproval({required String deliveryId}) =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.requestDeliveryApproval(
          deliveryId: deliveryId,
        )
      : Future.value(false);

  Future<bool> approveDeliveryRequest({required String deliveryId}) =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.approveDeliveryRequest(
          deliveryId: deliveryId,
        )
      : Future.value(false);

  Future<bool> rejectDeliveryRequest({required String deliveryId}) =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.rejectDeliveryRequest(
          deliveryId: deliveryId,
        )
      : Future.value(false);

  Future<Stream<List<Delivery>>?> watchDeliveries() =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.watchDeliveries()
      : RealtimeOperationsService.instance.watchDeliveries();

  Future<Stream<List<DeliveryChatMessage>>?> watchDeliveryChat({
    required String deliveryId,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.watchDeliveryChat(
          deliveryId: deliveryId,
        )
      : Future.value(null);

  Future<DeliveryChatMessage> sendDeliveryChat({
    required String deliveryId,
    required String body,
  }) => SupabaseOperationsService.instance.sendDeliveryChat(
    deliveryId: deliveryId,
    body: body,
  );

  Future<DeliveryEquivalent?> loadDeliveryEquivalent({
    required String deliveryId,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadDeliveryEquivalent(
          deliveryId: deliveryId,
        )
      : Future.value(null);

  Future<void> signDeliveryEquivalent({
    required String equivalentId,
    required String signatureName,
    required String signatureImage,
  }) => SupabaseOperationsService.instance.signDeliveryEquivalent(
    equivalentId: equivalentId,
    signatureName: signatureName,
    signatureImage: signatureImage,
  );

  Future<Map<String, String>> loadCourierEquivalentStatuses() =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadCourierEquivalentStatuses()
      : Future.value(const <String, String>{});

  Future<String> loadEquivalentPaymentTiming() => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadEquivalentPaymentTiming()
      : Future.value('end_of_shift');

  Future<void> updateEquivalentPaymentTiming({required String timing}) =>
      SupabaseOperationsService.instance.updateEquivalentPaymentTiming(
        timing: timing,
      );

  String? get currentUserId => SupabaseOperationsService.instance.currentUserId;

  Future<List<AdminShift>> loadCourierShifts({
    required String courierId,
    required DateTime weekStart,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadCourierShifts(
          courierId: courierId,
          weekStart: weekStart,
        )
      : Future.value(
          demoAdminShifts
              .where(
                (shift) =>
                    shift.courierName == 'Juan Sebastián Ríos' &&
                    !DateUtils.dateOnly(shift.scheduledFor)
                        .isBefore(DateUtils.dateOnly(weekStart)) &&
                    DateUtils.dateOnly(shift.scheduledFor).isBefore(
                      DateUtils.dateOnly(weekStart)
                          .add(const Duration(days: 7)),
                    ),
              )
              .toList(),
        );

  Future<CourierFeeSummary?> loadCourierFeeSummary({
    required DateTime weekStart,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadCourierFeeSummary(
          weekStart: weekStart,
        )
      : Future.value(null);

  Future<List<AdminCourierFeeSummary>> loadAdminCourierFeeSummary({
    required DateTime weekStart,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadAdminCourierFeeSummary(
          weekStart: weekStart,
        )
      : Future.value(const []);

  Future<void> recordCourierFeePayment({
    required String courierId,
    required DateTime weekStart,
    required double amount,
    required String paymentMethod,
    String? note,
  }) => SupabaseOperationsService.instance.recordCourierFeePayment(
    courierId: courierId,
    weekStart: weekStart,
    amount: amount,
    paymentMethod: paymentMethod,
    note: note,
  );

  Future<List<CourierPharmacyBreakdown>> loadCourierPharmacyBreakdown() =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadCourierPharmacyBreakdown()
      : Future.error(
          StateError(
            'Supabase no está configurado en esta versión de la aplicación.',
          ),
        );

  Future<List<PharmacyCourierBreakdown>> loadPharmacyCourierBreakdown({
    required String pharmacyCode,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.loadPharmacyCourierBreakdown(
          pharmacyCode: pharmacyCode,
        )
      : Future.value(const []);

  Future<void> updateCourierFeeSettings({
    required double dailyAmount,
    required double doubleShiftSurcharge,
  }) => SupabaseOperationsService.instance.updateCourierFeeSettings(
    dailyAmount: dailyAmount,
    doubleShiftSurcharge: doubleShiftSurcharge,
  );

  Future<bool> acceptDelivery({
    required String deliveryId,
    bool asSupport = false,
  }) => SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.acceptDelivery(
          deliveryId: deliveryId,
          asSupport: asSupport,
        )
      : Future.value(false);
}

enum DeliveryKind {
  pharmacyToHome,
  storeToStore,
  externalPurchase,
  pharmacyCross,
  combinedService,
  overflow,
}

enum PaymentMethod { cash, card, qr }

enum DeliveryStatus { offered, accepted, pickedUp, delivered, notDelivered }

extension DeliveryKindX on DeliveryKind {
  String get label => switch (this) {
    DeliveryKind.pharmacyToHome => 'Domicilio',
    DeliveryKind.storeToStore => 'Traslado',
    DeliveryKind.externalPurchase => 'Compra externa',
    DeliveryKind.pharmacyCross => 'Cruce',
    DeliveryKind.combinedService => 'Servicio combinado',
    DeliveryKind.overflow => 'Desborde',
  };

  IconData get icon => switch (this) {
    DeliveryKind.pharmacyToHome => Icons.shopping_bag_outlined,
    DeliveryKind.storeToStore => Icons.swap_horiz_rounded,
    DeliveryKind.externalPurchase => Icons.shopping_cart_outlined,
    DeliveryKind.pharmacyCross => Icons.swap_horiz_rounded,
    DeliveryKind.combinedService => Icons.route_rounded,
    DeliveryKind.overflow => Icons.bolt_rounded,
  };

  Color get color => switch (this) {
    DeliveryKind.pharmacyToHome => AppColors.primary,
    DeliveryKind.storeToStore => AppColors.blue,
    DeliveryKind.externalPurchase => AppColors.violet,
    DeliveryKind.pharmacyCross => AppColors.blue,
    DeliveryKind.combinedService => AppColors.primaryDark,
    DeliveryKind.overflow => AppColors.warning,
  };
}

extension PaymentMethodX on PaymentMethod {
  String get label => switch (this) {
    PaymentMethod.cash => 'Efectivo',
    // Regla farmanorte: tarjeta y QR se cobran con el datáfono.
    PaymentMethod.card => 'Datáfono',
    PaymentMethod.qr => 'Datáfono',
  };

  IconData get icon => switch (this) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.card => Icons.point_of_sale_outlined,
    PaymentMethod.qr => Icons.point_of_sale_outlined,
  };

  Color get color => switch (this) {
    PaymentMethod.cash => AppColors.primaryDark,
    PaymentMethod.card => AppColors.primary,
    PaymentMethod.qr => AppColors.primary,
  };
}

extension DeliveryStatusX on DeliveryStatus {
  String get label => switch (this) {
    DeliveryStatus.offered => 'Publicado',
    DeliveryStatus.accepted => 'Aceptado',
    DeliveryStatus.pickedUp => 'En recorrido',
    DeliveryStatus.delivered => 'Entregado',
    DeliveryStatus.notDelivered => 'No entregado',
  };
}

class DeliveryAddress {
  const DeliveryAddress({
    required this.label,
    required this.address,
    required this.point,
  });

  final String label;
  final String address;
  final LatLng point;
}

class DeliveryPickupStop {
  const DeliveryPickupStop({
    required this.title,
    required this.address,
    required this.point,
    required this.label,
  });

  final String title;
  final String address;
  final LatLng point;
  final String label;
}

class DeliveryCrossRoute {
  const DeliveryCrossRoute({
    required this.originCode,
    required this.destinationCode,
  });

  final String originCode;
  final String destinationCode;

  String get label =>
      '${formatPharmacyCodeLabel(originCode)} → '
      '${formatPharmacyCodeLabel(destinationCode)}';
}

class DeliveryServicePlan {
  const DeliveryServicePlan({
    this.hasDomicilio = true,
    this.crossCount = 0,
    this.purchaseCount = 0,
    this.changeOfMoney = false,
    this.hasDataphone = false,
  });

  final bool hasDomicilio;
  final int crossCount;
  final int purchaseCount;
  final bool changeOfMoney;
  final bool hasDataphone;

  String get label {
    if (changeOfMoney) return 'Cambio de menudo';
    if (!hasDomicilio && purchaseCount == 1 && crossCount == 0) {
      return 'Compra';
    }
    if (!hasDomicilio && crossCount > 0 && purchaseCount == 0) {
      return crossCount == 1 ? 'Cruce' : 'Cruce x$crossCount';
    }
    if (!hasDomicilio) return 'Servicio especial';
    if (crossCount == 0 && purchaseCount == 0) {
      return hasDataphone ? 'Domicilio con datáfono' : 'Domicilio normal';
    }
    if (crossCount == 0 && purchaseCount == 1) {
      return hasDataphone
          ? 'Domicilio con compra y datáfono'
          : 'Domicilio con compra';
    }
    if (crossCount == 1 && purchaseCount == 0) {
      return hasDataphone
          ? 'Domicilio, cruce y datáfono'
          : 'Domicilio con un cruce';
    }
    if (crossCount == 2 && purchaseCount == 0) {
      return hasDataphone
          ? 'Domicilio, dos cruces y datáfono'
          : 'Domicilio con dos cruces';
    }
    if (crossCount == 1 && purchaseCount == 1) {
      return hasDataphone
          ? 'Domicilio, cruce, compra y datáfono'
          : 'Domicilio con cruce y compra';
    }
    if (crossCount == 1 && purchaseCount == 2 && hasDataphone) {
      return 'Domicilio, dos compras, cruce y datáfono';
    }
    if (crossCount == 3 && purchaseCount == 0 && hasDataphone) {
      return 'Domicilio, tres cruces y datáfono';
    }
    return 'Domicilio especial';
  }

  int get fee {
    if (changeOfMoney) return 4000;
    if (!hasDomicilio && purchaseCount == 1 && crossCount == 0) return 4000;
    if (!hasDomicilio && crossCount == 1 && purchaseCount == 0) return 3000;

    if (hasDomicilio) {
      if (purchaseCount == 0) {
        if (crossCount == 0) return hasDataphone ? 6000 : 5000;
        if (crossCount == 1) return hasDataphone ? 8000 : 7000;
        if (crossCount == 2) return hasDataphone ? 10000 : 9000;
        if (crossCount == 3 && hasDataphone) return 13000;
      }
      if (purchaseCount == 1 && crossCount == 0) {
        return hasDataphone ? 8000 : 7000;
      }
      if (purchaseCount == 1 && crossCount == 1) {
        return hasDataphone ? 11000 : 9000;
      }
      if (purchaseCount == 2 && crossCount == 1 && hasDataphone) {
        return 13000;
      }

      // Extiende la tabla para cantidades que todavía no aparecen de forma
      // explícita, manteniendo la progresión de los cruces adicionales.
      return 5000 +
          crossCount * 2000 +
          purchaseCount * 2000 +
          (hasDataphone ? 1000 : 0);
    }

    return purchaseCount * 4000 + crossCount * 3000 + (hasDataphone ? 1000 : 0);
  }

  String get ruleNote =>
      'Tarifa oficial farmanorte · $label · ${_money(fee.toDouble())}';

  factory DeliveryServicePlan.fromMap(
    Map<dynamic, dynamic> data, {
    DeliveryKind kind = DeliveryKind.pharmacyToHome,
  }) {
    final rawType = (data['serviceType'] ?? data['service'] ?? '')
        .toString()
        .toLowerCase();
    int countFromText(String singular, String plural) {
      if (rawType.contains('tres $plural')) return 3;
      if (rawType.contains('dos $plural')) return 2;
      if (rawType.contains(singular)) return 1;
      return 0;
    }

    final bool hasDomicilio = data['hasDomicilio'] is bool
        ? data['hasDomicilio'] as bool
        : rawType.isEmpty
        ? switch (kind) {
            DeliveryKind.externalPurchase ||
            DeliveryKind.pharmacyCross => false,
            _ => true,
          }
        : rawType.contains('domicilio');
    final parsedCrossCount = data['crossCount'] is num
        ? (data['crossCount'] as num).round()
        : int.tryParse((data['crossCount'] ?? 0).toString()) ?? 0;
    final parsedPurchaseCount = data['purchaseCount'] is num
        ? (data['purchaseCount'] as num).round()
        : int.tryParse((data['purchaseCount'] ?? 0).toString()) ?? 0;
    final crossCount = parsedCrossCount > 0
        ? parsedCrossCount
        : countFromText('cruce', 'cruces');
    final purchaseCount = parsedPurchaseCount > 0
        ? parsedPurchaseCount
        : countFromText('compra', 'compras');
    final changeOfMoney =
        data['changeOfMoney'] == true ||
        rawType.contains('menudo') ||
        rawType.contains('cambio');
    final hasDataphone =
        data['hasDataphone'] == true ||
        data['dataphone'] == true ||
        data['platform'] == true ||
        rawType.contains('datáfono') ||
        rawType.contains('datafono') ||
        rawType.contains('plataforma');

    return DeliveryServicePlan(
      hasDomicilio: hasDomicilio,
      crossCount: crossCount < 0 ? 0 : crossCount,
      purchaseCount: purchaseCount < 0 ? 0 : purchaseCount,
      changeOfMoney: changeOfMoney,
      hasDataphone: hasDataphone,
    );
  }
}

class Delivery {
  const Delivery({
    required this.id,
    required this.storeName,
    required this.storeAddress,
    required this.destination,
    required this.destinationAddress,
    required this.recipientName,
    required this.recipientPhone,
    required this.paymentMethod,
    required this.paymentAmount,
    this.courierEarnings = 0,
    this.totalToCollect,
    this.cashReceived,
    required this.distance,
    required this.estimatedTime,
    required this.kind,
    required this.status,
    required this.note,
    required this.origin,
    required this.destinationPoint,
    this.service = const DeliveryServicePlan(),
    this.productSummary = 'Productos del pedido',
    this.pickupStops = const [],
    this.crossRoutes = const [],
    this.destinationOptions = const [],
    this.selectedAddressIndex = 0,
    this.pharmacyCode = '',
    this.neighborhood = '',
    this.addressReference = '',
    this.cashExpected,
    this.approvalPending = false,
    this.approvalCourierName,
    this.assignedAsSupport = false,
    this.acceptedCourierId,
    this.deliveryOutcome,
    this.priorityUntil,
    this.expiresAt,
  });

  final String id;
  final String storeName;
  final String storeAddress;
  final String destination;
  final String destinationAddress;
  final String recipientName;
  final String recipientPhone;
  final PaymentMethod paymentMethod;
  final double paymentAmount;
  final double courierEarnings;
  final double? totalToCollect;
  final double? cashReceived;
  final double distance;
  final int estimatedTime;
  final DeliveryKind kind;
  final DeliveryStatus status;
  final String note;
  final LatLng origin;
  final LatLng destinationPoint;
  final DeliveryServicePlan service;
  final String productSummary;
  final List<DeliveryPickupStop> pickupStops;
  final List<DeliveryCrossRoute> crossRoutes;
  final List<DeliveryAddress> destinationOptions;
  final int selectedAddressIndex;
  final String pharmacyCode;
  final String neighborhood;
  final String addressReference;
  final double? cashExpected;
  final bool approvalPending;
  final String? approvalCourierName;
  final bool assignedAsSupport;
  final String? acceptedCourierId;
  final String? deliveryOutcome;
  // Migración 039/041: reserva para la zona que pide y vencimiento de la oferta.
  final DateTime? priorityUntil;
  final DateTime? expiresAt;

  double get serviceFee =>
      courierEarnings > 0 ? courierEarnings : service.fee.toDouble();

  double get amountToCollect => totalToCollect ?? paymentAmount;

  double? get changeDue =>
      cashReceived == null ? null : cashReceived! - amountToCollect;

  List<DeliveryAddress> get addressOptions => destinationOptions.isEmpty
      ? [
          DeliveryAddress(
            label: destination,
            address: destinationAddress,
            point: destinationPoint,
          ),
        ]
      : destinationOptions;

  Delivery copyWith({
    DeliveryStatus? status,
    String? destination,
    String? destinationAddress,
    LatLng? destinationPoint,
    int? selectedAddressIndex,
    double? cashReceived,
    bool? approvalPending,
    String? approvalCourierName,
    bool? assignedAsSupport,
    String? acceptedCourierId,
    String? deliveryOutcome,
  }) => Delivery(
    id: id,
    storeName: storeName,
    storeAddress: storeAddress,
    destination: destination ?? this.destination,
    destinationAddress: destinationAddress ?? this.destinationAddress,
    recipientName: recipientName,
    recipientPhone: recipientPhone,
    paymentMethod: paymentMethod,
    paymentAmount: paymentAmount,
    courierEarnings: courierEarnings,
    totalToCollect: totalToCollect,
    cashReceived: cashReceived ?? this.cashReceived,
    distance: distance,
    estimatedTime: estimatedTime,
    kind: kind,
    status: status ?? this.status,
    note: note,
    origin: origin,
    destinationPoint: destinationPoint ?? this.destinationPoint,
    service: service,
    productSummary: productSummary,
    pickupStops: pickupStops,
    crossRoutes: crossRoutes,
    destinationOptions: destinationOptions,
    selectedAddressIndex: selectedAddressIndex ?? this.selectedAddressIndex,
    pharmacyCode: pharmacyCode,
    neighborhood: neighborhood,
    addressReference: addressReference,
    cashExpected: cashExpected,
    approvalPending: approvalPending ?? this.approvalPending,
    approvalCourierName: approvalCourierName ?? this.approvalCourierName,
    assignedAsSupport: assignedAsSupport ?? this.assignedAsSupport,
    acceptedCourierId: acceptedCourierId ?? this.acceptedCourierId,
    deliveryOutcome: deliveryOutcome ?? this.deliveryOutcome,
    priorityUntil: priorityUntil,
    expiresAt: expiresAt,
  );
}

/// Almacén local de la compilación de revisión de la etapa 0.
///
/// La etapa 1 conecta este almacenamiento con Supabase, autenticación y
/// notificaciones. Mantenerlo aislado permite revisar los flujos completos en
/// el APK mientras se configura el backend de producción.
class StageZeroDemoStore {
  StageZeroDemoStore._();

  static final instance = StageZeroDemoStore._();

  late final ValueNotifier<List<Delivery>> deliveries = ValueNotifier(
    demoDeliveries.toList(),
  );

  void addDelivery(Delivery delivery) {
    deliveries.value = [...deliveries.value, delivery];
  }

  void updateDelivery(Delivery delivery) {
    final next = deliveries.value.toList();
    final index = next.indexWhere((item) => item.id == delivery.id);
    if (index >= 0) {
      next[index] = delivery;
    } else {
      next.add(delivery);
    }
    deliveries.value = next;
  }

  void requestPharmacyApproval({
    required String deliveryId,
    required String courierName,
  }) {
    final delivery = deliveries.value.cast<Delivery?>().firstWhere(
      (item) => item?.id == deliveryId,
      orElse: () => null,
    );
    if (delivery == null) return;
    updateDelivery(
      delivery.copyWith(
        approvalPending: true,
        approvalCourierName: courierName,
      ),
    );
  }

  void approvePharmacyRequest(String deliveryId) {
    final delivery = _find(deliveryId);
    if (delivery == null) return;
    updateDelivery(
      delivery.copyWith(
        status: DeliveryStatus.accepted,
        approvalPending: false,
      ),
    );
  }

  void rejectPharmacyRequest(String deliveryId) {
    final delivery = _find(deliveryId);
    if (delivery == null) return;
    updateDelivery(
      delivery.copyWith(
        approvalPending: false,
        deliveryOutcome: 'Solicitud adicional rechazada por la farmacia',
      ),
    );
  }

  Delivery? _find(String deliveryId) {
    for (final delivery in deliveries.value) {
      if (delivery.id == deliveryId) return delivery;
    }
    return null;
  }
}

class AdminZone {
  const AdminZone({
    this.id,
    required this.name,
    required this.reference,
    required this.pharmacyCount,
    required this.courierCount,
    required this.active,
    required this.color,
  });

  final String? id;
  final String name;
  final String reference;
  final int pharmacyCount;
  final int courierCount;
  final bool active;
  final Color color;

  AdminZone copyWith({
    String? id,
    String? name,
    String? reference,
    int? pharmacyCount,
    int? courierCount,
    bool? active,
    Color? color,
  }) => AdminZone(
    id: id ?? this.id,
    name: name ?? this.name,
    reference: reference ?? this.reference,
    pharmacyCount: pharmacyCount ?? this.pharmacyCount,
    courierCount: courierCount ?? this.courierCount,
    active: active ?? this.active,
    color: color ?? this.color,
  );
}

class AdminPharmacyProfile {
  const AdminPharmacyProfile({
    this.id,
    required this.displayName,
    required this.username,
    required this.role,
    required this.active,
  });

  final String? id;
  final String displayName;
  final String username;
  final String role;
  final bool active;

  factory AdminPharmacyProfile.fromMap(Map<String, dynamic> row) =>
      AdminPharmacyProfile(
        id: row['id']?.toString(),
        displayName: '${row['display_name'] ?? ''}',
        username: '${row['username'] ?? ''}',
        role: '${row['profile_role'] ?? 'vendedor'}',
        active: row['active'] == true,
      );
}

class AdminUser {
  const AdminUser({
    this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.pharmacy,
    required this.active,
    this.phone = '',
    this.temporaryPassword,
    this.pharmacyProfiles = const [],
  });

  final String? id;
  final String name;
  final String username;
  final String role;
  final String pharmacy;
  final bool active;
  final String phone;
  final String? temporaryPassword;
  final List<AdminPharmacyProfile> pharmacyProfiles;

  AdminUser copyWith({
    String? id,
    String? name,
    String? username,
    String? role,
    String? pharmacy,
    bool? active,
    String? phone,
    String? temporaryPassword,
    List<AdminPharmacyProfile>? pharmacyProfiles,
  }) => AdminUser(
    id: id ?? this.id,
    name: name ?? this.name,
    username: username ?? this.username,
    role: role ?? this.role,
    pharmacy: pharmacy ?? this.pharmacy,
    active: active ?? this.active,
    phone: phone ?? this.phone,
    temporaryPassword: temporaryPassword ?? this.temporaryPassword,
    pharmacyProfiles: pharmacyProfiles ?? this.pharmacyProfiles,
  );
}

String _adminUserOptionKey(AdminUser user) => user.id ?? user.username;

class AdminWeeklyDayDraft {
  AdminWeeklyDayDraft({
    required this.hours,
    required this.zone,
    required this.pharmacy,
    this.isDouble = false,
    this.isSupport = false,
  });

  String hours;
  String zone;
  String pharmacy;
  bool isDouble;
  bool isSupport;
}

class AdminWeeklyShiftDraft {
  AdminWeeklyShiftDraft({required this.courier, required this.days});

  final AdminUser courier;
  final List<AdminWeeklyDayDraft> days;
}

class AdminPharmacy {
  const AdminPharmacy({
    required this.code,
    required this.name,
    required this.address,
    required this.zone,
    required this.location,
    this.active = true,
  });

  final String code;
  final String name;
  final String address;
  final String zone;
  final LatLng location;
  final bool active;

  AdminPharmacy copyWith({
    String? code,
    String? name,
    String? address,
    String? zone,
    LatLng? location,
    bool? active,
  }) => AdminPharmacy(
    code: code ?? this.code,
    name: name ?? this.name,
    address: address ?? this.address,
    zone: zone ?? this.zone,
    location: location ?? this.location,
    active: active ?? this.active,
  );
}

class AdminShift {
  const AdminShift({
    this.id,
    this.courierId,
    this.zoneId,
    required this.courierName,
    required this.hours,
    required this.zone,
    required this.pharmacy,
    required this.isDouble,
    required this.scheduledFor,
    required this.color,
    this.secondHours,
    this.isSupport = false,
  });

  final String? id;
  final String? courierId;
  final String? zoneId;
  final String courierName;
  final String hours;
  final String zone;
  final String pharmacy;
  final bool isDouble;
  final DateTime scheduledFor;
  final String? secondHours;
  final Color color;
  final bool isSupport;

  String get name => courierName;

  String get displayHours =>
      isDouble && secondHours != null ? '$hours + $secondHours' : hours;

  String get pharmacyLabel => adminShiftPharmacyLabel(pharmacy);

  String get assignmentLabel => isSupport
      ? 'Apoyo general'
      : pharmacy == adminNoPharmacy
      ? 'Toda la zona'
      : 'Farmacia $pharmacy';

  int get blockCount => isDouble ? 2 : 1;

  String get dayLabel {
    final today = DateUtils.dateOnly(DateTime.now());
    final date = DateUtils.dateOnly(scheduledFor);
    if (date == today) return 'Hoy';
    if (date == today.add(const Duration(days: 1))) return 'Mañana';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
  }

  String get status => _calculateShiftStatus(
    date: scheduledFor,
    primaryHours: hours,
    secondaryHours: secondHours,
  );

  AdminShift copyWith({
    String? id,
    String? courierId,
    String? zoneId,
    String? courierName,
    String? hours,
    String? zone,
    String? pharmacy,
    bool? isDouble,
    DateTime? scheduledFor,
    String? secondHours,
    Color? color,
    bool? isSupport,
  }) => AdminShift(
    id: id ?? this.id,
    courierId: courierId ?? this.courierId,
    zoneId: zoneId ?? this.zoneId,
    courierName: courierName ?? this.courierName,
    hours: hours ?? this.hours,
    zone: zone ?? this.zone,
    pharmacy: pharmacy ?? this.pharmacy,
    isDouble: isDouble ?? this.isDouble,
    scheduledFor: scheduledFor ?? this.scheduledFor,
    secondHours: secondHours ?? this.secondHours,
    color: color ?? this.color,
    isSupport: isSupport ?? this.isSupport,
  );
}

String adminCourierGroupKey(AdminShift shift) {
  final courierId = shift.courierId?.trim();
  return courierId == null || courierId.isEmpty
      ? 'name:${shift.courierName.trim()}'
      : courierId;
}

const adminPrimaryHours = <String>['07:00 – 15:00', '14:00 – 23:00'];

const adminDoubleHours = '17:00 – 23:00';

const adminNoPharmacy = 'Sin farmacia asignada';
const adminSupportZone = 'Apoyo general';

const adminFlexibleZones = <String>{
  'Zona 41',
  'Cantaclaro',
  'Pradera',
  'Margen izquierda',
  'Granja',
};

bool adminZoneAllowsAnyPharmacy(String zone) =>
    adminFlexibleZones.contains(zone);

String adminShiftPharmacyLabel(String pharmacy) =>
    pharmacy == adminNoPharmacy ? 'Toda la zona' : pharmacy;

List<String> adminSuggestedZoneSequence({
  required List<String> zones,
  required int courierIndex,
  int days = 7,
}) {
  if (zones.isEmpty || days <= 0) return const [];
  final counts = <String, int>{for (final zone in zones) zone: 0};
  final result = <String>[];
  for (var day = 0; day < days; day++) {
    final offset = (courierIndex + day) % zones.length;
    final candidates = [
      for (var index = 0; index < zones.length; index++)
        zones[(offset + index) % zones.length],
    ];
    candidates.sort((a, b) => (counts[a] ?? 0).compareTo(counts[b] ?? 0));
    final selected = candidates.firstWhere(
      (zone) => (counts[zone] ?? 0) < 2,
      orElse: () => candidates.first,
    );
    result.add(selected);
    counts[selected] = (counts[selected] ?? 0) + 1;
  }
  return result;
}

DateTime _adminToday() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

DateTime _adminWeekStart(DateTime value) {
  final date = DateUtils.dateOnly(value);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

/// The weekly schedule is normally published on Saturdays for the following
/// Monday–Sunday period. On other days we keep the current Monday as default.
DateTime adminPublishWeekStart(DateTime value) {
  final date = DateUtils.dateOnly(value);
  final currentWeek = _adminWeekStart(date);
  return date.weekday >= DateTime.saturday
      ? currentWeek.add(const Duration(days: 7))
      : currentWeek;
}

String _adminWeekdayShort(DateTime value) => const [
  'Lun',
  'Mar',
  'Mié',
  'Jue',
  'Vie',
  'Sáb',
  'Dom',
][value.weekday - DateTime.monday];

String _adminCalendarDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}';

String _courierInitials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'FN';
  if (words.length == 1) {
    final word = words.first.toUpperCase();
    return word.length == 1 ? word : word.substring(0, 2);
  }
  return '${words.first[0]}${words[1][0]}'.toUpperCase();
}

String _calculateShiftStatus({
  required DateTime date,
  required String primaryHours,
  String? secondaryHours,
}) {
  final today = DateUtils.dateOnly(DateTime.now());
  final scheduledDate = DateUtils.dateOnly(date);
  if (scheduledDate.isAfter(today)) return 'Programado';
  if (scheduledDate.isBefore(today)) return 'Finalizado';

  final now = DateTime.now();
  final ranges = [primaryHours, ?secondaryHours];
  final parsedRanges = ranges
      .map((range) => _parseShiftRange(range, scheduledDate))
      .whereType<(DateTime, DateTime)>()
      .toList();
  if (parsedRanges.any((range) {
    final start = range.$1;
    final end = range.$2;
    return !now.isBefore(start) && now.isBefore(end);
  })) {
    return 'En curso';
  }
  if (parsedRanges.every((range) => now.isAfter(range.$2))) {
    return 'Finalizado';
  }
  return 'Programado';
}

(DateTime, DateTime)? _parseShiftRange(String range, DateTime day) {
  final matches = RegExp(r'(\d{1,2}):(\d{2})').allMatches(range).toList();
  if (matches.length < 2) return null;
  DateTime parse(Match match) => DateTime(
    day.year,
    day.month,
    day.day,
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
  );
  final start = parse(matches.first);
  var end = parse(matches[1]);
  if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
  return (start, end);
}

const demoAdminZones = <AdminZone>[
  AdminZone(
    name: 'Margen izquierda',
    reference: 'Farmacias 310 · 221 · 219',
    pharmacyCount: 3,
    courierCount: 3,
    active: true,
    color: AppColors.primaryDark,
  ),
  AdminZone(
    name: 'Zona norte',
    reference: 'Farmacias 192 · 183 · 155 · 179',
    pharmacyCount: 4,
    courierCount: 2,
    active: true,
    color: AppColors.violet,
  ),
  AdminZone(
    name: 'Cantaclaro',
    reference: 'Farmacias 177 · 184 · 178',
    pharmacyCount: 3,
    courierCount: 1,
    active: true,
    color: AppColors.blue,
  ),
  AdminZone(
    name: 'Pradera',
    reference: 'Farmacias 220 · 252',
    pharmacyCount: 2,
    courierCount: 1,
    active: true,
    color: AppColors.warning,
  ),
  AdminZone(
    name: 'Zona 41',
    reference: 'Farmacias 181 · 182 · 269',
    pharmacyCount: 3,
    courierCount: 1,
    active: true,
    color: AppColors.primary,
  ),
  AdminZone(
    name: 'Granja',
    reference: 'Farmacias 234 · 222 · 145 · 167',
    pharmacyCount: 4,
    courierCount: 1,
    active: true,
    color: AppColors.primaryDark,
  ),
  AdminZone(
    name: 'Curva del Diablo',
    reference: 'Base 232 · cobertura especial Granja y Pradera',
    pharmacyCount: 1,
    courierCount: 1,
    active: true,
    color: AppColors.violet,
  ),
  AdminZone(
    name: 'Nirvana',
    reference: 'Base 357 · cobertura especial Cantaclaro',
    pharmacyCount: 1,
    courierCount: 1,
    active: true,
    color: AppColors.blue,
  ),
];

const demoAdminPharmacies = <AdminPharmacy>[
  AdminPharmacy(
    code: '234',
    name: 'FN 234',
    address: 'La Granja · dirección por confirmar',
    zone: 'Granja',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '222',
    name: 'FN 222',
    address: 'La Granja · dirección por confirmar',
    zone: 'Granja',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '145',
    name: 'FN 145',
    address: 'La Granja · dirección por confirmar',
    zone: 'Granja',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '167',
    name: 'FN 167',
    address: 'La Granja · dirección por confirmar',
    zone: 'Granja',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '232',
    name: 'FN 232',
    address: 'Curva del Diablo · dirección por confirmar',
    zone: 'Curva del Diablo',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '220',
    name: 'FN 220',
    address: 'Pradera · dirección por confirmar',
    zone: 'Pradera',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '252',
    name: 'FN 252',
    address: 'Pradera · dirección por confirmar',
    zone: 'Pradera',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '178',
    name: 'FN 178',
    address: 'Cantaclaro · dirección por confirmar',
    zone: 'Cantaclaro',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '184',
    name: 'FN 184',
    address: 'Cantaclaro · dirección por confirmar',
    zone: 'Cantaclaro',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '177',
    name: 'FN 177',
    address: 'Cantaclaro · dirección por confirmar',
    zone: 'Cantaclaro',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '357',
    name: 'FN 357',
    address: 'Nirvana · dirección por confirmar',
    zone: 'Nirvana',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '183',
    name: 'FN 183',
    address: 'Zona norte · dirección por confirmar',
    zone: 'Zona norte',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '155',
    name: 'FN 155',
    address: 'Monteverde · dirección por confirmar',
    zone: 'Zona norte',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '192',
    name: 'FN 192',
    address: 'Zona norte · dirección por confirmar',
    zone: 'Zona norte',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '179',
    name: 'FN 179',
    address: 'Zona norte · dirección por confirmar',
    zone: 'Zona norte',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '181',
    name: 'FN 181',
    address: 'Zona 41 · dirección por confirmar',
    zone: 'Zona 41',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '182',
    name: 'FN 182',
    address: 'Zona 41 · dirección por confirmar',
    zone: 'Zona 41',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '269',
    name: 'FN 269',
    address: 'Zona 41 · dirección por confirmar',
    zone: 'Zona 41',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '310',
    name: 'FN 310',
    address: 'Margen izquierda · dirección por confirmar',
    zone: 'Margen izquierda',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '221',
    name: 'FN 221',
    address: 'Margen izquierda · dirección por confirmar',
    zone: 'Margen izquierda',
    location: MapsConfig.monteria,
  ),
  AdminPharmacy(
    code: '219',
    name: 'FN 219',
    address: 'Margen izquierda · dirección por confirmar',
    zone: 'Margen izquierda',
    location: MapsConfig.monteria,
  ),
];

final demoAdminShifts = <AdminShift>[
  AdminShift(
    courierName: 'Juan Sebastián Ríos',
    hours: '07:00 – 15:00',
    zone: 'Zona norte',
    pharmacy: '155',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.violet,
  ),
  AdminShift(
    courierName: 'María',
    hours: '07:00 – 15:00',
    zone: 'Margen izquierda',
    pharmacy: '310',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.primaryDark,
  ),
  AdminShift(
    courierName: 'Carlos',
    hours: '07:00 – 15:00',
    zone: 'Curva del Diablo',
    pharmacy: '232',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.violet,
  ),
  AdminShift(
    courierName: 'Diana',
    hours: '14:00 – 23:00',
    zone: 'Nirvana',
    pharmacy: '357',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.blue,
  ),
  AdminShift(
    courierName: 'Andrés',
    hours: '14:00 – 23:00',
    zone: 'Cantaclaro',
    pharmacy: '177',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.blue,
  ),
  AdminShift(
    courierName: 'Luis',
    hours: '14:00 – 23:00',
    zone: 'Zona 41',
    pharmacy: '181',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.primary,
  ),
  AdminShift(
    courierName: 'Santiago',
    hours: '07:00 – 15:00',
    zone: 'Granja',
    pharmacy: '234',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.primaryDark,
  ),
  AdminShift(
    courierName: 'Valentina',
    hours: '14:00 – 23:00',
    zone: 'Pradera',
    pharmacy: '220',
    isDouble: false,
    scheduledFor: _adminToday(),
    color: AppColors.warning,
  ),
];

final demoAdminUsers = <AdminUser>[
  const AdminUser(
    name: 'Juan Sebastián Ríos',
    username: 'juan.rios@farmanorte.co',
    role: 'Domiciliario',
    pharmacy: 'Base 155 · Zona norte',
    active: true,
  ),
  const AdminUser(
    name: 'Vendedor FN 155',
    username: 'vendedor155@farmanorte.co',
    role: 'Vendedor de farmacia',
    pharmacy: 'FN 155',
    active: true,
  ),
  const AdminUser(
    name: 'Administrador principal',
    username: 'admin@farmanorte.co',
    role: 'Administrador',
    pharmacy: 'Todas las farmacias',
    active: true,
  ),
];

final demoDeliveries = <Delivery>[
  Delivery(
    id: 'FN155001',
    storeName: 'FN 155',
    storeAddress: 'Monteverde · dirección por confirmar',
    destination: 'La Castellana',
    destinationAddress: 'Carrera 8 # 62-14, Montería',
    recipientName: 'María Fernanda López',
    recipientPhone: '300 456 7812',
    paymentMethod: PaymentMethod.cash,
    paymentAmount: 28900,
    courierEarnings: 5000,
    totalToCollect: 33900,
    cashReceived: 50000,
    cashExpected: 50000,
    distance: 3.2,
    estimatedTime: 18,
    kind: DeliveryKind.pharmacyToHome,
    status: DeliveryStatus.offered,
    note: 'Entregar en portería. El cliente tiene cambio.',
    origin: LatLng(8.7571, -75.8847),
    destinationPoint: LatLng(8.7692, -75.8674),
    pharmacyCode: '155',
    neighborhood: 'La Castellana',
    addressReference: 'Portería principal',
    productSummary: 'Medicamentos de fórmula y cuidado personal',
    pickupStops: [
      DeliveryPickupStop(
        title: 'FN 155',
        address: 'Monteverde · dirección por confirmar',
        point: LatLng(8.7571, -75.8847),
        label: 'Farmacia solicitante',
      ),
    ],
    destinationOptions: [
      DeliveryAddress(
        label: 'La Castellana',
        address: 'Carrera 8 # 62-14, Montería',
        point: LatLng(8.7692, -75.8674),
      ),
      DeliveryAddress(
        label: 'Centro · Calle 23',
        address: 'Calle 23 # 7-19, Montería',
        point: LatLng(8.7589, -75.8836),
      ),
    ],
  ),
  Delivery(
    id: 'FN183002',
    storeName: 'FN 183',
    storeAddress: 'Zona norte · dirección por confirmar',
    destination: 'El Recreo',
    destinationAddress: 'Calle 64 # 6-27, Montería',
    recipientName: 'Carlos Andrés Pérez',
    recipientPhone: '315 807 2441',
    paymentMethod: PaymentMethod.card,
    paymentAmount: 45700,
    courierEarnings: 8000,
    totalToCollect: 53700,
    distance: 4.8,
    estimatedTime: 24,
    kind: DeliveryKind.pharmacyToHome,
    status: DeliveryStatus.offered,
    note: 'Llamar al llegar al edificio.',
    origin: LatLng(8.7458, -75.8915),
    destinationPoint: LatLng(8.7745, -75.8792),
    pharmacyCode: '183',
    neighborhood: 'El Recreo',
    addressReference: 'Llamar al llegar al edificio',
    service: DeliveryServicePlan(purchaseCount: 1, hasDataphone: true),
    productSummary: 'Producto no disponible en farmacia · comprar en Pasteur',
    pickupStops: [
      DeliveryPickupStop(
        title: 'FN 183',
        address: 'Zona norte · dirección por confirmar',
        point: LatLng(8.7458, -75.8915),
        label: 'Farmacia solicitante',
      ),
      DeliveryPickupStop(
        title: 'Pasteur',
        address: 'Carrera 6 # 32-18, Montería',
        point: LatLng(8.7520, -75.8810),
        label: 'Comprar producto',
      ),
    ],
  ),
  Delivery(
    id: 'FN232003',
    storeName: 'FN 232',
    storeAddress: 'Curva del Diablo · dirección por confirmar',
    destination: 'Villa Campestre',
    destinationAddress: 'Carrera 12 # 70-05, Montería',
    recipientName: 'Julián Martínez',
    recipientPhone: '301 921 6408',
    paymentMethod: PaymentMethod.qr,
    paymentAmount: 16300,
    courierEarnings: 8000,
    totalToCollect: 24300,
    distance: 2.6,
    estimatedTime: 16,
    kind: DeliveryKind.overflow,
    status: DeliveryStatus.offered,
    note: 'Pedido de desborde: está cerca de tu ubicación.',
    origin: LatLng(8.7610, -75.8798),
    destinationPoint: LatLng(8.7810, -75.8645),
    pharmacyCode: '232',
    neighborhood: 'Villa Campestre',
    addressReference: 'Cruce en FN 183 · entregar directo al cliente',
    service: DeliveryServicePlan(crossCount: 1, hasDataphone: true),
    productSummary: 'Un producto debe recogerse en otra farmanorte',
    pickupStops: [
      DeliveryPickupStop(
        title: 'FN 232',
        address: 'Calle 41 # 13-26, P5',
        point: LatLng(8.7610, -75.8798),
        label: 'Farmacia solicitante',
      ),
      DeliveryPickupStop(
        title: 'FN 183',
        address: 'Calle 64 # 6-27, El Recreo',
        point: LatLng(8.7741, -75.8768),
        label: 'Recoger cruce',
      ),
    ],
  ),
  Delivery(
    id: 'FN219004',
    storeName: 'FN 219',
    storeAddress: 'Margen izquierda · dirección por confirmar',
    destination: 'Alamedas del Sinú',
    destinationAddress: 'Calle 35 # 6-16, Montería',
    recipientName: 'Diana Carolina Rojas',
    recipientPhone: '316 224 1200',
    paymentMethod: PaymentMethod.qr,
    paymentAmount: 32100,
    courierEarnings: 7000,
    totalToCollect: 39100,
    distance: 3.9,
    estimatedTime: 21,
    kind: DeliveryKind.pharmacyToHome,
    status: DeliveryStatus.offered,
    note: 'Recoger paquete sellado en mostrador.',
    origin: LatLng(8.7505, -75.8738),
    destinationPoint: LatLng(8.7555, -75.8990),
    pharmacyCode: '219',
    neighborhood: 'Alamedas del Sinú',
    addressReference: 'Paquete sellado en mostrador',
    service: DeliveryServicePlan(crossCount: 1),
    productSummary: 'Domicilio con un cruce en FN 221',
    pickupStops: [
      DeliveryPickupStop(
        title: 'FN 219',
        address: 'Carrera 14 # 24-10, La Coquera',
        point: LatLng(8.7505, -75.8738),
        label: 'Farmacia solicitante',
      ),
      DeliveryPickupStop(
        title: 'FN 221',
        address: 'Calle 72 # 2-09, Alamedas',
        point: LatLng(8.7882, -75.8757),
        label: 'Recoger cruce',
      ),
    ],
  ),
  Delivery(
    id: 'FN177005',
    storeName: 'FN 177',
    storeAddress: 'Calle 23 # 7-19, Centro',
    destination: 'Punto de cambio',
    destinationAddress: 'Carrera 4 # 28-12, Centro, Montería',
    recipientName: 'FN 177',
    recipientPhone: farmanorteSupportPhone,
    paymentMethod: PaymentMethod.cash,
    paymentAmount: 0,
    courierEarnings: 4000,
    totalToCollect: 0,
    distance: 1.8,
    estimatedTime: 12,
    kind: DeliveryKind.storeToStore,
    status: DeliveryStatus.offered,
    note: 'Cambiar 400.000 en billetes de 100 por billetes de 2.000, 5.000 y 10.000.',
    origin: LatLng(8.7589, -75.8836),
    destinationPoint: LatLng(8.7541, -75.8815),
    service: DeliveryServicePlan(changeOfMoney: true),
    productSummary: 'Cambio de menudo · valor solicitado: 400.000 pesos',
    pickupStops: [
      DeliveryPickupStop(
        title: 'FN 177',
        address: 'Calle 23 # 7-19, Centro',
        point: LatLng(8.7589, -75.8836),
        label: 'Recoger dinero',
      ),
    ],
  ),
];

class FarmaNorteApp extends StatelessWidget {
  const FarmaNorteApp({super.key, this.allowLocalReview = false});

  /// Solo se activa desde las pruebas automatizadas. Las compilaciones
  /// instalables nunca deben entrar al modo local ni mostrar datos ficticios.
  final bool allowLocalReview;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'farmanorte Domicilios',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme.copyWith(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: AppColors.ink,
        ),
        scaffoldBackgroundColor: AppColors.canvas,
        fontFamily: 'Roboto',
        iconTheme: const IconThemeData(color: AppColors.primaryDark, size: 21),
        listTileTheme: const ListTileThemeData(
          iconColor: AppColors.primaryDark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.ink,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: AppColors.line),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.canvas,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
        // Botón secundario: mismo radio que el principal, borde de marca.
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.ink,
          contentTextStyle: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        switchTheme: SwitchThemeData(
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.line,
          ),
        ),
      ),
      builder: (context, child) =>
          NotificationPermissionBanner(child: child ?? const SizedBox.shrink()),
      home: SessionGate(allowLocalReview: allowLocalReview),
    );
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key, this.allowLocalReview = false});

  final bool allowLocalReview;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  SupabaseUserProfile? _profile;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSession());
  }

  Future<void> _restoreSession() async {
    if (!SupabaseConfig.isConfigured) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }

    try {
      final service = SupabaseOperationsService.instance;
      final ready = await service.initialize();
      if (!ready || !service.hasAuthenticatedUser) {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      final profile = await service.loadCurrentProfile();
      if (profile == null || !profile.active) {
        await service.signOut();
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'La sesión existe, pero el perfil está inactivo.';
        });
        return;
      }
      // La sesión puede haber sido guardada por otra superficie del sistema.
      // Nunca conviertas automáticamente cualquier rol distinto de admin en
      // domiciliario: una cuenta de farmacia solo puede usar su página web.
      if (!isSupportedOperationsAppRole(profile.role)) {
        await service.signOut();
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = operationsAppAccessMessage(profile.role);
        });
        return;
      }
      // Solicitar el permiso antes de mostrar la jornada operativa. Si el
      // sistema tarda o Firebase no está disponible, la sesión no se bloquea.
      await OperationsBackend.instance.requestNotificationPermission();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
      unawaited(OperationsBackend.instance.registerPushNotifications());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'No se pudo restaurar la sesión: '
            '${'$error'.replaceFirst('Bad state: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!SupabaseConfig.isConfigured && !widget.allowLocalReview) {
      return const BackendConfigurationRequiredScreen();
    }
    if (_profile != null) {
      if (_profile!.mustChangePassword) {
        return PasswordChangeRequiredScreen(
          profile: _profile!,
          nextScreenBuilder: (updatedProfile) => updatedProfile.role == 'admin'
              ? AdminDashboardScreen(realBackend: true, profile: updatedProfile)
              : HomeScreen(profile: updatedProfile),
        );
      }
      return _profile!.role == 'admin'
          ? AdminDashboardScreen(realBackend: true, profile: _profile)
          : HomeScreen(profile: _profile);
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_clock_outlined,
                  color: AppColors.danger,
                  size: 38,
                ),
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    unawaited(_restoreSession());
                  },
                  child: const Text('Reintentar'),
                ),
                TextButton(
                  onPressed: () async {
                    await OperationsBackend.instance.signOut();
                    if (!mounted) return;
                    setState(() => _error = null);
                  },
                  child: const Text('Ir al inicio de sesión'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return LoginScreen(allowLocalReview: widget.allowLocalReview);
  }
}

class PasswordChangeRequiredScreen extends StatefulWidget {
  const PasswordChangeRequiredScreen({
    super.key,
    required this.profile,
    required this.nextScreenBuilder,
  });

  final SupabaseUserProfile profile;
  final Widget Function(SupabaseUserProfile profile) nextScreenBuilder;

  @override
  State<PasswordChangeRequiredScreen> createState() =>
      _PasswordChangeRequiredScreenState();
}

class _PasswordChangeRequiredScreenState
    extends State<PasswordChangeRequiredScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final password = _password.text;
    if (password.length < 8) {
      setState(
        () => _error = 'La nueva contraseña debe tener mínimo 8 caracteres.',
      );
      return;
    }
    if (password != _confirmation.text) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await OperationsBackend.instance.completePasswordChange(
        password: password,
      );
      unawaited(OperationsBackend.instance.registerPushNotifications());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => widget.nextScreenBuilder(
            widget.profile.copyWith(mustChangePassword: false),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.lock_reset_rounded,
                        size: 42,
                        color: AppColors.primary,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Cambia tu contraseña',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'La contraseña entregada por el administrador es temporal. Define una nueva para continuar, ${widget.profile.fullName}.',
                        style: const TextStyle(
                          color: AppColors.muted,
                          height: 1.45,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.danger,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                          labelText: 'Nueva contraseña',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmation,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                          labelText: 'Repite la contraseña',
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.check_rounded),
                          label: Text(
                            _saving ? 'Guardando…' : 'Guardar y continuar',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BackendConfigurationRequiredScreen extends StatelessWidget {
  const BackendConfigurationRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: AppColors.danger,
                      size: 44,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Conexión real requerida',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Esta compilación no tiene configurado Supabase. '
                      'No se cargarán domicilios, usuarios ni turnos ficticios.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, height: 1.45),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.allowLocalReview = false});

  final bool allowLocalReview;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _user = TextEditingController();
  final _password = TextEditingController();
  late final AnimationController _introController;
  late final Animation<double> _introProgress;
  bool _obscure = true;
  bool _adminMode = false;
  bool _isLoading = false;
  bool _rememberCredentials = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    );
    _introProgress = CurvedAnimation(
      parent: _introController,
      curve: Curves.easeOutCubic,
    );
    unawaited(_introController.forward());
    _setInitialCredentials();
    // Pedirlo al abrir la APK, antes del login, para que Android no deje la
    // aplicación sin permiso por esperar únicamente a una autenticación. Se
    // difiere hasta el primer frame para que la Activity ya esté reanudada y
    // Android pueda mostrar el diálogo nativo sin descartarlo durante el
    // arranque.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_requestNotificationsOnEntry());
    });
  }

  void _setInitialCredentials() {
    // La revisión local entra por una ruta explícita de pruebas; no se
    // incrustan usuarios ni contraseñas compartidas en la APK.
  }

  Future<void> _requestNotificationsOnEntry() async {
    if (!mounted) return;
    await OperationsBackend.instance.requestNotificationPermission();
  }

  @override
  void dispose() {
    _introController.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusManager.instance.primaryFocus?.unfocus();
    AppNotificationAudio.unlockForWeb();

    if (!SupabaseConfig.isConfigured) {
      if (widget.allowLocalReview) {
        _enterLocalReview();
      } else {
        setState(() => _error = SupabaseConfig.configurationError);
      }
      return;
    }

    final email = normalizeAuthIdentifier(_user.text);
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Escribe el correo y la contraseña.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await OperationsBackend.instance.signInWithPassword(
        email: email,
        password: password,
      );
      final profile = await OperationsBackend.instance.loadCurrentProfile();
      final expectedRole = _adminMode ? 'admin' : 'courier';

      if (profile == null || !profile.active) {
        await OperationsBackend.instance.signOut();
        throw StateError(
          'El usuario ingresó, pero todavía no tiene un perfil operativo.',
        );
      }
      if (profile.role != expectedRole) {
        await OperationsBackend.instance.signOut();
        throw StateError(
          _adminMode
              ? 'Este usuario no tiene rol de administrador.'
              : operationsAppAccessMessage(profile.role),
        );
      }

      await OperationsBackend.instance.requestNotificationPermission();

      if (profile.mustChangePassword) {
        if (!mounted) return;
        TextInput.finishAutofillContext(shouldSave: false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => PasswordChangeRequiredScreen(
              profile: profile,
              nextScreenBuilder: (updatedProfile) => _adminMode
                  ? AdminDashboardScreen(
                      realBackend: true,
                      profile: updatedProfile,
                    )
                  : HomeScreen(profile: updatedProfile),
            ),
          ),
        );
        return;
      }

      unawaited(OperationsBackend.instance.registerPushNotifications());
      if (!mounted) return;
      TextInput.finishAutofillContext(shouldSave: _rememberCredentials);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => _adminMode
              ? AdminDashboardScreen(realBackend: true, profile: profile)
              : HomeScreen(profile: profile),
        ),
      );
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo iniciar sesión: ${error.message}');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _enterLocalReview() {
    if (!widget.allowLocalReview) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) =>
            _adminMode ? const AdminDashboardScreen() : const HomeScreen(),
      ),
    );
  }

  void _selectRole(bool admin) {
    setState(() {
      _adminMode = admin;
      _error = null;
      _user.text = '';
    });
    unawaited(_introController.forward(from: 0));
  }

  Widget _buildProfessionalLogin(BuildContext context) {
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 760;
    final contentWidth = isWide ? 620.0 : media.size.width;
    final heroHeight = isWide ? 500.0 : 455.0;
    final admin = _adminMode;
    final reducedMotion = media.disableAnimations;
    final headline = admin
        ? 'Todo bajo control.'
        : 'Bienvenido,\ndomiciliario.';
    final description = admin
        ? 'Turnos, farmacias, usuarios y domicilios\nen un solo lugar.'
        : 'Ingresa para recibir turnos, domicilios\ny mensajes de las farmacias.';

    if (!isWide) {
      return _buildMobileLoginLayout(context);
    }

    return Scaffold(
      backgroundColor: AppColors.pharmacyCanvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = contentWidth > constraints.maxWidth
                ? constraints.maxWidth
                : contentWidth;
            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 30),
              child: Center(
                child: SizedBox(
                  width: width,
                  child: Column(
                    children: [
                      Container(
                        height: heroHeight,
                        width: double.infinity,
                        clipBehavior: Clip.hardEdge,
                        decoration: const BoxDecoration(
                          color: AppColors.pharmacyBlueDeep,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(72),
                            bottomRight: Radius.circular(72),
                          ),
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              right: -118,
                              top: 34,
                              child: Container(
                                width: 380,
                                height: 380,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withValues(
                                    alpha: .20,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: -12,
                              top: 116,
                              child: Container(
                                width: 218,
                                height: 218,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: .06),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: const _LoginRoutePainter(),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                28,
                                28,
                                28,
                                34,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 268,
                                    height: 68,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: .12,
                                          ),
                                          blurRadius: 16,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Image.asset(
                                      'assets/farmanorte-brand.png',
                                      fit: BoxFit.contain,
                                      alignment: Alignment.centerLeft,
                                      semanticLabel: 'farmanorte',
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    admin
                                        ? 'PANEL DE OPERACIÓN'
                                        : 'RED DE DOMICILIOS',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: .82,
                                      ),
                                      fontSize: 13,
                                      letterSpacing: 1.7,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const Spacer(),
                                  AnimatedBuilder(
                                    animation: _introProgress,
                                    builder: (context, child) {
                                      final progress = reducedMotion
                                          ? 1.0
                                          : _introProgress.value;
                                      final characterCount =
                                          (headline.length * progress)
                                              .round()
                                              .clamp(0, headline.length)
                                              .toInt();
                                      final animatedHeadline = headline
                                          .substring(0, characterCount);
                                      return Text(
                                        '$animatedHeadline${characterCount < headline.length ? '▌' : ''}',
                                        semanticsLabel: admin
                                            ? 'Control de $farmanorteBrandName'
                                            : 'Bienvenido a $farmanorteBrandName',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 39,
                                          height: 1.12,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -.7,
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    description,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: .86,
                                      ),
                                      fontSize: 18,
                                      height: 1.45,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Transform.translate(
                        offset: const Offset(0, -84),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: _buildProfessionalLoginCard(context),
                        ),
                      ),
                      Transform.translate(
                        offset: const Offset(0, -58),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                size: 18,
                                color: AppColors.pharmacyBlue,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  admin
                                      ? 'Sesión segura · $farmanorteBrandName Administración'
                                      : 'Acceso protegido para domiciliarios',
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMobileLoginLayout(BuildContext context) {
    final media = MediaQuery.of(context);
    final admin = _adminMode;
    final compactHeight = media.size.height < 720;
    final tight = media.size.height < 760;
    final headline = admin
        ? 'Todo bajo control.'
        : 'Bienvenido,\ndomiciliario.';
    final description = admin
        ? 'Turnos, farmacias y domicilios en un solo lugar.'
        : 'Ingresa para recibir turnos, domicilios y mensajes.';

    return Scaffold(
      backgroundColor: AppColors.pharmacyCanvas,
      body: SafeArea(
        child: Column(
          children: [
            _buildLoginHero(
              height: tight
                  ? 148
                  : compactHeight
                  ? 158
                  : 174,
              compact: true,
              tight: tight,
              admin: admin,
              headline: headline,
              description: description,
              reducedMotion: media.disableAnimations,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: _buildProfessionalLoginCard(
                  context,
                  compact: true,
                  tight: tight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginHero({
    required double height,
    required bool compact,
    required bool admin,
    required String headline,
    required String description,
    required bool reducedMotion,
    bool tight = false,
  }) {
    final brandWidth = compact ? (tight ? 184.0 : 194.0) : 272.0;

    return Container(
      height: height,
      width: double.infinity,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: AppColors.pharmacyBlueDeep,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(compact ? 42 : 72),
          bottomRight: Radius.circular(compact ? 42 : 72),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: compact ? -132 : -118,
            top: compact ? 24 : 34,
            child: Container(
              width: compact ? 300 : 380,
              height: compact ? 300 : 380,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: .20),
              ),
            ),
          ),
          Positioned(
            right: compact ? -30 : -12,
            top: compact ? 84 : 116,
            child: Container(
              width: compact ? 176 : 218,
              height: compact ? 176 : 218,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: .06),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(painter: const _LoginRoutePainter()),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? (tight ? 16 : 20) : 28,
              compact ? (tight ? 10 : 16) : 28,
              compact ? (tight ? 16 : 20) : 28,
              compact ? (tight ? 6 : 12) : 34,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Container(
                        width: brandWidth + (compact ? 16 : 0),
                        height: compact ? (tight ? 42 : 50) : 68,
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 8 : 12,
                          vertical: compact ? 5 : 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .12),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/farmanorte-brand.png',
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          semanticLabel: 'farmanorte',
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                AnimatedBuilder(
                  animation: _introProgress,
                  builder: (context, child) {
                    final progress = reducedMotion ? 1.0 : _introProgress.value;
                    final characterCount = (headline.length * progress)
                        .round()
                        .clamp(0, headline.length)
                        .toInt();
                    final animatedHeadline = headline.substring(
                      0,
                      characterCount,
                    );
                    return Text(
                      '$animatedHeadline${characterCount < headline.length ? '▌' : ''}',
                      semanticsLabel: admin
                          ? 'Control de $farmanorteBrandName'
                          : 'Bienvenido a $farmanorteBrandName',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? (tight ? 23 : 27) : 39,
                        height: 1.08,
                        fontWeight: FontWeight.w900,
                        letterSpacing: compact ? -.4 : -.7,
                      ),
                    );
                  },
                ),
                SizedBox(height: compact ? (tight ? 4 : 6) : 16),
                Text(
                  description,
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .86),
                    fontSize: compact ? (tight ? 11.5 : 12.5) : 18,
                    height: compact ? (tight ? 1.18 : 1.25) : 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfessionalLoginCard(
    BuildContext context, {
    bool compact = false,
    bool tight = false,
  }) {
    final admin = _adminMode;
    final baseTheme = Theme.of(context);
    final inputTheme = baseTheme.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: const Color(0xFFFBFDFF),
      labelStyle: const TextStyle(
        color: AppColors.muted,
        fontWeight: FontWeight.w600,
      ),
      floatingLabelStyle: const TextStyle(
        color: AppColors.pharmacyBlue,
        fontWeight: FontWeight.w700,
      ),
      prefixIconColor: AppColors.pharmacyBlue,
      suffixIconColor: AppColors.muted,
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: tight
            ? 8
            : compact
            ? 12
            : 18,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(compact ? 15 : 18),
        borderSide: const BorderSide(color: Color(0xFFC9D8E7), width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(compact ? 15 : 18),
        borderSide: const BorderSide(color: Color(0xFFC9D8E7), width: 1.4),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(compact ? 15 : 18),
        borderSide: const BorderSide(color: AppColors.pharmacyBlue, width: 2),
      ),
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        compact ? (tight ? 16 : 20) : 26,
        compact ? (tight ? 12 : 18) : 30,
        compact ? (tight ? 16 : 20) : 26,
        compact ? (tight ? 10 : 14) : 22,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 24 : 32),
        boxShadow: [
          BoxShadow(
            color: AppColors.pharmacyBlueDeep.withValues(alpha: .15),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Theme(
        data: baseTheme.copyWith(
          colorScheme: baseTheme.colorScheme.copyWith(
            primary: AppColors.pharmacyBlue,
            secondary: AppColors.primary,
          ),
          inputDecorationTheme: inputTheme,
        ),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: compact ? 4 : 6,
                width: compact ? 62 : 76,
                decoration: BoxDecoration(
                  color: admin ? AppColors.pharmacyBlue : AppColors.primary,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              SizedBox(height: compact ? (tight ? 8 : 12) : 24),
              Text(
                admin ? 'ACCESO ADMINISTRATIVO' : 'ACCESO DE DOMICILIARIO',
                style: TextStyle(
                  color: admin ? AppColors.pharmacyBlue : AppColors.primaryDark,
                  fontSize: compact ? (tight ? 9.5 : 10.5) : 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: compact ? 1.3 : 1.7,
                ),
              ),
              SizedBox(height: compact ? (tight ? 4 : 6) : 12),
              Text(
                'Iniciar sesión',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: compact ? (tight ? 25 : 28) : 34,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: compact ? -.5 : -.8,
                ),
              ),
              SizedBox(height: compact ? (tight ? 4 : 6) : 10),
              Text(
                admin
                    ? 'Ingresa para gestionar la operación completa de $farmanorteBrandName.'
                    : 'Usa las credenciales que te asignó el administrador.',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: compact ? (tight ? 12 : 13) : 16,
                  height: compact ? (tight ? 1.2 : 1.3) : 1.45,
                ),
              ),
              SizedBox(height: compact ? (tight ? 8 : 12) : 22),
              _buildRoleSwitcher(compact: compact),
              SizedBox(height: compact ? (tight ? 7 : 10) : 20),
              TextField(
                controller: _user,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                decoration: InputDecoration(
                  labelText: 'Usuario o correo',
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                ),
              ),
              SizedBox(height: compact ? (tight ? 6 : 8) : 14),
              TextField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    tooltip: _obscure
                        ? 'Mostrar contraseña'
                        : 'Ocultar contraseña',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? (tight ? 4 : 6) : 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrowOptions = constraints.maxWidth < 390;
                  final rememberRow = Row(
                    children: [
                      Checkbox.adaptive(
                        value: _rememberCredentials,
                        activeColor: AppColors.pharmacyBlue,
                        visualDensity: compact
                            ? VisualDensity.compact
                            : VisualDensity.standard,
                        materialTapTargetSize: compact
                            ? MaterialTapTargetSize.shrinkWrap
                            : MaterialTapTargetSize.padded,
                        onChanged: (value) => setState(
                          () => _rememberCredentials = value ?? false,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Mantener sesión iniciada',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: compact ? (tight ? 10.5 : 11.5) : 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  );
                  final forgotButton = TextButton(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Solicita al administrador una nueva contraseña temporal.',
                        ),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: TextStyle(
                        fontSize: compact ? (tight ? 10 : 11) : 14,
                      ),
                    ),
                    child: const Text('¿Olvidaste tu clave?'),
                  );
                  return compact
                      ? Row(
                          children: [
                            Expanded(child: rememberRow),
                            forgotButton,
                          ],
                        )
                      : narrowOptions
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            rememberRow,
                            Align(
                              alignment: Alignment.centerRight,
                              child: forgotButton,
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: rememberRow),
                            forgotButton,
                          ],
                        );
                },
              ),
              SizedBox(height: compact ? (tight ? 7 : 10) : 16),
              SizedBox(
                width: double.infinity,
                height: tight
                    ? 46
                    : compact
                    ? 50
                    : 58,
                child: FilledButton.icon(
                  onPressed: _isLoading ? null : _login,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          admin
                              ? Icons.dashboard_customize_rounded
                              : Icons.arrow_forward_rounded,
                        ),
                  label: Text(
                    _isLoading
                        ? 'Verificando…'
                        : admin
                        ? 'Entrar al panel'
                        : 'Entrar a mi jornada',
                    style: TextStyle(
                      fontSize: compact ? (tight ? 13 : 14) : 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.pharmacyBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(compact ? 18 : 22),
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0F0),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFF4C6C6)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              SizedBox(height: compact ? (tight ? 10 : 14) : 20),
              const Divider(color: AppColors.line),
              SizedBox(height: compact ? (tight ? 6 : 8) : 14),
              Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    color: admin
                        ? AppColors.pharmacyBlue
                        : AppColors.primaryDark,
                    size: compact ? (tight ? 16 : 18) : 22,
                  ),
                  SizedBox(width: compact ? (tight ? 6 : 8) : 12),
                  Expanded(
                    child: Text(
                      admin
                          ? 'Acceso administrativo protegido.\nPermisos completos de la operación.'
                          : 'Acceso protegido para personal autorizado.\nTu jornada se sincroniza con las farmacias.',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: compact ? (tight ? 10 : 11) : 13,
                        height: compact ? (tight ? 1.15 : 1.25) : 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleSwitcher({bool compact = false}) {
    return Container(
      height: compact ? 44 : 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5FA),
        borderRadius: BorderRadius.circular(compact ? 15 : 18),
        border: Border.all(color: const Color(0xFFE3EAF2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildRoleOption(
              label: 'Domiciliario',
              admin: false,
              compact: compact,
            ),
          ),
          Expanded(
            child: _buildRoleOption(
              label: 'Administrador',
              admin: true,
              compact: compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleOption({
    required String label,
    required bool admin,
    bool compact = false,
  }) {
    final selected = _adminMode == admin;
    return GestureDetector(
      onTap: () {
        if (!selected) _selectRole(admin);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.pharmacyBlue.withValues(alpha: .12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.pharmacyBlue : AppColors.muted,
            fontSize: compact ? 12.5 : 14,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _buildProfessionalLogin(context);
}

class _LoginRoutePainter extends CustomPainter {
  const _LoginRoutePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: .14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    final accent = Paint()
      ..color = AppColors.primary.withValues(alpha: .66)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;

    final guidePath = Path()
      ..moveTo(-24, size.height * .78)
      ..cubicTo(
        size.width * .22,
        size.height * .60,
        size.width * .36,
        size.height * .90,
        size.width * .52,
        size.height * .66,
      )
      ..cubicTo(
        size.width * .68,
        size.height * .42,
        size.width * .77,
        size.height * .58,
        size.width + 28,
        size.height * .44,
      );
    canvas.drawPath(guidePath, guide);

    final accentPath = Path()
      ..moveTo(-18, size.height * .88)
      ..cubicTo(
        size.width * .20,
        size.height * .70,
        size.width * .36,
        size.height * 1.02,
        size.width * .55,
        size.height * .78,
      )
      ..cubicTo(
        size.width * .72,
        size.height * .56,
        size.width * .82,
        size.height * .72,
        size.width + 18,
        size.height * .60,
      );
    canvas.drawPath(accentPath, accent);
  }

  @override
  bool shouldRepaint(covariant _LoginRoutePainter oldDelegate) => false;
}

class SupabaseSessionVerifiedScreen extends StatelessWidget {
  const SupabaseSessionVerifiedScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await OperationsBackend.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sesión real'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.verified_user_outlined,
                      color: AppColors.primaryDark,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Autenticación real verificada',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'La sesión de Supabase Auth funciona. El panel operativo real se abrirá según el rol del perfil; no se muestran datos locales en esta sesión.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, height: 1.45),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => _logout(context),
                      child: const Text('Cerrar sesión'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PharmacyDeskScreen extends StatefulWidget {
  const PharmacyDeskScreen({super.key});

  @override
  State<PharmacyDeskScreen> createState() => _PharmacyDeskScreenState();
}

class _PharmacyDeskScreenState extends State<PharmacyDeskScreen> {
  static const pharmacyCode = '155';

  final _client = TextEditingController();
  final _phone = TextEditingController();
  final _neighborhood = TextEditingController();
  final _address = TextEditingController();
  final _reference = TextEditingController();
  final _products = TextEditingController();
  final _amount = TextEditingController();
  final _cashExpected = TextEditingController();
  final _notes = TextEditingController();
  final _externalPlace = TextEditingController();

  String _serviceType = 'Domicilio normal';
  String _payment = 'Efectivo';

  List<Delivery> get _pharmacyDeliveries => StageZeroDemoStore
      .instance
      .deliveries
      .value
      .where((delivery) => delivery.pharmacyCode == pharmacyCode)
      .toList()
      .reversed
      .toList();

  @override
  void dispose() {
    for (final controller in [
      _client,
      _phone,
      _neighborhood,
      _address,
      _reference,
      _products,
      _amount,
      _cashExpected,
      _notes,
      _externalPlace,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _needsPlace =>
      _serviceType == 'Compra externa' || _serviceType == 'Cruce con domicilio';

  Future<void> _createDelivery() async {
    final missing = <String>[];
    if (_client.text.trim().isEmpty) missing.add('nombre del cliente');
    if (_phone.text.trim().isEmpty) missing.add('teléfono');
    if (_neighborhood.text.trim().isEmpty) missing.add('barrio o sector');
    if (_address.text.trim().isEmpty) missing.add('dirección');
    if (_reference.text.trim().isEmpty) missing.add('referencia');
    if (_products.text.trim().isEmpty) missing.add('descripción del pedido');
    if (_needsPlace && _externalPlace.text.trim().isEmpty) {
      missing.add('farmacia o lugar de recogida');
    }
    if (missing.isNotEmpty) {
      _showMessage('Falta completar: ${missing.join(', ')}.');
      return;
    }

    final amount = _parseMoney(_amount.text);
    final expected = _parseMoney(_cashExpected.text);
    final isDataphone = _payment == 'Tarjeta';
    final isQr = _payment == 'QR';
    final isChange = _serviceType == 'Cambio de menudo';
    final isCross = _serviceType == 'Cruce con domicilio';
    final isPurchase = _serviceType == 'Compra externa';
    final kind = _serviceType == 'Desborde'
        ? DeliveryKind.overflow
        : isChange
        ? DeliveryKind.storeToStore
        : DeliveryKind.pharmacyToHome;
    final service = DeliveryServicePlan(
      hasDomicilio: !isChange,
      crossCount: isCross ? 1 : 0,
      purchaseCount: isPurchase ? 1 : 0,
      changeOfMoney: isChange,
      hasDataphone: isDataphone,
    );
    final originName = _needsPlace ? _externalPlace.text.trim() : 'FN 155';
    final id =
        'FN155${(DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0')}';
    final delivery = Delivery(
      id: id,
      storeName: isCross || isPurchase ? originName : 'FN 155',
      storeAddress: isCross || isPurchase
          ? '$originName · punto de recogida'
          : 'Monteverde · punto de recogida',
      destination: _neighborhood.text.trim(),
      destinationAddress: _address.text.trim(),
      recipientName: _client.text.trim(),
      recipientPhone: _phone.text.trim(),
      paymentMethod: isDataphone
          ? PaymentMethod.card
          : isQr
          ? PaymentMethod.qr
          : PaymentMethod.cash,
      paymentAmount: amount,
      courierEarnings: service.fee.toDouble(),
      totalToCollect: isChange ? 0 : amount + service.fee,
      distance: 0,
      estimatedTime: 20,
      kind: kind,
      status: DeliveryStatus.offered,
      note: [
        if (_reference.text.trim().isNotEmpty)
          'Referencia: ${_reference.text.trim()}',
        if (_notes.text.trim().isNotEmpty) _notes.text.trim(),
        if (isCross)
          'Cruce de un solo producto: recoger en $originName y llevar directo al cliente.',
        if (isPurchase) 'Compra externa en $originName.',
      ].join(' '),
      origin: MapsConfig.monteria,
      destinationPoint: MapsConfig.monteria,
      productSummary: _products.text.trim(),
      pharmacyCode: pharmacyCode,
      neighborhood: _neighborhood.text.trim(),
      addressReference: _reference.text.trim(),
      cashExpected: expected,
      pickupStops: [
        DeliveryPickupStop(
          title: originName,
          address: _needsPlace
              ? '$originName · punto de recogida'
              : 'FN 155 · Monteverde',
          point: MapsConfig.monteria,
          label: isCross ? 'Recoger cruce directo' : 'Recoger pedido',
        ),
      ],
    );
    StageZeroDemoStore.instance.addDelivery(delivery);
    for (final controller in [
      _client,
      _phone,
      _neighborhood,
      _address,
      _reference,
      _products,
      _amount,
      _cashExpected,
      _notes,
      _externalPlace,
    ]) {
      controller.clear();
    }
    setState(() {});
    _showMessage('Domicilio $id publicado para la zona de FN 155.');
  }

  double _parseMoney(String raw) {
    final normalized = raw.replaceAll('.', '').replaceAll(',', '.').trim();
    return double.tryParse(normalized) ?? 0;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _logout() {
    unawaited(() async {
      try {
        await OperationsBackend.instance.signOut();
      } catch (_) {
        // La navegación local no debe quedar bloqueada por un error remoto.
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('FN 155 · Domicilios'),
      actions: [
        IconButton(
          tooltip: 'Cerrar sesión',
          onPressed: _logout,
          icon: const Icon(Icons.logout_rounded),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _PharmacyHero(onCreate: () => _scrollToForm(context)),
        const SizedBox(height: 16),
        _PharmacySectionTitle(
          eyebrow: 'NUEVO SERVICIO',
          title: 'Publicar un domicilio',
          subtitle: 'La solicitud quedará registrada y se ofrecerá a la cobertura disponible.',
        ),
        const SizedBox(height: 12),
        _PharmacyFormCard(
          client: _client,
          phone: _phone,
          neighborhood: _neighborhood,
          address: _address,
          reference: _reference,
          products: _products,
          amount: _amount,
          cashExpected: _cashExpected,
          notes: _notes,
          externalPlace: _externalPlace,
          serviceType: _serviceType,
          payment: _payment,
          onServiceChanged: (value) => setState(() => _serviceType = value),
          onPaymentChanged: (value) => setState(() => _payment = value),
          onCreate: _createDelivery,
          needsPlace: _needsPlace,
        ),
        const SizedBox(height: 26),
        _PharmacySectionTitle(
          eyebrow: 'SEGUIMIENTO',
          title: 'Domicilios de FN 155',
          subtitle: 'Aquí aparecerán las solicitudes, aprobaciones y entregas de esta farmacia.',
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<List<Delivery>>(
          valueListenable: StageZeroDemoStore.instance.deliveries,
          builder: (context, _, child) {
            final deliveries = _pharmacyDeliveries;
            if (deliveries.isEmpty) {
              return const _Notice(
                icon: Icons.inbox_outlined,
                title: 'Aún no hay domicilios',
                message: 'Publica el primero con los datos del cliente.',
              );
            }
            return Column(
              children: [
                for (final delivery in deliveries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PharmacyDeliveryCard(
                      delivery: delivery,
                      onApprove: delivery.approvalPending
                          ? () => StageZeroDemoStore.instance
                                .approvePharmacyRequest(delivery.id)
                          : null,
                      onReject: delivery.approvalPending
                          ? () => StageZeroDemoStore.instance
                                .rejectPharmacyRequest(delivery.id)
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );

  void _scrollToForm(BuildContext context) {
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 220),
    );
  }
}

class _PharmacyHero extends StatelessWidget {
  const _PharmacyHero({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
    decoration: BoxDecoration(
      color: AppColors.ink,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(Icons.local_pharmacy_rounded, color: Colors.white),
        ),
        const SizedBox(width: 13),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FN 155 · Monteverde',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Panel de vendedor · etapa 0',
                style: TextStyle(color: Color(0xFFB8C8CD), fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Crear domicilio',
          onPressed: onCreate,
          icon: const Icon(
            Icons.add_circle_outline_rounded,
            color: Colors.white,
          ),
        ),
      ],
    ),
  );
}

class _PharmacySectionTitle extends StatelessWidget {
  const _PharmacySectionTitle({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });

  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow,
        style: const TextStyle(
          color: AppColors.primaryDark,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        title,
        style: const TextStyle(
          color: AppColors.ink,
          fontSize: 21,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    ],
  );
}

class _PharmacyFormCard extends StatelessWidget {
  const _PharmacyFormCard({
    required this.client,
    required this.phone,
    required this.neighborhood,
    required this.address,
    required this.reference,
    required this.products,
    required this.amount,
    required this.cashExpected,
    required this.notes,
    required this.externalPlace,
    required this.serviceType,
    required this.payment,
    required this.onServiceChanged,
    required this.onPaymentChanged,
    required this.onCreate,
    required this.needsPlace,
  });

  final TextEditingController client;
  final TextEditingController phone;
  final TextEditingController neighborhood;
  final TextEditingController address;
  final TextEditingController reference;
  final TextEditingController products;
  final TextEditingController amount;
  final TextEditingController cashExpected;
  final TextEditingController notes;
  final TextEditingController externalPlace;
  final String serviceType;
  final String payment;
  final ValueChanged<String> onServiceChanged;
  final ValueChanged<String> onPaymentChanged;
  final VoidCallback onCreate;
  final bool needsPlace;

  InputDecoration _decoration(String label, IconData icon) =>
      InputDecoration(labelText: label, prefixIcon: Icon(icon));

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppColors.line),
    ),
    child: Column(
      children: [
        TextField(
          controller: client,
          decoration: _decoration('Nombre del cliente', Icons.person_outline),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: _decoration('Teléfono del cliente', Icons.phone_outlined),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: neighborhood,
          decoration: _decoration(
            'Barrio o sector',
            Icons.location_city_outlined,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: address,
          decoration: _decoration(
            'Dirección: calle, carrera, diagonal, transversal o manzana',
            Icons.home_outlined,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: reference,
          maxLines: 2,
          decoration: _decoration(
            'Referencia: ej. doblando el D1 de Cantaclaro',
            Icons.place_outlined,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: products,
          maxLines: 3,
          decoration: _decoration(
            'Descripción del pedido y cantidad de productos',
            Icons.inventory_2_outlined,
          ),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: serviceType,
          isExpanded: true,
          decoration: _decoration('Tipo de servicio', Icons.route_outlined),
          items: const [
            DropdownMenuItem(
              value: 'Domicilio normal',
              child: Text('Domicilio normal'),
            ),
            DropdownMenuItem(
              value: 'Compra externa',
              child: Text('Compra externa'),
            ),
            DropdownMenuItem(
              value: 'Cruce con domicilio',
              child: Text('Cruce con domicilio · 1 producto directo'),
            ),
            DropdownMenuItem(
              value: 'Cambio de menudo',
              child: Text('Cambio de menudo'),
            ),
            DropdownMenuItem(value: 'Desborde', child: Text('Desborde')),
          ],
          onChanged: (value) {
            if (value != null) onServiceChanged(value);
          },
        ),
        if (needsPlace) ...[
          const SizedBox(height: 10),
          TextField(
            controller: externalPlace,
            decoration: _decoration(
              serviceType == 'Cruce con domicilio'
                  ? 'Farmacia donde se recoge el cruce'
                  : 'Lugar de la compra externa',
              Icons.storefront_outlined,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: payment,
                isExpanded: true,
                decoration: _decoration(
                  'Forma de pago',
                  Icons.payments_outlined,
                ),
                items: const [
                  DropdownMenuItem(value: 'Efectivo', child: Text('Efectivo')),
                  DropdownMenuItem(value: 'Tarjeta', child: Text('Tarjeta')),
                  DropdownMenuItem(value: 'QR', child: Text('QR')),
                ],
                onChanged: (value) {
                  if (value != null) onPaymentChanged(value);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: _decoration('Valor del pedido', Icons.attach_money),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: cashExpected,
          keyboardType: TextInputType.number,
          decoration: _decoration(
            '¿Con cuánto paga? · opcional',
            Icons.currency_exchange_rounded,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: notes,
          maxLines: 2,
          decoration: _decoration(
            'Observaciones · opcional',
            Icons.notes_outlined,
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Publicar domicilio · oferta de 5 minutos'),
          ),
        ),
      ],
    ),
  );
}

class _PharmacyDeliveryCard extends StatelessWidget {
  const _PharmacyDeliveryCard({
    required this.delivery,
    required this.onApprove,
    required this.onReject,
  });

  final Delivery delivery;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final waiting = delivery.approvalPending;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: waiting ? const Color(0xFFFFF8E7) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: waiting
              ? AppColors.warning.withValues(alpha: .45)
              : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  delivery.id,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _StatusPill(status: delivery.status),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${delivery.recipientName} · ${delivery.neighborhood}',
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            delivery.addressReference.isEmpty
                ? delivery.destinationAddress
                : '${delivery.destinationAddress} · ${delivery.addressReference}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              height: 1.3,
            ),
          ),
          if (waiting) ...[
            const SizedBox(height: 10),
            Text(
              '${delivery.approvalCourierName ?? 'Un domiciliario'} ya tiene otros domicilios. ¿Apruebas este servicio?',
              style: const TextStyle(
                color: Color(0xFF8B5E00),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onReject,
                    child: const Text('Rechazar'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: FilledButton(
                    onPressed: onApprove,
                    child: const Text('Aprobar'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

enum _AdminSection { overview, zones, pharmacies, shifts, users, settings }

extension _AdminSectionX on _AdminSection {
  String get label => switch (this) {
    _AdminSection.overview => 'Resumen',
    _AdminSection.zones => 'Zonas',
    _AdminSection.pharmacies => 'Farmacias',
    _AdminSection.shifts => 'Turnos',
    _AdminSection.users => 'Usuarios',
    _AdminSection.settings => 'Configuración',
  };

  IconData get icon => switch (this) {
    _AdminSection.overview => Icons.space_dashboard_rounded,
    _AdminSection.zones => Icons.map_outlined,
    _AdminSection.pharmacies => Icons.local_pharmacy_outlined,
    _AdminSection.shifts => Icons.schedule_rounded,
    _AdminSection.users => Icons.manage_accounts_outlined,
    _AdminSection.settings => Icons.settings_outlined,
  };
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({
    super.key,
    this.realBackend = false,
    this.profile,
  });

  final bool realBackend;
  final SupabaseUserProfile? profile;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  List<AdminZone> _zones = const [];
  List<AdminPharmacy> _pharmacies = const [];
  List<AdminShift> _shifts = const [];
  List<AdminUser> _users = const [];
  List<AdminCourierFeeSummary> _courierFeeSummaries = const [];
  String _equivalentPaymentTiming = 'end_of_shift';
  final DateTime _feeWeekStart = adminPublishWeekStart(_adminToday());
  bool _loadingFeeSummaries = false;
  _AdminSection _section = _AdminSection.overview;
  bool _loadingRemote = false;
  String? _remoteError;

  @override
  void initState() {
    super.initState();
    if (widget.realBackend) {
      unawaited(_loadRemote());
    } else {
      _zones = demoAdminZones.toList();
      _pharmacies = demoAdminPharmacies.toList();
      _shifts = demoAdminShifts.toList();
      _users = demoAdminUsers.toList();
      _syncZoneStats();
    }
  }

  Future<void> _loadRemote() async {
    if (!mounted) return;
    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });
    try {
      final snapshot = await SupabaseOperationsService.instance
          .loadAdminSnapshot();
      if (!mounted) return;
      setState(() {
        _zones = snapshot.zones;
        _pharmacies = snapshot.pharmacies;
        _shifts = snapshot.shifts;
        _users = snapshot.users;
      });
      unawaited(_loadAdminFeeSummaries());
      unawaited(_loadEquivalentPaymentTiming());
    } catch (error) {
      if (!mounted) return;
      setState(() => _remoteError = '$error'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _loadingRemote = false);
    }
  }

  Future<void> _loadAdminFeeSummaries() async {
    if (!widget.realBackend || !mounted) return;
    setState(() => _loadingFeeSummaries = true);
    try {
      final summaries = await OperationsBackend.instance
          .loadAdminCourierFeeSummary(weekStart: _feeWeekStart);
      if (mounted) setState(() => _courierFeeSummaries = summaries);
    } catch (error) {
      if (mounted) _showRemoteMessage('No se pudo cargar la cuota: $error');
    } finally {
      if (mounted) setState(() => _loadingFeeSummaries = false);
    }
  }

  Future<void> _loadEquivalentPaymentTiming() async {
    if (!widget.realBackend || !mounted) return;
    try {
      final timing = await OperationsBackend.instance
          .loadEquivalentPaymentTiming();
      if (mounted) setState(() => _equivalentPaymentTiming = timing);
    } catch (_) {
      // Se conserva el valor seguro por defecto: liquidación al cierre.
    }
  }

  Future<void> _editEquivalentPaymentTiming() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Liquidación de equivalentes'),
        content: RadioGroup<String>(
          groupValue: _equivalentPaymentTiming,
          onChanged: (value) => Navigator.pop(dialogContext, value),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                value: 'immediate',
                title: Text('Inmediata'),
                subtitle: Text(
                  'La farmacia registra el pago al recibir el soporte firmado.',
                ),
              ),
              RadioListTile<String>(
                value: 'end_of_shift',
                title: Text('Al cierre del turno'),
                subtitle: Text('Se acumula para la liquidación del turno.'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted || !widget.realBackend) return;
    try {
      await OperationsBackend.instance.updateEquivalentPaymentTiming(
        timing: selected,
      );
      if (mounted) {
        setState(() => _equivalentPaymentTiming = selected);
        _showRemoteMessage('Regla de liquidación guardada.');
      }
    } catch (error) {
      _showRemoteMessage('No se pudo guardar la liquidación: $error');
    }
  }

  Future<void> _editCourierFeeSettings() async {
    final first = _courierFeeSummaries.isEmpty
        ? null
        : _courierFeeSummaries.first;
    final dailyController = TextEditingController(
      text: (first?.dailyAmount ?? 8000).round().toString(),
    );
    final doubleController = TextEditingController(
      text: (first?.doubleShiftSurcharge ?? 2000).round().toString(),
    );
    final values = await showDialog<(double, double)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Configurar cuotas'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: dailyController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Cuota por día',
                prefixText: '\$ ',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: doubleController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Recargo por doble turno',
                prefixText: '\$ ',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final daily = double.tryParse(
                dailyController.text.replaceAll(',', '.'),
              );
              final extra = double.tryParse(
                doubleController.text.replaceAll(',', '.'),
              );
              if (daily == null || extra == null || daily < 0 || extra < 0) {
                return;
              }
              Navigator.pop(dialogContext, (daily, extra));
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    dailyController.dispose();
    doubleController.dispose();
    if (values == null || !mounted) return;
    try {
      await OperationsBackend.instance.updateCourierFeeSettings(
        dailyAmount: values.$1,
        doubleShiftSurcharge: values.$2,
      );
      await _loadAdminFeeSummaries();
      _showRemoteMessage('Cuotas actualizadas para los próximos cálculos.');
    } catch (error) {
      _showRemoteMessage('No se pudo actualizar la cuota: $error');
    }
  }

  Future<void> _recordFeePayment(AdminCourierFeeSummary summary) async {
    if (!widget.realBackend || summary.courierId.trim().isEmpty) return;
    final amountController = TextEditingController(
      text: summary.balanceDue > 0 ? summary.balanceDue.round().toString() : '',
    );
    final noteController = TextEditingController();
    var paymentMethod = 'cash';
    final values = await showDialog<(double, String, String?)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Registrar abono · ${summary.courierName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Saldo pendiente de esta semana: ${_money(summary.balanceDue)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Valor del abono',
                    prefixText: '\$ ',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: paymentMethod,
                  decoration: const InputDecoration(labelText: 'Forma de pago'),
                  items: const [
                    DropdownMenuItem(value: 'cash', child: Text('Efectivo')),
                    DropdownMenuItem(
                      value: 'transfer',
                      child: Text('Transferencia'),
                    ),
                    DropdownMenuItem(value: 'other', child: Text('Otro')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => paymentMethod = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  maxLength: 180,
                  decoration: const InputDecoration(
                    labelText: 'Nota opcional',
                    hintText: 'Ej. Liquidación del lunes',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final amount = double.tryParse(
                  amountController.text.replaceAll(',', '.'),
                );
                if (amount == null || amount <= 0) return;
                Navigator.pop(dialogContext, (
                  amount,
                  paymentMethod,
                  noteController.text.trim(),
                ));
              },
              child: const Text('Guardar abono'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    noteController.dispose();
    if (values == null || !mounted) return;
    try {
      await OperationsBackend.instance.recordCourierFeePayment(
        courierId: summary.courierId,
        weekStart: _feeWeekStart,
        amount: values.$1,
        paymentMethod: values.$2,
        note: values.$3,
      );
      await _loadAdminFeeSummaries();
      _showRemoteMessage('Abono registrado y saldo actualizado.');
    } catch (error) {
      _showRemoteMessage('No se pudo registrar el abono: $error');
    }
  }

  void _showRemoteMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  int get _activeZoneCount => _zones.where((zone) => zone.active).length;

  int get _shiftCount => _shifts
      .where((shift) => DateUtils.dateOnly(shift.scheduledFor) == _adminToday())
      .fold(0, (total, shift) => total + shift.blockCount);

  int get _courierCount => _activeCouriers.length;

  int get _pharmacyCount => _pharmacies.length;

  List<AdminUser> get _activeCouriers => _users
      .where((user) => user.active && user.role == 'Domiciliario')
      .toList();

  List<AdminPharmacy> _pharmaciesFor(String zoneName) =>
      _pharmacies.where((pharmacy) => pharmacy.zone == zoneName).toList();

  void _syncZoneStats() {
    _zones = _zones
        .map(
          (zone) => zone.copyWith(
            active: true,
            pharmacyCount: _pharmaciesFor(zone.name).length,
            courierCount: _shifts
                .where((shift) => shift.zone == zone.name)
                .map((shift) => shift.courierName)
                .toSet()
                .length,
          ),
        )
        .toList();
  }

  DateTime _displayedWeekStart() {
    final preferred = adminPublishWeekStart(_adminToday());
    final preferredHasShifts = _shifts.any(
      (shift) => _isInWeek(shift.scheduledFor, preferred),
    );
    if (preferredHasShifts || _shifts.isEmpty) return preferred;
    final latest = _shifts
        .map((shift) => DateUtils.dateOnly(shift.scheduledFor))
        .reduce((first, second) => first.isAfter(second) ? first : second);
    return _adminWeekStart(latest);
  }

  bool _isInWeek(DateTime date, DateTime weekStart) {
    final normalized = DateUtils.dateOnly(date);
    final start = DateUtils.dateOnly(weekStart);
    return !normalized.isBefore(start) &&
        normalized.isBefore(start.add(const Duration(days: 7)));
  }

  Map<String, List<AdminShift>> _shiftsByCourier(DateTime weekStart) {
    final grouped = <String, List<AdminShift>>{};
    for (final shift in _shifts) {
      if (!_isInWeek(shift.scheduledFor, weekStart)) continue;
      final key = adminCourierGroupKey(shift);
      grouped.putIfAbsent(key, () => <AdminShift>[]).add(shift);
    }
    return grouped;
  }

  Future<void> _openCourierWeek(
    String courierName,
    List<AdminShift> shifts,
    DateTime weekStart,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Turnos de $courierName'),
        content: SizedBox(
          width: 900,
          child: SingleChildScrollView(
            child: _AdminWeeklyCalendar(
              weekStart: weekStart,
              shifts: shifts,
              onEdit: (shift) {
                Navigator.of(dialogContext).pop();
                unawaited(_createOrEditShift(shift));
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteCourierWeek(
    String courierKey,
    String courierName,
    DateTime weekStart,
    List<AdminShift> shifts,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Borrar semana'),
        content: Text(
          'Se eliminarán ${shifts.length} turnos de $courierName entre '
          '${_adminCalendarDate(weekStart)} y '
          '${_adminCalendarDate(weekStart.add(const Duration(days: 6)))}. '
          'No se borra el usuario ni el historial de domicilios.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Borrar semana'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final realCourierId = shifts
        .map((shift) => shift.courierId?.trim())
        .whereType<String>()
        .firstWhere((courierId) => courierId.isNotEmpty, orElse: () => '');
    if (widget.realBackend && realCourierId.isEmpty) {
      _showRemoteMessage(
        'No se pudo identificar al domiciliario real. Recarga el panel e inténtalo nuevamente.',
      );
      return;
    }

    try {
      if (widget.realBackend) {
        final deletedCount = await SupabaseOperationsService.instance
            .deleteAdminShiftsForCourierWeek(
              courierId: realCourierId,
              weekStart: weekStart,
            );
        await _loadRemote();
        _showRemoteMessage(
          deletedCount == 0
              ? 'No había turnos de esa semana para borrar.'
              : 'Se eliminaron $deletedCount turnos. El usuario y el historial se conservaron.',
        );
      } else {
        setState(() {
          _shifts = _shifts
              .where(
                (shift) =>
                    !(adminCourierGroupKey(shift) == courierKey &&
                        _isInWeek(shift.scheduledFor, weekStart)),
              )
              .toList(growable: false);
          _syncZoneStats();
        });
        _showRemoteMessage(
          'Semana eliminada. El usuario y su historial se conservaron.',
        );
      }
    } catch (error) {
      _showRemoteMessage(
        'No se pudo borrar la semana: ${'$error'.replaceFirst('Bad state: ', '')}',
      );
    }
  }

  void _logout() {
    unawaited(() async {
      try {
        await OperationsBackend.instance.signOut();
      } catch (_) {
        // La navegación local no debe quedar bloqueada por un error remoto.
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }());
  }

  Future<void> _createOrEditZone([AdminZone? current]) async {
    final zone = await showDialog<AdminZone>(
      context: context,
      builder: (_) => _AdminZoneDialog(initial: current),
    );
    if (zone == null || !mounted) return;

    if (widget.realBackend) {
      try {
        await SupabaseOperationsService.instance.saveAdminZone(
          zone: zone,
          originalName: current?.name,
        );
        await _loadRemote();
        _showRemoteMessage('Zona guardada en Supabase.');
      } catch (error) {
        _showRemoteMessage(
          'No se pudo guardar la zona: ${'$error'.replaceFirst('Bad state: ', '')}',
        );
      }
      return;
    }

    setState(() {
      if (current == null) {
        _zones = [..._zones, zone];
      } else {
        final index = _zones.indexWhere((item) => item.name == current.name);
        if (index >= 0) {
          _zones[index] = zone;
          if (current.name != zone.name) {
            _pharmacies = _pharmacies
                .map(
                  (pharmacy) => pharmacy.zone == current.name
                      ? pharmacy.copyWith(zone: zone.name)
                      : pharmacy,
                )
                .toList();
            _shifts = _shifts
                .map(
                  (shift) => shift.zone == current.name
                      ? shift.copyWith(zone: zone.name)
                      : shift,
                )
                .toList();
          }
        }
      }
      _syncZoneStats();
    });
  }

  Future<void> _createOrEditPharmacy([AdminPharmacy? current]) async {
    final pharmacy = await showDialog<AdminPharmacy>(
      context: context,
      builder: (_) => _AdminPharmacyDialog(initial: current, zones: _zones),
    );
    if (pharmacy == null || !mounted) return;

    if (widget.realBackend) {
      try {
        await SupabaseOperationsService.instance.saveAdminPharmacy(
          pharmacy: pharmacy,
          originalCode: current?.code,
        );
        await _loadRemote();
        _showRemoteMessage('Farmacia guardada en Supabase.');
      } catch (error) {
        _showRemoteMessage(
          'No se pudo guardar la farmacia: ${'$error'.replaceFirst('Bad state: ', '')}',
        );
      }
      return;
    }

    setState(() {
      if (current == null) {
        _pharmacies = [..._pharmacies, pharmacy];
      } else {
        final index = _pharmacies.indexWhere(
          (item) => item.code == current.code,
        );
        if (index >= 0) _pharmacies[index] = pharmacy;
      }
      _syncZoneStats();
    });
  }

  Future<void> _createOrEditShift([AdminShift? current]) async {
    final shift = await showDialog<AdminShift>(
      context: context,
      builder: (_) => _AdminShiftDialog(
        initial: current,
        zones: _zones,
        pharmacies: _pharmacies,
        couriers: _activeCouriers,
      ),
    );
    if (shift == null || !mounted) return;

    if (widget.realBackend) {
      try {
        await SupabaseOperationsService.instance.saveAdminShift(
          shift: shift,
          originalId: current?.id,
        );
        await _loadRemote();
        _showRemoteMessage('Turno guardado en Supabase.');
      } catch (error) {
        _showRemoteMessage(
          'No se pudo guardar el turno: ${'$error'.replaceFirst('Bad state: ', '')}',
        );
      }
      return;
    }

    setState(() {
      if (current == null) {
        _shifts = [..._shifts, shift];
      } else {
        final index = _shifts.indexWhere(
          (item) =>
              item.courierName == current.courierName &&
              item.zone == current.zone &&
              item.pharmacy == current.pharmacy,
        );
        if (index >= 0) _shifts[index] = shift;
      }
      _syncZoneStats();
    });
  }

  Future<void> _createWeeklyShifts() async {
    final shifts = await showDialog<List<AdminShift>>(
      context: context,
      builder: (_) => _AdminWeeklyShiftDialog(
        zones: _zones,
        pharmacies: _pharmacies,
        couriers: _activeCouriers,
      ),
    );
    if (shifts == null || !mounted) return;

    if (widget.realBackend) {
      try {
        await SupabaseOperationsService.instance.saveAdminShifts(
          shifts: shifts,
        );
        await _loadRemote();
        _showRemoteMessage('${shifts.length} turnos semanales guardados.');
      } catch (error) {
        _showRemoteMessage(
          'No se pudo guardar la semana: ${'$error'.replaceFirst('Bad state: ', '')}',
        );
      }
      return;
    }

    setState(() {
      _shifts = [..._shifts, ...shifts];
      _syncZoneStats();
    });
  }

  Future<void> _createOrEditUser([AdminUser? current]) async {
    final user = await showDialog<AdminUser>(
      context: context,
      builder: (_) =>
          _AdminUserDialog(initial: current, pharmacies: _pharmacies),
    );
    if (user == null || !mounted) return;

    if (widget.realBackend) {
      try {
        if (current == null) {
          final password = user.temporaryPassword;
          if (password == null || password.isEmpty) {
            throw StateError('Define una contraseña inicial para el usuario.');
          }
          final createdUser = await SupabaseOperationsService.instance
              .createAdminUser(user: user, password: password);
          await _loadRemote();
          _showRemoteMessage(
            'Usuario ${user.username} creado. Contraseña temporal: ${createdUser.temporaryPassword ?? password}',
          );
        } else {
          await SupabaseOperationsService.instance.saveAdminProfile(user);
          if (user.temporaryPassword != null) {
            await OperationsBackend.instance.resetAdminUserPassword(
              userId: user.id!,
              password: user.temporaryPassword!,
            );
          }
          await _loadRemote();
          _showRemoteMessage(
            user.temporaryPassword == null
                ? 'Perfil actualizado en Supabase.'
                : 'Perfil actualizado y contraseña restablecida.',
          );
        }
      } catch (error) {
        _showRemoteMessage(
          'No se pudo guardar el usuario: ${_friendlyUserError(error)}',
        );
      }
      return;
    }

    setState(() {
      if (current == null) {
        _users = [..._users, user];
      } else {
        final index = _users.indexWhere(
          (item) => item.username == current.username,
        );
        if (index >= 0) _users[index] = user;
      }
    });
  }

  String _friendlyUserError(Object error) {
    final message = '$error'.replaceFirst('Bad state: ', '').trim();
    final normalized = message.toLowerCase();
    if (normalized.contains('duplicate') ||
        normalized.contains('unique constraint') ||
        normalized.contains('ya existe')) {
      return 'ese usuario ya existe. Usa otro usuario; los perfiles nuevos reciben un identificador interno automáticamente.';
    }
    if (normalized.contains('permission denied') ||
        normalized.contains('forbidden') ||
        normalized.contains('403')) {
      return 'la sesión actual no tiene permiso para realizar esta acción.';
    }
    if (message.isEmpty) return 'revisa los datos e inténtalo nuevamente.';
    return message;
  }

  Future<void> _resetUserPassword(AdminUser user) async {
    if (user.id == null || user.id!.isEmpty) {
      _showRemoteMessage(
        'Este usuario local no tiene un perfil real para restablecer.',
      );
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _AdminPasswordResetDialog(),
    );
    if (password == null || !mounted) return;

    if (widget.realBackend) {
      try {
        await OperationsBackend.instance.resetAdminUserPassword(
          userId: user.id!,
          password: password,
        );
        _showRemoteMessage(
          'Contraseña temporal restablecida para ${user.name}: $password. El perfil y su historial se conservaron.',
        );
      } catch (error) {
        _showRemoteMessage(
          'No se pudo restablecer: ${'$error'.replaceFirst('Bad state: ', '')}',
        );
      }
      return;
    }

    _showRemoteMessage('Contraseña actualizada en la revisión local.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                _AdminSidebar(
                  selected: _section,
                  onSelected: (section) => setState(() => _section = section),
                  onLogout: _logout,
                ),
              Expanded(
                child: Column(
                  children: [
                    _AdminTopBar(
                      onLogout: _logout,
                      realBackend: widget.realBackend,
                      displayName: widget.profile?.fullName ?? 'Administrador',
                    ),
                    if (!wide)
                      _AdminMobileTabs(
                        selected: _section,
                        onSelected: (section) =>
                            setState(() => _section = section),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 32 : 16,
                          24,
                          wide ? 32 : 16,
                          36,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1180),
                            child: _buildSection(wide),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildSection(bool wide) => switch (_section) {
    _AdminSection.overview => _buildOverview(wide),
    _AdminSection.zones => _buildZones(),
    _AdminSection.pharmacies => _buildPharmacies(),
    _AdminSection.shifts => _buildShifts(),
    _AdminSection.users => _buildUsers(),
    _AdminSection.settings => _buildSettings(),
  };

  Widget _buildSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AdminPageHeader(
        eyebrow: 'CONTROL DEL SISTEMA',
        title: 'Configuración',
        subtitle: 'Define cómo se liberan los equivalentes y cómo se liquida el equipo.',
      ),
      const SizedBox(height: 22),
      _AdminPanel(
        eyebrow: 'EQUIVALENTES',
        title: 'Firma obligatoria antes de liberar',
        icon: Icons.verified_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Un equivalente queda pendiente por firmar hasta que el domiciliario dibuje su firma en pantalla. Mientras esté pendiente, la farmacia no lo puede consultar y el valor no se suma a sus ganancias.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.mint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_clock_outlined, color: AppColors.primaryDark),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Regla activa en Supabase: draft → firma → visible para farmacia.',
                      style: TextStyle(
                        color: AppColors.primaryDark,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _AdminPanel(
        eyebrow: 'LIQUIDACIÓN',
        title: 'Pago del equivalente firmado',
        icon: Icons.account_balance_wallet_outlined,
        action: TextButton(
          onPressed: widget.realBackend ? _editEquivalentPaymentTiming : null,
          child: const Text('Cambiar'),
        ),
        child: Row(
          children: [
            Icon(
              _equivalentPaymentTiming == 'immediate'
                  ? Icons.flash_on_outlined
                  : Icons.event_available_outlined,
              color: AppColors.warning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _equivalentPaymentTiming == 'immediate'
                    ? 'Liquidación inmediata al recibir el equivalente firmado.'
                    : 'Liquidación acumulada al cierre del turno.',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _courierFeesPanel(),
    ],
  );

  Widget _buildOverview(bool wide) {
    final metrics = [
      _AdminMetric(
        value: '$_activeZoneCount',
        label: 'Zonas activas',
        detail: 'Cobertura configurada',
        icon: Icons.hub_outlined,
        color: AppColors.primaryDark,
        onTap: () => setState(() => _section = _AdminSection.zones),
      ),
      _AdminMetric(
        value: _shiftCount.toString(),
        label: 'Turnos de hoy',
        detail: 'Bloques programados',
        icon: Icons.schedule_rounded,
        color: AppColors.blue,
        onTap: () => setState(() => _section = _AdminSection.shifts),
      ),
      _AdminMetric(
        value: '$_courierCount',
        label: 'Domiciliarios',
        detail: 'Usuarios activos',
        icon: Icons.delivery_dining_rounded,
        color: AppColors.violet,
        onTap: () => setState(() => _section = _AdminSection.users),
      ),
      _AdminMetric(
        value: '$_pharmacyCount',
        label: 'Farmacias',
        detail: 'Puntos configurados',
        icon: Icons.local_pharmacy_outlined,
        color: AppColors.warning,
        onTap: () => setState(() => _section = _AdminSection.pharmacies),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AdminPageHeader(
          eyebrow: 'CONTROL OPERATIVO',
          title: 'Centro de operaciones',
          subtitle: widget.realBackend
              ? 'Datos reales del proyecto Supabase. El piloto todavía no está asignado.'
              : 'Organiza la cobertura de farmanorte y prepara el día de tu equipo.',
          action: FilledButton.icon(
            onPressed: () => _createOrEditShift(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nuevo turno'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 46),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
        ),
        if (widget.realBackend && _loadingRemote)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (widget.realBackend && _remoteError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'No se pudieron cargar los datos reales: $_remoteError',
              style: const TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        const SizedBox(height: 22),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 850 ? 4 : 2;
            final gap = 12.0;
            final width =
                (constraints.maxWidth - (columns - 1) * gap) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final metric in metrics)
                  SizedBox(width: width, child: _AdminMetricCard(metric)),
              ],
            );
          },
        ),
        const SizedBox(height: 22),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _coveragePanel()),
              const SizedBox(width: 16),
              Expanded(child: _shiftsPanel()),
            ],
          )
        else ...[
          _coveragePanel(),
          const SizedBox(height: 16),
          _shiftsPanel(),
        ],
        const SizedBox(height: 16),
        _pharmaciesPanel(),
        const SizedBox(height: 16),
        _courierFeesPanel(),
      ],
    );
  }

  Widget _courierFeesPanel() => _AdminPanel(
    eyebrow: 'CUOTAS DEL EQUIPO',
    title: 'Deuda semanal de domiciliarios',
    icon: Icons.account_balance_wallet_outlined,
    action: Wrap(
      spacing: 6,
      children: [
        IconButton(
          tooltip: 'Actualizar cuotas',
          onPressed: _loadingFeeSummaries ? null : _loadAdminFeeSummaries,
          icon: const Icon(Icons.refresh_rounded),
        ),
        TextButton(
          onPressed: widget.realBackend ? _editCourierFeeSettings : null,
          child: const Text('Configurar'),
        ),
      ],
    ),
    child: _loadingFeeSummaries
        ? const LinearProgressIndicator()
        : _courierFeeSummaries.isEmpty
        ? const _AdminEmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Cuotas pendientes de migración',
            message: 'Aplica la migración 014 para calcular la deuda con turnos reales.',
          )
        : Column(
            children: [
              for (final summary in _courierFeeSummaries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: AppColors.mint,
                        child: Text(
                          _courierInitials(summary.courierName),
                          style: const TextStyle(
                            color: AppColors.primaryDark,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              summary.courierName,
                              style: const TextStyle(
                                color: AppColors.ink,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              '${summary.scheduledDays} días · ${summary.doubleShiftCount} dobles',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _money(summary.balanceDue),
                            style: const TextStyle(
                              color: AppColors.warning,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'debe · pagó ${_money(summary.totalPaid)}',
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Registrar abono',
                        onPressed: summary.balanceDue <= 0
                            ? null
                            : () => _recordFeePayment(summary),
                        icon: const Icon(Icons.add_card_outlined, size: 19),
                      ),
                    ],
                  ),
                ),
              Text(
                'Semana del ${_adminCalendarDate(_feeWeekStart)} al ${_adminCalendarDate(_feeWeekStart.add(const Duration(days: 6)))} · cuota diaria y recargo doble configurables.',
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ),
  );

  Widget _coveragePanel() => _AdminPanel(
    eyebrow: 'COBERTURA',
    title: 'Zonas operativas',
    icon: Icons.map_outlined,
    action: TextButton(
      onPressed: () => setState(() => _section = _AdminSection.zones),
      child: const Text('Ver zonas'),
    ),
    child: Column(
      children: [
        for (final zone in _zones.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminZoneRow(
              zone: zone,
              onEdit: () => _createOrEditZone(zone),
            ),
          ),
        if (_zones.isEmpty)
          const _AdminEmptyState(
            icon: Icons.map_outlined,
            title: 'Aún no hay zonas',
            message: 'Crea la primera zona de cobertura.',
          ),
      ],
    ),
  );

  Widget _shiftsPanel() => _AdminPanel(
    eyebrow: 'JORNADA',
    title: 'Turnos programados',
    icon: Icons.schedule_rounded,
    action: TextButton(
      onPressed: () => setState(() => _section = _AdminSection.shifts),
      child: const Text('Ver turnos'),
    ),
    child: Column(
      children: [
        for (final shift in _shifts.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminShiftRow(
              shift: shift,
              onEdit: () => _createOrEditShift(shift),
            ),
          ),
        if (_shifts.isEmpty)
          const _AdminEmptyState(
            icon: Icons.schedule_outlined,
            title: 'Aún no hay turnos',
            message: 'Programa el primer turno del día.',
          ),
      ],
    ),
  );

  Widget _pharmaciesPanel() => _AdminPanel(
    eyebrow: 'PUNTOS DE SERVICIO',
    title: 'Farmacias configuradas',
    icon: Icons.local_pharmacy_outlined,
    action: TextButton(
      onPressed: () => setState(() => _section = _AdminSection.pharmacies),
      child: const Text('Ver farmacias'),
    ),
    child: Column(
      children: [
        for (final pharmacy in _pharmacies.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminPharmacyRow(
              pharmacy: pharmacy,
              onEdit: () => _createOrEditPharmacy(pharmacy),
            ),
          ),
        if (_pharmacies.isEmpty)
          const _AdminEmptyState(
            icon: Icons.local_pharmacy_outlined,
            title: 'Aún no hay farmacias',
            message: 'Agrega el primer punto de servicio.',
          ),
      ],
    ),
  );

  Widget _buildZones() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AdminPageHeader(
        eyebrow: 'CONFIGURACIÓN',
        title: 'Zonas operativas',
        subtitle:
            'Define qué farmacias y domiciliarios hacen parte de cada zona.',
        action: FilledButton.icon(
          onPressed: () => _createOrEditZone(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nueva zona'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
      const SizedBox(height: 22),
      if (_zones.isEmpty)
        const _AdminEmptyState(
          icon: Icons.map_outlined,
          title: 'Aún no hay zonas configuradas',
          message: 'Crea una zona para empezar a distribuir la operación.',
        )
      else
        ..._zones.map(
          (zone) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminZoneCard(
              zone: zone,
              pharmacies: _pharmaciesFor(zone.name),
              onEdit: () => _createOrEditZone(zone),
            ),
          ),
        ),
    ],
  );

  Widget _buildPharmacies() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AdminPageHeader(
        eyebrow: 'PUNTOS DE SERVICIO',
        title: 'Farmacias',
        subtitle: 'Registra las droguerías, sus direcciones y la zona que recibe sus domicilios.',
        action: FilledButton.icon(
          onPressed: () => _createOrEditPharmacy(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nueva farmacia'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
      const SizedBox(height: 22),
      if (_pharmacies.isEmpty)
        const _AdminEmptyState(
          icon: Icons.local_pharmacy_outlined,
          title: 'Aún no hay farmacias configuradas',
          message: 'Agrega una farmacia para comenzar a repartir por zona.',
        )
      else
        ..._pharmacies.map(
          (pharmacy) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminPharmacyCard(
              pharmacy: pharmacy,
              onEdit: () => _createOrEditPharmacy(pharmacy),
            ),
          ),
        ),
    ],
  );

  Widget _buildShifts() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AdminPageHeader(
        eyebrow: 'CONFIGURACIÓN',
        title: 'Turnos del equipo',
        subtitle: 'Define horarios y vincúlalos a la zona que debe cubrir cada equipo.',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _createWeeklyShifts,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Programar semana'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _createOrEditShift,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nuevo día'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      _AdminWeeklyCalendar(
        weekStart: _displayedWeekStart(),
        shifts: _shifts,
        onEdit: _createOrEditShift,
      ),
      const SizedBox(height: 16),
      if (_shifts.isEmpty)
        const _AdminEmptyState(
          icon: Icons.schedule_outlined,
          title: 'Aún no hay turnos configurados',
          message: 'Programa un horario para comenzar a organizar el día.',
        )
      else ...[
        Builder(
          builder: (context) {
            final weekStart = _displayedWeekStart();
            final grouped = _shiftsByCourier(weekStart);
            if (grouped.isEmpty) {
              return _AdminEmptyState(
                icon: Icons.calendar_month_outlined,
                title: 'No hay turnos en la semana mostrada',
                message: 'Programa la semana siguiente o selecciona una fecha desde el calendario.',
              );
            }
            return Column(
              children: [
                for (final entry in grouped.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _AdminCourierWeekCard(
                      courierName: entry.value.first.courierName,
                      shifts: entry.value,
                      weekStart: weekStart,
                      onOpen: () => _openCourierWeek(
                        entry.value.first.courierName,
                        entry.value,
                        weekStart,
                      ),
                      onDelete: () => _confirmDeleteCourierWeek(
                        entry.key,
                        entry.value.first.courierName,
                        weekStart,
                        entry.value,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ],
  );

  Widget _buildUsers() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AdminPageHeader(
        eyebrow: 'ACCESOS',
        title: 'Usuarios y permisos',
        subtitle: 'Crea una cuenta de farmacia con perfiles vendedores, o accesos de domiciliario y administrador.',
        action: FilledButton.icon(
          onPressed: () => _createOrEditUser(),
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Nuevo usuario'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
      const SizedBox(height: 22),
      if (_users.isEmpty)
        const _AdminEmptyState(
          icon: Icons.people_outline_rounded,
          title: 'Aún no hay usuarios operativos',
          message: 'Crea el primer domiciliario con un usuario y contraseña inicial.',
        )
      else
        ..._users.map(
          (user) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AdminUserCard(
              user: user,
              onEdit: () => _createOrEditUser(user),
              onResetPassword: () => _resetUserPassword(user),
            ),
          ),
        ),
    ],
  );
}

class _AdminSidebar extends StatelessWidget {
  const _AdminSidebar({
    required this.selected,
    required this.onSelected,
    required this.onLogout,
  });

  final _AdminSection selected;
  final ValueChanged<_AdminSection> onSelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) => Container(
    width: 248,
    padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: AppColors.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.local_pharmacy_rounded,
                color: Colors.white,
                size: 21,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    farmanorteBrandName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'Control operativo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 38),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'ADMINISTRACIÓN',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (final section in _AdminSection.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: _AdminNavButton(
              section: section,
              selected: selected == section,
              onTap: () => onSelected(section),
            ),
          ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.line),
          ),
          child: const Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: AppColors.ink,
                child: Text(
                  'AD',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Administrador',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Sesión de demostración',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded, size: 17),
            label: const Text('Cerrar sesión'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              foregroundColor: AppColors.danger,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AdminNavButton extends StatelessWidget {
  const _AdminNavButton({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _AdminSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.mint : Colors.transparent,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(
              section.icon,
              color: selected ? AppColors.primaryDark : AppColors.muted,
              size: 19,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                section.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.primaryDark : AppColors.ink,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AdminTopBar extends StatelessWidget {
  const _AdminTopBar({
    required this.onLogout,
    required this.realBackend,
    required this.displayName,
  });

  final VoidCallback onLogout;
  final bool realBackend;
  final String displayName;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 520;
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$farmanorteBrandName / Administración',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Bienvenido, $displayName · panel administrativo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (compact)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.mint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_rounded,
                      color: AppColors.primaryDark,
                      size: 15,
                    ),
                    SizedBox(width: 6),
                    Text(
                      realBackend ? 'Supabase real' : 'Modo demo',
                      style: TextStyle(
                        color: AppColors.primaryDark,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            IconButton(
              tooltip: 'Cerrar sesión',
              onPressed: onLogout,
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
        ),
      );
    },
  );
}

class _AdminMobileTabs extends StatelessWidget {
  const _AdminMobileTabs({required this.selected, required this.onSelected});

  final _AdminSection selected;
  final ValueChanged<_AdminSection> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    height: 58,
    color: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final section in _AdminSection.values) ...[
            ChoiceChip(
              selected: selected == section,
              label: Text(section.label),
              avatar: Icon(section.icon, size: 16),
              onSelected: (_) => onSelected(section),
              selectedColor: AppColors.mint,
              labelStyle: TextStyle(
                color: selected == section
                    ? AppColors.primaryDark
                    : AppColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
              side: const BorderSide(color: AppColors.line),
              showCheckmark: false,
            ),
            if (section != _AdminSection.shifts) const SizedBox(width: 8),
          ],
        ],
      ),
    ),
  );
}

class _AdminPageHeader extends StatelessWidget {
  const _AdminPageHeader({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 28,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -.7,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );

      if (action == null) return heading;
      if (constraints.maxWidth < 600) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [heading, const SizedBox(height: 15), action!],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: heading),
          const SizedBox(width: 18),
          action!,
        ],
      );
    },
  );
}

class _AdminMetric {
  const _AdminMetric({
    required this.value,
    required this.label,
    required this.detail,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String value;
  final String label;
  final String detail;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
}

class _AdminMetricCard extends StatelessWidget {
  const _AdminMetricCard(this.metric);

  final _AdminMetric metric;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Semantics(
      button: metric.onTap != null,
      label: '${metric.label}: ${metric.detail}',
      child: InkWell(
        onTap: metric.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: metric.color.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(metric.icon, color: metric.color, size: 18),
              ),
              const SizedBox(height: 17),
              Text(
                metric.value,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                metric.label,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                metric.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AdminPanel extends StatelessWidget {
  const _AdminPanel({
    required this.eyebrow,
    required this.title,
    required this.icon,
    required this.child,
    this.action,
  });

  final String eyebrow;
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primaryDark, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eyebrow,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    ),
  );
}

class _AdminZoneRow extends StatelessWidget {
  const _AdminZoneRow({required this.zone, required this.onEdit});

  final AdminZone zone;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: zone.color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.map_rounded, color: zone.color, size: 18),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final title = Text(
                  zone.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                  ),
                );
                final status = _AdminStatusPill(active: zone.active);
                if (constraints.maxWidth < 180) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 4), status],
                  );
                }
                return Row(
                  children: [
                    Flexible(child: title),
                    const SizedBox(width: 7),
                    status,
                  ],
                );
              },
            ),
            const SizedBox(height: 3),
            Text(
              zone.reference,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${zone.pharmacyCount} farmacias',
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${zone.courierCount} domiciliarios',
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      IconButton(
        tooltip: 'Editar zona',
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined, size: 17),
        color: AppColors.muted,
      ),
    ],
  );
}

class _AdminWeeklyCalendar extends StatelessWidget {
  const _AdminWeeklyCalendar({
    required this.weekStart,
    required this.shifts,
    required this.onEdit,
  });

  final DateTime weekStart;
  final List<AdminShift> shifts;
  final ValueChanged<AdminShift> onEdit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  color: AppColors.primaryDark,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Semana de turnos',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${_adminCalendarDate(weekStart)} – '
                  '${_adminCalendarDate(weekStart.add(const Duration(days: 6)))}',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < 7; index++)
                    _AdminCalendarDay(
                      date: weekStart.add(Duration(days: index)),
                      shifts: shifts
                          .where(
                            (shift) => DateUtils.isSameDay(
                              shift.scheduledFor,
                              weekStart.add(Duration(days: index)),
                            ),
                          )
                          .toList(),
                      onEdit: onEdit,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CourierWeeklyCalendar extends StatelessWidget {
  const _CourierWeeklyCalendar({required this.weekStart, required this.shifts});

  final DateTime weekStart;
  final List<AdminShift> shifts;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.calendar_month_outlined,
                color: AppColors.primaryDark,
                size: 18,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Calendario semanal',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                'Lun – Dom',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var day = 0; day < 7; day++)
                  _CourierCalendarDay(
                    date: weekStart.add(Duration(days: day)),
                    shifts: shifts
                        .where(
                          (shift) => DateUtils.isSameDay(
                            shift.scheduledFor,
                            weekStart.add(Duration(days: day)),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CourierCalendarDay extends StatelessWidget {
  const _CourierCalendarDay({required this.date, required this.shifts});

  final DateTime date;
  final List<AdminShift> shifts;

  @override
  Widget build(BuildContext context) {
    final isToday = DateUtils.isSameDay(date, _adminToday());
    return Container(
      width: 142,
      constraints: const BoxConstraints(minHeight: 142),
      margin: const EdgeInsets.only(right: 7),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isToday ? AppColors.mint : AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isToday
              ? AppColors.primary.withValues(alpha: .45)
              : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _adminWeekdayShort(date),
                style: TextStyle(
                  color: isToday ? AppColors.primaryDark : AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                _adminCalendarDate(date),
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (shifts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 15),
              child: Text(
                'Descanso',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            for (final shift in shifts)
              Semantics(
                label:
                    '${shift.displayHours}, ${shift.zone}, ${shift.pharmacyLabel}',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shift.displayHours,
                        style: TextStyle(
                          color: shift.color,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        shift.zone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        shift.pharmacyLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _AdminCalendarDay extends StatelessWidget {
  const _AdminCalendarDay({
    required this.date,
    required this.shifts,
    required this.onEdit,
  });

  final DateTime date;
  final List<AdminShift> shifts;
  final ValueChanged<AdminShift> onEdit;

  @override
  Widget build(BuildContext context) {
    final isToday = DateUtils.isSameDay(date, _adminToday());
    return Container(
      width: 150,
      constraints: const BoxConstraints(minHeight: 136),
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isToday ? AppColors.mint : AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isToday
              ? AppColors.primary.withValues(alpha: .45)
              : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _adminWeekdayShort(date),
                style: TextStyle(
                  color: isToday ? AppColors.primaryDark : AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                _adminCalendarDate(date),
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (shifts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 15),
              child: Text(
                'Sin turnos',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            for (final shift in shifts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Semantics(
                  button: true,
                  label: 'Editar turno de ${shift.courierName}',
                  child: InkWell(
                    onTap: () => onEdit(shift),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            shift.courierName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${shift.displayHours} · ${shift.pharmacyLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _AdminWeeklyShiftDialog extends StatefulWidget {
  const _AdminWeeklyShiftDialog({
    required this.zones,
    required this.pharmacies,
    required this.couriers,
  });

  final List<AdminZone> zones;
  final List<AdminPharmacy> pharmacies;
  final List<AdminUser> couriers;

  @override
  State<_AdminWeeklyShiftDialog> createState() =>
      _AdminWeeklyShiftDialogState();
}

class _AdminWeeklyShiftDialogState extends State<_AdminWeeklyShiftDialog> {
  late DateTime _weekStart;
  late final List<AdminWeeklyShiftDraft> _drafts;
  String? _error;
  String? _notice;

  List<AdminZone> get _availableZones =>
      widget.zones.where((zone) => zone.active).toList();

  List<AdminPharmacy> get _availablePharmacies =>
      widget.pharmacies.where((pharmacy) => pharmacy.active).toList();

  List<AdminPharmacy> _pharmaciesForZone(String zone) =>
      _availablePharmacies.where((pharmacy) => pharmacy.zone == zone).toList();

  @override
  void initState() {
    super.initState();
    _weekStart = adminPublishWeekStart(_adminToday());
    _drafts = [
      for (final courier in widget.couriers)
        AdminWeeklyShiftDraft(
          courier: courier,
          days: [
            for (var day = 0; day < 7; day++)
              AdminWeeklyDayDraft(
                hours: adminPrimaryHours.first,
                zone: _zoneForCourier(courier),
                pharmacy: _pharmacyForCourier(courier),
              ),
          ],
        ),
    ];
  }

  String _zoneForCourier(AdminUser courier) {
    for (final pharmacy in _availablePharmacies) {
      if (pharmacy.code == courier.pharmacy) return pharmacy.zone;
    }
    return _availableZones.isEmpty
        ? 'Sin zona asignada'
        : _availableZones.first.name;
  }

  String _pharmacyForCourier(AdminUser courier) {
    final zone = _zoneForCourier(courier);
    if (adminZoneAllowsAnyPharmacy(zone)) return adminNoPharmacy;
    for (final pharmacy in _availablePharmacies) {
      if (pharmacy.code == courier.pharmacy && pharmacy.zone == zone) {
        return pharmacy.code;
      }
    }
    final zonePharmacies = _pharmaciesForZone(zone);
    return zonePharmacies.isEmpty ? adminNoPharmacy : zonePharmacies.first.code;
  }

  AdminPharmacy? _pharmacyByCode(String code) {
    if (code == adminNoPharmacy) return null;
    for (final pharmacy in _availablePharmacies) {
      if (pharmacy.code == code) return pharmacy;
    }
    return null;
  }

  AdminPharmacy? _firstPharmacyForZone(String zone) {
    final options = _pharmaciesForZone(zone);
    return options.isEmpty ? null : options.first;
  }

  void _suggest() {
    if (widget.couriers.isEmpty) {
      setState(() => _error = 'Primero crea y activa domiciliarios.');
      return;
    }
    if (_availableZones.isEmpty) {
      setState(() => _error = 'Primero registra las zonas operativas.');
      return;
    }
    final zoneNames = _availableZones.map((zone) => zone.name).toList();
    for (var courierIndex = 0; courierIndex < _drafts.length; courierIndex++) {
      final draft = _drafts[courierIndex];
      final suggestedZones = adminSuggestedZoneSequence(
        zones: zoneNames,
        courierIndex: courierIndex,
        days: draft.days.length,
      );
      final pharmacyCounts = <String, int>{};
      for (var day = 0; day < draft.days.length; day++) {
        final dayDraft = draft.days[day];
        final zone = suggestedZones[day];
        final shouldSupport =
            draft.days.isNotEmpty &&
            day == ((courierIndex + 2) % draft.days.length);
        final pharmacyOptions = _pharmaciesForZone(zone);
        AdminPharmacy? pharmacy;
        if (!shouldSupport &&
            !adminZoneAllowsAnyPharmacy(zone) &&
            pharmacyOptions.isNotEmpty) {
          final ordered = [
            for (var offset = 0; offset < pharmacyOptions.length; offset++)
              pharmacyOptions[(courierIndex + day + offset) %
                  pharmacyOptions.length],
          ];
          ordered.sort(
            (a, b) => (pharmacyCounts[a.code] ?? 0).compareTo(
              pharmacyCounts[b.code] ?? 0,
            ),
          );
          pharmacy = ordered.firstWhere(
            (item) => (pharmacyCounts[item.code] ?? 0) < 2,
            orElse: () => ordered.first,
          );
          pharmacyCounts[pharmacy.code] =
              (pharmacyCounts[pharmacy.code] ?? 0) + 1;
        }
        dayDraft
          ..isSupport = shouldSupport
          ..zone = shouldSupport ? adminSupportZone : zone
          ..pharmacy = shouldSupport
              ? adminNoPharmacy
              : pharmacy?.code ?? adminNoPharmacy
          ..hours =
              adminPrimaryHours[(courierIndex + day) % adminPrimaryHours.length]
          ..isDouble = false;
      }
    }
    setState(() {
      _error = null;
      _notice = 'Sugerencia rotada por día. Revisa cada zona y farmacia antes de guardar.';
    });
  }

  Future<void> _pickWeek() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _weekStart,
      firstDate: _adminToday(),
      lastDate: _adminToday().add(const Duration(days: 90)),
      helpText: 'Selecciona una fecha de esa semana',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _weekStart = _adminWeekStart(DateUtils.dateOnly(picked));
      _error = null;
    });
  }

  void _save() {
    if (_drafts.isEmpty) {
      setState(() => _error = 'No hay domiciliarios activos para programar.');
      return;
    }
    if (_availableZones.isEmpty) {
      setState(() => _error = 'Registra al menos una zona antes de guardar.');
      return;
    }
    for (final draft in _drafts) {
      for (final dayDraft in draft.days) {
        final zoneExists = _availableZones.any(
          (zone) => zone.name == dayDraft.zone,
        );
        final requiresPharmacy = !adminZoneAllowsAnyPharmacy(dayDraft.zone);
        if (!dayDraft.isSupport &&
            (!zoneExists ||
                (requiresPharmacy &&
                    _pharmacyByCode(dayDraft.pharmacy) == null))) {
          setState(
            () => _error =
                'Completa la zona y el punto requerido para ${draft.courier.name}.',
          );
          return;
        }
      }
    }

    final shifts = <AdminShift>[];
    for (final draft in _drafts) {
      for (var day = 0; day < 7; day++) {
        final dayDraft = draft.days[day];
        final pharmacy = _pharmacyByCode(dayDraft.pharmacy);
        shifts.add(
          AdminShift(
            courierId: draft.courier.id,
            courierName: draft.courier.name,
            hours: dayDraft.hours,
            zone: dayDraft.isSupport ? adminSupportZone : dayDraft.zone,
            pharmacy:
                dayDraft.isSupport || adminZoneAllowsAnyPharmacy(dayDraft.zone)
                ? adminNoPharmacy
                : pharmacy!.code,
            isDouble: dayDraft.isDouble,
            secondHours: dayDraft.isDouble ? adminDoubleHours : null,
            scheduledFor: _weekStart.add(Duration(days: day)),
            color: AppColors.primaryDark,
            isSupport: dayDraft.isSupport,
          ),
        );
      }
    }
    Navigator.pop(context, shifts);
  }

  Widget _courierDraft(AdminWeeklyShiftDraft draft) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.mint,
                  child: Icon(
                    Icons.delivery_dining_rounded,
                    color: AppColors.primaryDark,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        draft.courier.name,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        draft.courier.username,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Asignación por día',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            for (var day = 0; day < draft.days.length; day++)
              _dayDraft(draft, day),
          ],
        ),
      ),
    );
  }

  Widget _toggleRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _dayDraft(AdminWeeklyShiftDraft draft, int dayIndex) {
    final dayDraft = draft.days[dayIndex];
    final date = _weekStart.add(Duration(days: dayIndex));
    final pharmacyOptions = dayDraft.isSupport
        ? const <AdminPharmacy>[]
        : _pharmaciesForZone(dayDraft.zone);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_adminWeekdayShort(date)} ${_adminCalendarDate(date)}',
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 11.5,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: dayDraft.hours,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Horario'),
            items: [
              for (final hours in adminPrimaryHours)
                DropdownMenuItem(value: hours, child: Text(hours)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => dayDraft.hours = value);
            },
          ),
          const SizedBox(height: 8),
          _toggleRow(
            value: dayDraft.isSupport,
            onChanged: (value) => setState(() {
              dayDraft.isSupport = value;
              if (value) {
                dayDraft.zone = adminSupportZone;
                dayDraft.pharmacy = adminNoPharmacy;
              } else {
                final zone = _availableZones.isEmpty
                    ? 'Sin zona asignada'
                    : _availableZones.first.name;
                final pharmacy = _firstPharmacyForZone(zone);
                dayDraft.zone = zone;
                dayDraft.pharmacy = adminZoneAllowsAnyPharmacy(zone)
                    ? adminNoPharmacy
                    : pharmacy?.code ?? adminNoPharmacy;
              }
            }),
            title: 'Apoyo general · todas las zonas',
            subtitle: dayDraft.isSupport
                ? 'Podrá recibir ofertas de cualquier farmacia durante este turno.'
                : 'Cubre solamente la zona y el punto configurados abajo.',
          ),
          if (dayDraft.isSupport)
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Cobertura'),
              child: const Text(
                'Todas las farmacias y zonas · apoyo general',
                style: TextStyle(
                  color: AppColors.primaryDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else ...[
            DropdownButtonFormField<String>(
              initialValue:
                  _availableZones.any((zone) => zone.name == dayDraft.zone)
                  ? dayDraft.zone
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Zona operativa'),
              items: [
                for (final zone in _availableZones)
                  DropdownMenuItem(value: zone.name, child: Text(zone.name)),
              ],
              onChanged: (value) {
                if (value == null) return;
                final pharmacy = _firstPharmacyForZone(value);
                setState(() {
                  dayDraft.zone = value;
                  dayDraft.pharmacy = adminZoneAllowsAnyPharmacy(value)
                      ? adminNoPharmacy
                      : pharmacy?.code ?? adminNoPharmacy;
                });
              },
            ),
            const SizedBox(height: 8),
            if (adminZoneAllowsAnyPharmacy(dayDraft.zone))
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Punto base'),
                child: const Text(
                  'No requerido: cubre cualquier farmacia de la zona.',
                  style: TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              DropdownButtonFormField<String>(
                initialValue:
                    pharmacyOptions.any(
                      (pharmacy) => pharmacy.code == dayDraft.pharmacy,
                    )
                    ? dayDraft.pharmacy
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Punto base'),
                items: [
                  for (final pharmacy in pharmacyOptions)
                    DropdownMenuItem(
                      value: pharmacy.code,
                      child: Text(formatPharmacyDisplay(pharmacy.code)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => dayDraft.pharmacy = value);
                  }
                },
              ),
          ],
          _toggleRow(
            value: dayDraft.isDouble,
            onChanged: (value) => setState(() => dayDraft.isDouble = value),
            title: 'Doble turno',
            subtitle: dayDraft.isDouble
                ? 'Incluye el bloque adicional de $adminDoubleHours.'
                : 'Solo se programa el turno base.',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final weekLabel =
        'Semana: ${_adminCalendarDate(_weekStart)} – '
        '${_adminCalendarDate(_weekStart.add(const Duration(days: 6)))}';
    final weekButton = OutlinedButton.icon(
      onPressed: _pickWeek,
      icon: const Icon(Icons.calendar_month_outlined, size: 17),
      label: Text(weekLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final suggestButton = OutlinedButton.icon(
      onPressed: _suggest,
      icon: const Icon(Icons.auto_awesome_rounded, size: 17),
      label: const Text(
        'Sugerir automáticamente',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final isNarrow = MediaQuery.sizeOf(context).width < 520;
    final scheduleControls = isNarrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [weekButton, const SizedBox(height: 8), suggestButton],
          )
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [weekButton, suggestButton],
          );
    final dialogActions = isNarrow
        ? <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: _save,
                  child: const Text('Guardar semana'),
                ),
              ],
            ),
          ]
        : <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(onPressed: _save, child: const Text('Guardar semana')),
          ];

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Programar semana completa'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Se crearán los turnos de lunes a domingo. La sugerencia rota zonas y limita las repeticiones a dos cuando hay alternativas.',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              scheduleControls,
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  _notice!,
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (_drafts.isEmpty)
                const Text(
                  'No hay domiciliarios activos registrados.',
                  style: TextStyle(
                    color: AppColors.danger,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                for (final draft in _drafts) _courierDraft(draft),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: dialogActions,
    );
  }
}

class _AdminShiftRow extends StatelessWidget {
  const _AdminShiftRow({required this.shift, required this.onEdit});

  final AdminShift shift;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: shift.color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.schedule_rounded, color: shift.color, size: 18),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shift.courierName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${shift.displayHours} · ${shift.zone}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _AdminShiftStatus(status: shift.status),
          const SizedBox(height: 4),
          Text(
            shift.blockCount == 2 ? 'Doble turno' : shift.dayLabel,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      IconButton(
        tooltip: 'Editar turno',
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined, size: 17),
        color: AppColors.muted,
      ),
    ],
  );
}

class _AdminPharmacyChip extends StatelessWidget {
  const _AdminPharmacyChip({required this.pharmacy});

  final AdminPharmacy pharmacy;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.canvas,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.local_pharmacy_outlined,
          color: AppColors.primaryDark,
          size: 14,
        ),
        const SizedBox(width: 6),
        Text(
          formatPharmacyDisplay(pharmacy.code),
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _AdminPharmacyRow extends StatelessWidget {
  const _AdminPharmacyRow({required this.pharmacy, required this.onEdit});

  final AdminPharmacy pharmacy;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.local_pharmacy_outlined,
          color: AppColors.primaryDark,
          size: 18,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatPharmacyDisplay(pharmacy.code),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${pharmacy.address} · ${pharmacy.zone}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      _AdminInfoPill(
        icon: Icons.tag_rounded,
        label: pharmacy.code,
        color: AppColors.primaryDark,
      ),
      IconButton(
        tooltip: 'Editar farmacia',
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined, size: 17),
        color: AppColors.muted,
      ),
    ],
  );
}

class _AdminPharmacyCard extends StatelessWidget {
  const _AdminPharmacyCard({required this.pharmacy, required this.onEdit});

  final AdminPharmacy pharmacy;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .11),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.local_pharmacy_outlined,
              color: AppColors.primaryDark,
              size: 22,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        formatPharmacyDisplay(pharmacy.code),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _AdminStatusPill(active: pharmacy.active),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  'Punto ${pharmacy.code} · ${pharmacy.zone}',
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  pharmacy.address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Ubicación lista para mapa: ${pharmacy.location.latitude.toStringAsFixed(4)}, '
                  '${pharmacy.location.longitude.toStringAsFixed(4)}',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Editar farmacia',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            color: AppColors.muted,
          ),
        ],
      ),
    ),
  );
}

class _AdminZoneCard extends StatelessWidget {
  const _AdminZoneCard({
    required this.zone,
    required this.pharmacies,
    required this.onEdit,
  });

  final AdminZone zone;
  final List<AdminPharmacy> pharmacies;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: zone.color.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.map_rounded, color: zone.color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            zone.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _AdminStatusPill(active: zone.active),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      zone.reference,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Editar zona',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                color: AppColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 17),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _AdminInfoPill(
                icon: Icons.local_pharmacy_outlined,
                label: '${zone.pharmacyCount} farmacias',
              ),
              _AdminInfoPill(
                icon: Icons.delivery_dining_rounded,
                label: '${zone.courierCount} domiciliarios',
              ),
              _AdminInfoPill(
                icon: zone.active
                    ? Icons.check_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                label: zone.active ? 'Disponible para asignar' : 'Pausada',
                color: zone.active ? AppColors.primaryDark : AppColors.muted,
              ),
            ],
          ),
          if (pharmacies.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Farmacias asignadas',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final pharmacy in pharmacies)
                    _AdminPharmacyChip(pharmacy: pharmacy),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _AdminCourierWeekCard extends StatelessWidget {
  const _AdminCourierWeekCard({
    required this.courierName,
    required this.shifts,
    required this.weekStart,
    required this.onOpen,
    required this.onDelete,
  });

  final String courierName;
  final List<AdminShift> shifts;
  final DateTime weekStart;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Semantics(
      button: true,
      label: 'Abrir turnos de $courierName',
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: AppColors.mint,
                child: Icon(
                  Icons.delivery_dining_rounded,
                  color: AppColors.primaryDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      courierName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${shifts.length} turnos · ${_adminCalendarDate(weekStart)} – '
                      '${_adminCalendarDate(weekStart.add(const Duration(days: 6)))}',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Toca para ver el calendario completo',
                      style: TextStyle(
                        color: AppColors.primaryDark,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Borrar semana de $courierName',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                color: AppColors.danger,
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AdminStatusPill extends StatelessWidget {
  const _AdminStatusPill({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: active ? AppColors.mint : AppColors.canvas,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      active ? 'Operativa' : 'Pausada',
      style: TextStyle(
        color: active ? AppColors.primaryDark : AppColors.muted,
        fontSize: 9,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _AdminShiftStatus extends StatelessWidget {
  const _AdminShiftStatus({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final inProgress = status == 'En curso';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: inProgress ? AppColors.mint : AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: inProgress ? AppColors.primaryDark : AppColors.muted,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _AdminInfoPill extends StatelessWidget {
  const _AdminInfoPill({
    required this.icon,
    required this.label,
    this.color = AppColors.muted,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.canvas,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 15),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _AdminEmptyState extends StatelessWidget {
  const _AdminEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.line),
    ),
    child: Column(
      children: [
        Icon(icon, color: AppColors.primaryDark, size: 30),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _AdminZoneDialog extends StatefulWidget {
  const _AdminZoneDialog({this.initial});

  final AdminZone? initial;

  @override
  State<_AdminZoneDialog> createState() => _AdminZoneDialogState();
}

class _AdminZoneDialogState extends State<_AdminZoneDialog> {
  late final TextEditingController _name;
  late final TextEditingController _reference;
  String? _error;

  @override
  void initState() {
    super.initState();
    final zone = widget.initial;
    _name = TextEditingController(text: zone?.name ?? '');
    _reference = TextEditingController(text: zone?.reference ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _reference.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Escribe un nombre para la zona.');
      return;
    }
    Navigator.pop(
      context,
      AdminZone(
        name: name,
        reference: _reference.text.trim().isEmpty
            ? 'Cobertura por definir'
            : _reference.text.trim(),
        pharmacyCount: widget.initial?.pharmacyCount ?? 0,
        courierCount: widget.initial?.courierCount ?? 0,
        active: true,
        color: widget.initial?.color ?? AppColors.primaryDark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Nueva zona' : 'Editar zona'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nombre de la zona',
              hintText: 'Ej. Margen izquierda',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reference,
            decoration: const InputDecoration(
              labelText: 'Barrios o referencias',
              hintText: 'Ej. Centro · La Coquera · P5',
            ),
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Las zonas se mantienen operativas. Las farmacias y domiciliarios se asignan desde sus propios apartados.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Guardar zona')),
    ],
  );
}

class _AdminPharmacyDialog extends StatefulWidget {
  const _AdminPharmacyDialog({required this.initial, required this.zones});

  final AdminPharmacy? initial;
  final List<AdminZone> zones;

  @override
  State<_AdminPharmacyDialog> createState() => _AdminPharmacyDialogState();
}

class _AdminPharmacyDialogState extends State<_AdminPharmacyDialog> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _address;
  late String _zone;
  String? _error;

  @override
  void initState() {
    super.initState();
    final pharmacy = widget.initial;
    _code = TextEditingController(text: pharmacy?.code ?? '');
    _name = TextEditingController(text: pharmacy?.name ?? '');
    _address = TextEditingController(text: pharmacy?.address ?? '');
    final zoneNames = widget.zones.map((zone) => zone.name).toList();
    _zone = pharmacy?.zone != null && zoneNames.contains(pharmacy!.zone)
        ? pharmacy.zone
        : zoneNames.isEmpty
        ? 'Sin zona asignada'
        : zoneNames.first;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  void _save() {
    final code = _code.text.trim();
    final name = _name.text.trim();
    final address = _address.text.trim();
    if (code.isEmpty || name.isEmpty || address.isEmpty) {
      setState(() => _error = 'Completa código, nombre y dirección.');
      return;
    }
    if (_zone == 'Sin zona asignada') {
      setState(() => _error = 'Crea una zona antes de registrar la farmacia.');
      return;
    }
    Navigator.pop(
      context,
      AdminPharmacy(
        code: code,
        name: name,
        address: address,
        zone: _zone,
        location: widget.initial?.location ?? MapsConfig.monteria,
        active: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Nueva farmacia' : 'Editar farmacia'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Código',
                    hintText: 'Ej. 155',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Nombre',
                    hintText: 'FN 155',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Dirección',
              hintText: 'Ej. Calle 27 # 8-18, Centro',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _zone,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zona operativa'),
            items: [
              if (widget.zones.isEmpty)
                const DropdownMenuItem(
                  value: 'Sin zona asignada',
                  child: Text('Sin zona asignada'),
                ),
              for (final zone in widget.zones)
                DropdownMenuItem(value: zone.name, child: Text(zone.name)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _zone = value);
            },
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'La ubicación GPS se deja lista para conectarla al mapa cuando se carguen las coordenadas reales.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Guardar farmacia')),
    ],
  );
}

class _AdminShiftDialog extends StatefulWidget {
  const _AdminShiftDialog({
    required this.initial,
    required this.zones,
    required this.pharmacies,
    required this.couriers,
  });

  final AdminShift? initial;
  final List<AdminZone> zones;
  final List<AdminPharmacy> pharmacies;
  final List<AdminUser> couriers;

  @override
  State<_AdminShiftDialog> createState() => _AdminShiftDialogState();
}

class _AdminShiftDialogState extends State<_AdminShiftDialog> {
  AdminUser? _selectedCourier;
  late String _hours;
  late String _zone;
  late String _pharmacy;
  late bool _isSupport;
  late bool _isDouble;
  late DateTime _scheduledFor;
  String? _error;

  @override
  void initState() {
    super.initState();
    final shift = widget.initial;
    for (final courier in widget.couriers) {
      if (shift != null &&
          ((shift.courierId != null && courier.id == shift.courierId) ||
              courier.name == shift.courierName)) {
        _selectedCourier = courier;
        break;
      }
    }
    _selectedCourier ??= widget.couriers.isEmpty ? null : widget.couriers.first;
    _hours = shift?.hours ?? adminPrimaryHours.first;
    _isSupport = shift?.isSupport ?? false;
    final zoneNames = widget.zones.map((zone) => zone.name).toList();
    _zone = _isSupport
        ? adminSupportZone
        : shift?.zone != null && zoneNames.contains(shift!.zone)
        ? shift.zone
        : zoneNames.isEmpty
        ? 'Sin zona asignada'
        : zoneNames.first;
    final pharmacyCodes = widget.pharmacies
        .where((pharmacy) => pharmacy.zone == _zone)
        .map((pharmacy) => pharmacy.code)
        .toList();
    _pharmacy = _isSupport
        ? adminNoPharmacy
        : shift?.pharmacy != null &&
              (shift!.pharmacy == adminNoPharmacy ||
                  pharmacyCodes.contains(shift.pharmacy))
        ? shift.pharmacy
        : adminZoneAllowsAnyPharmacy(_zone)
        ? adminNoPharmacy
        : pharmacyCodes.isEmpty
        ? adminNoPharmacy
        : pharmacyCodes.first;
    _isDouble = shift?.isDouble ?? false;
    _scheduledFor = shift?.scheduledFor ?? _adminToday();
  }

  List<AdminPharmacy> get _availablePharmacies =>
      widget.pharmacies.where((pharmacy) => pharmacy.zone == _zone).toList();

  void _save() {
    if (_selectedCourier == null) {
      setState(() => _error = 'Registra y activa al menos un domiciliario.');
      return;
    }
    if (!_isSupport && _zone == 'Sin zona asignada') {
      setState(() => _error = 'Selecciona una zona operativa.');
      return;
    }
    if (!_isSupport &&
        !adminZoneAllowsAnyPharmacy(_zone) &&
        _pharmacy == adminNoPharmacy) {
      setState(
        () => _error =
            'Agrega una farmacia a esa zona antes de asignar el turno.',
      );
      return;
    }
    Navigator.pop(
      context,
      AdminShift(
        courierId: _selectedCourier!.id,
        courierName: _selectedCourier!.name,
        hours: _hours,
        zone: _isSupport ? adminSupportZone : _zone,
        pharmacy: _isSupport || adminZoneAllowsAnyPharmacy(_zone)
            ? adminNoPharmacy
            : _pharmacy,
        isDouble: _isDouble,
        secondHours: _isDouble ? adminDoubleHours : null,
        scheduledFor: _scheduledFor,
        color: widget.initial?.color ?? AppColors.primaryDark,
        isSupport: _isSupport,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: Text(widget.initial == null ? 'Nuevo turno' : 'Editar turno'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedCourier == null
                ? null
                : _adminUserOptionKey(_selectedCourier!),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Domiciliario activo'),
            items: [
              for (final courier in widget.couriers)
                DropdownMenuItem(
                  value: _adminUserOptionKey(courier),
                  child: Text('${courier.name} · ${courier.username}'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              for (final courier in widget.couriers) {
                if (_adminUserOptionKey(courier) == value) {
                  setState(() => _selectedCourier = courier);
                  break;
                }
              }
            },
          ),
          if (widget.couriers.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'No hay domiciliarios activos registrados.',
                  style: TextStyle(
                    color: AppColors.danger,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _hours,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Horario'),
            items: [
              for (final hours in adminPrimaryHours)
                DropdownMenuItem(value: hours, child: Text(hours)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _hours = value);
            },
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            value: _isSupport,
            onChanged: (value) => setState(() {
              _isSupport = value;
              if (value) {
                _zone = adminSupportZone;
                _pharmacy = adminNoPharmacy;
              } else {
                _zone = widget.zones.isEmpty
                    ? 'Sin zona asignada'
                    : widget.zones.first.name;
                final pharmacyOptions = widget.pharmacies
                    .where((pharmacy) => pharmacy.zone == _zone)
                    .toList();
                _pharmacy = adminZoneAllowsAnyPharmacy(_zone)
                    ? adminNoPharmacy
                    : pharmacyOptions.isEmpty
                    ? adminNoPharmacy
                    : pharmacyOptions.first.code;
              }
            }),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Apoyo general · todas las zonas',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              _isSupport
                  ? 'Puede recibir solicitudes de cualquier farmacia.'
                  : 'Cubre solo la zona y el punto base seleccionados.',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_isSupport)
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Cobertura'),
              child: const Text(
                'Todas las farmacias y zonas · apoyo general',
                style: TextStyle(
                  color: AppColors.primaryDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else ...[
            DropdownButtonFormField<String>(
              initialValue: _zone,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Zona asignada'),
              items: [
                if (widget.zones.isEmpty)
                  const DropdownMenuItem(
                    value: 'Sin zona asignada',
                    child: Text('Sin zona asignada'),
                  ),
                ...widget.zones.map(
                  (zone) => DropdownMenuItem(
                    value: zone.name,
                    child: Text(zone.name),
                  ),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                final pharmacyCodes = widget.pharmacies
                    .where((pharmacy) => pharmacy.zone == value)
                    .map((pharmacy) => pharmacy.code)
                    .toList();
                setState(() {
                  _zone = value;
                  _pharmacy = adminZoneAllowsAnyPharmacy(value)
                      ? adminNoPharmacy
                      : pharmacyCodes.isEmpty
                      ? adminNoPharmacy
                      : pharmacyCodes.first;
                });
              },
            ),
            const SizedBox(height: 12),
            if (adminZoneAllowsAnyPharmacy(_zone))
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Farmacia específica',
                ),
                child: const Text(
                  'No requerida: puede cubrir cualquier farmacia de la zona.',
                  style: TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _pharmacy,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Farmacia asignada',
                ),
                items: [
                  if (_availablePharmacies.isEmpty)
                    const DropdownMenuItem(
                      value: adminNoPharmacy,
                      child: Text(adminNoPharmacy),
                    ),
                  for (final pharmacy in _availablePharmacies)
                    DropdownMenuItem(
                      value: pharmacy.code,
                      child: Text(formatPharmacyDisplay(pharmacy.code)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _pharmacy = value);
                },
              ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _scheduledFor.isBefore(_adminToday())
                      ? _adminToday()
                      : _scheduledFor,
                  firstDate: _adminToday(),
                  lastDate: _adminToday().add(const Duration(days: 90)),
                  helpText: 'Selecciona el día del turno',
                );
                if (picked == null || !mounted) return;
                setState(() => _scheduledFor = DateUtils.dateOnly(picked));
              },
              icon: const Icon(Icons.calendar_month_outlined, size: 17),
              label: Text(
                'Día: ${_adminWeekdayShort(_scheduledFor)} ${_adminCalendarDate(_scheduledFor)}',
              ),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            value: _isDouble,
            onChanged: (value) => setState(() => _isDouble = value),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '¿Se dobla?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              _isDouble
                  ? 'Segundo bloque automático: $adminDoubleHours'
                  : 'Un solo bloque asignado',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const Text(
                  'Estado automático: ',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _AdminShiftStatus(
                  status: _calculateShiftStatus(
                    date: _scheduledFor,
                    primaryHours: _hours,
                    secondaryHours: _isDouble ? adminDoubleHours : null,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Guardar turno')),
    ],
  );
}

class _AdminPasswordResetDialog extends StatefulWidget {
  const _AdminPasswordResetDialog();

  @override
  State<_AdminPasswordResetDialog> createState() =>
      _AdminPasswordResetDialogState();
}

class _AdminPasswordResetDialogState extends State<_AdminPasswordResetDialog> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _save() {
    final value = _password.text;
    if (value.length < 8) {
      setState(() => _error = 'La contraseña debe tener mínimo 8 caracteres.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Restablecer contraseña'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Escribe una nueva contraseña para este perfil. El usuario y todo su historial se conservan.',
          style: TextStyle(
            color: AppColors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'Nueva contraseña temporal',
            helperText: 'Mínimo 8 caracteres.',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(
              color: AppColors.danger,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Restablecer')),
    ],
  );
}

class _AdminUserCard extends StatelessWidget {
  const _AdminUserCard({
    required this.user,
    required this.onEdit,
    required this.onResetPassword,
  });

  final AdminUser user;
  final VoidCallback onEdit;
  final VoidCallback onResetPassword;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      leading: CircleAvatar(
        backgroundColor: user.active ? AppColors.mint : AppColors.canvas,
        child: Icon(
          user.role == 'Administrador'
              ? Icons.admin_panel_settings_outlined
              : user.role == 'Vendedor de farmacia' ||
                    user.role == 'Cuenta de farmacia'
              ? Icons.storefront_outlined
              : Icons.delivery_dining_rounded,
          color: user.active ? AppColors.primaryDark : AppColors.muted,
        ),
      ),
      title: Text(
        user.name,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        user.role == 'Cuenta de farmacia' || user.role == 'Vendedor de farmacia'
            ? '${user.role} · ${user.pharmacy}\n${user.username} · ${user.pharmacyProfiles.length} perfiles'
            : '${user.role} · ${user.pharmacy}\n${user.username}${user.phone.trim().isEmpty ? '' : ' · ${user.phone}'}',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Restablecer contraseña',
            onPressed: onResetPassword,
            icon: const Icon(Icons.key_outlined),
          ),
          IconButton(
            tooltip: 'Editar usuario',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    ),
  );
}

class _AdminPharmacyProfileDraft {
  _AdminPharmacyProfileDraft({
    required String displayName,
    String username = '',
    this.role = 'vendedor',
    this.id,
    this.active = true,
  }) : name = TextEditingController(text: displayName),
       username = TextEditingController(text: username);

  factory _AdminPharmacyProfileDraft.fromModel(AdminPharmacyProfile profile) =>
      _AdminPharmacyProfileDraft(
        id: profile.id,
        displayName: profile.displayName,
        username: profile.username,
        role: 'vendedor',
        active: profile.active,
      );

  final String? id;
  final TextEditingController name;
  // Kept for existing records. New profiles no longer ask the administrator
  // to invent a username; the server generates a unique internal key.
  final TextEditingController username;
  String role;
  bool active;

  void dispose() {
    name.dispose();
    username.dispose();
  }
}

class _AdminPharmacyProfileEditor extends StatelessWidget {
  const _AdminPharmacyProfileEditor({
    super.key,
    required this.profile,
    required this.position,
    required this.onRemove,
    required this.onChanged,
  });

  final _AdminPharmacyProfileDraft profile;
  final int position;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    color: AppColors.canvas,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Perfil ${position + 1}',
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                tooltip: profile.id == null
                    ? 'Quitar perfil'
                    : 'Desactivar perfil',
                onPressed: onRemove,
                icon: Icon(
                  profile.id == null
                      ? Icons.remove_circle_outline
                      : profile.active
                      ? Icons.person_off_outlined
                      : Icons.person_add_alt_1_outlined,
                  color: profile.active
                      ? AppColors.danger
                      : AppColors.primaryDark,
                ),
              ),
            ],
          ),
          TextField(
            controller: profile.name,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              labelText: 'Nombre del vendedor',
              hintText: 'Ej. Sandy',
              helperText: 'El sistema crea el usuario interno automáticamente.',
            ),
          ),
          const SizedBox(height: 4),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Función: vendedor',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (profile.id != null)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                profile.active ? 'Perfil activo' : 'Perfil desactivado',
              ),
              value: profile.active,
              onChanged: (value) {
                profile.active = value;
                onChanged();
              },
            ),
        ],
      ),
    ),
  );
}

class _AdminAccountChoiceCard extends StatelessWidget {
  const _AdminAccountChoiceCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 92),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? AppColors.mint : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 21,
              color: selected ? AppColors.primaryDark : AppColors.muted,
            ),
            const SizedBox(height: 7),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 9.5,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AdminUserDialog extends StatefulWidget {
  const _AdminUserDialog({required this.initial, required this.pharmacies});

  final AdminUser? initial;
  final List<AdminPharmacy> pharmacies;

  @override
  State<_AdminUserDialog> createState() => _AdminUserDialogState();
}

class _AdminUserDialogState extends State<_AdminUserDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _username;
  late final TextEditingController _password;
  String? _role;
  late String _pharmacy;
  late bool _active;
  int _profileCount = 1;
  final List<_AdminPharmacyProfileDraft> _pharmacyProfiles = [];
  String? _error;

  bool get _isNew => widget.initial == null;
  bool get _isPharmacy => _role == 'Cuenta de farmacia';

  @override
  void initState() {
    super.initState();
    final user = widget.initial;
    _name = TextEditingController(text: user?.name ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _username = TextEditingController(text: user?.username ?? '');
    _password = TextEditingController();
    _role = _roleForUser(user);
    final knownPharmacies = {
      'Sin farmacia asignada',
      ...widget.pharmacies.map((pharmacy) => pharmacy.code),
    };
    _pharmacy = knownPharmacies.contains(user?.pharmacy)
        ? user!.pharmacy
        : 'Sin farmacia asignada';
    _active = user?.active ?? true;
    for (final profile
        in user?.pharmacyProfiles ?? const <AdminPharmacyProfile>[]) {
      _pharmacyProfiles.add(_AdminPharmacyProfileDraft.fromModel(profile));
    }
    _profileCount = _pharmacyProfiles.isEmpty ? 1 : _pharmacyProfiles.length;
  }

  String? _roleForUser(AdminUser? user) {
    if (user == null) return null;
    if (user.role == 'Administrador') return 'Administrador';
    if (user.role == 'Cuenta de farmacia' ||
        user.role == 'Vendedor de farmacia') {
      return 'Cuenta de farmacia';
    }
    return 'Domiciliario';
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _username.dispose();
    _password.dispose();
    for (final profile in _pharmacyProfiles) {
      profile.dispose();
    }
    super.dispose();
  }

  void _suggestPharmacyAccount(String code) {
    if (code == 'Sin farmacia asignada') return;
    final pharmacy = widget.pharmacies.cast<AdminPharmacy?>().firstWhere(
      (item) => item?.code == code,
      orElse: () => null,
    );
    if (pharmacy == null) return;
    if (_isNew || _name.text.trim().isEmpty) {
      _name.text = formatPharmacyDisplay(pharmacy.code);
    }
    if (_isNew && _username.text.trim().isEmpty) {
      _username.text = 'farmanorte.fm${pharmacy.code}';
    }
    if (_isNew && _password.text.isEmpty) {
      _password.text = 'FarmaNorte${pharmacy.code}';
    }
    if (_pharmacyProfiles.isEmpty) _addProfileWithoutSetState();
  }

  void _selectRole(String role) {
    setState(() {
      _role = role;
      _error = null;
      if (role == 'Cuenta de farmacia' && _pharmacyProfiles.isEmpty) {
        _addProfileWithoutSetState();
      }
      if (role == 'Cuenta de farmacia') _suggestPharmacyAccount(_pharmacy);
    });
  }

  void _addProfileWithoutSetState() {
    final number = _pharmacyProfiles.length + 1;
    _pharmacyProfiles.add(
      _AdminPharmacyProfileDraft(displayName: 'Perfil $number'),
    );
    _profileCount = _pharmacyProfiles.length;
  }

  void _setProfileCount(int value) {
    setState(() {
      _profileCount = value;
      while (_pharmacyProfiles.length < value) {
        _addProfileWithoutSetState();
      }
      while (_pharmacyProfiles.length > value) {
        final last = _pharmacyProfiles.removeLast();
        if (last.id == null) last.dispose();
      }
    });
  }

  void _addPharmacyProfile() {
    setState(_addProfileWithoutSetState);
  }

  void _removePharmacyProfile(int index) {
    final profile = _pharmacyProfiles[index];
    if (profile.id != null && profile.id!.isNotEmpty) {
      setState(() => profile.active = false);
      return;
    }
    if (_pharmacyProfiles.length == 1) {
      setState(() => _error = 'Debe quedar al menos un perfil vendedor.');
      return;
    }
    setState(() {
      profile.dispose();
      _pharmacyProfiles.removeAt(index);
      _profileCount = _pharmacyProfiles.length;
    });
  }

  String _pharmacyAccountName() {
    if (_pharmacy != 'Sin farmacia asignada') {
      final pharmacy = widget.pharmacies.cast<AdminPharmacy?>().firstWhere(
        (item) => item?.code == _pharmacy,
        orElse: () => null,
      );
      if (pharmacy != null) return formatPharmacyDisplay(pharmacy.code);
    }
    return _name.text.trim();
  }

  void _save() {
    final isPharmacy = _isPharmacy;
    final name = isPharmacy ? _pharmacyAccountName() : _name.text.trim();
    final phone = _phone.text.trim();
    final username = _username.text.trim().toLowerCase();
    final password = _password.text;
    if (_role == null) {
      setState(() => _error = 'Selecciona el tipo de cuenta.');
      return;
    }
    if (name.isEmpty || username.isEmpty) {
      setState(() => _error = 'Completa nombre y usuario.');
      return;
    }
    if (!isPharmacy && phone.isEmpty) {
      setState(() => _error = 'Escribe el número de teléfono.');
      return;
    }
    final normalizedPhone = phone.replaceAll(RegExp(r'\D'), '');
    if (!isPharmacy && !RegExp(r'^3\d{9}$').hasMatch(normalizedPhone)) {
      setState(
        () => _error =
            'El teléfono debe empezar por 3 y tener exactamente 10 números.',
      );
      return;
    }
    if (_isNew && password.isEmpty) {
      setState(() => _error = 'Define una contraseña inicial.');
      return;
    }
    if (password.isNotEmpty && password.length < 8) {
      setState(() => _error = 'La contraseña debe tener mínimo 8 caracteres.');
      return;
    }
    if (isPharmacy && _pharmacy == 'Sin farmacia asignada') {
      setState(() => _error = 'Selecciona una de las farmacias reales.');
      return;
    }
    if (isPharmacy && _pharmacyProfiles.isEmpty) {
      setState(() => _error = 'Agrega al menos un perfil vendedor.');
      return;
    }

    final profiles = <AdminPharmacyProfile>[];
    for (final profile in _pharmacyProfiles) {
      final profileName = profile.name.text.trim();
      if (isPharmacy && profileName.isEmpty) {
        setState(() => _error = 'Completa el nombre de cada vendedor.');
        return;
      }
      profiles.add(
        AdminPharmacyProfile(
          id: profile.id,
          displayName: profileName,
          // Existing rows keep their internal key. New rows receive one from
          // the Edge Function, so duplicate names can never block creation.
          username: profile.id == null ? '' : profile.username.text.trim(),
          role: 'vendedor',
          active: profile.active,
        ),
      );
    }

    Navigator.pop(
      context,
      AdminUser(
        id: widget.initial?.id,
        name: name,
        phone: normalizedPhone,
        username: username,
        role: _role!,
        pharmacy: isPharmacy ? _pharmacy : 'Sin farmacia asignada',
        active: _active,
        temporaryPassword: password.isEmpty ? null : password,
        pharmacyProfiles: profiles,
      ),
    );
  }

  Widget _roleCard({
    required String role,
    required IconData icon,
    required String title,
    required String description,
  }) => _AdminAccountChoiceCard(
    icon: icon,
    title: title,
    description: description,
    selected: _role == role,
    onTap: () => _selectRole(role),
  );

  Widget _buildRolePicker() {
    if (!_isNew) {
      return InputDecorator(
        decoration: const InputDecoration(labelText: 'Tipo de cuenta'),
        child: Text(
          _role == 'Cuenta de farmacia'
              ? 'Farmacia · cuenta con perfiles vendedores'
              : _role ?? 'Sin tipo',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '¿Qué cuenta vas a crear?',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - 16) / 3;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: width,
                  child: _roleCard(
                    role: 'Administrador',
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Administrador',
                    description: 'Acceso total',
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _roleCard(
                    role: 'Domiciliario',
                    icon: Icons.delivery_dining_rounded,
                    title: 'Domiciliario',
                    description: 'Nombre y acceso',
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _roleCard(
                    role: 'Cuenta de farmacia',
                    icon: Icons.local_pharmacy_outlined,
                    title: 'Farmacia',
                    description: 'Cuenta + vendedores',
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildCommonAccessFields() => Column(
    children: [
      TextField(
        controller: _username,
        keyboardType: TextInputType.text,
        readOnly: widget.initial != null,
        decoration: const InputDecoration(
          labelText: 'Usuario de acceso',
          hintText: 'Ej. farmanorte.fm357',
          helperText: 'No necesitas usar un correo personal.',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: InputDecoration(
          labelText: widget.initial == null
              ? 'Contraseña inicial'
              : 'Nueva contraseña temporal (opcional)',
          helperText: widget.initial == null
              ? 'Mínimo 8 caracteres.'
              : 'Déjala vacía para conservar la actual.',
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Nuevo usuario' : 'Editar usuario'),
    content: SizedBox(
      width: (MediaQuery.sizeOf(context).width - 48)
          .clamp(280.0, 520.0)
          .toDouble(),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRolePicker(),
            if (_role != null) ...[
              if (_isNew) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _role = null),
                    icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                    label: const Text('Cambiar tipo'),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              if (_isPharmacy) ...[
                DropdownButtonFormField<String>(
                  initialValue: _pharmacy,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Farmacia real',
                    helperText: 'Selecciona una de las farmacias cargadas.',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'Sin farmacia asignada',
                      child: Text('Selecciona una farmacia'),
                    ),
                    ...widget.pharmacies.map(
                      (pharmacy) => DropdownMenuItem(
                        value: pharmacy.code,
                        child: Text(
                          '${formatPharmacyDisplay(pharmacy.code)} · ${pharmacy.zone}',
                        ),
                      ),
                    ),
                  ],
                  onChanged: widget.initial != null
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _pharmacy = value;
                            _suggestPharmacyAccount(value);
                          });
                        },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la cuenta',
                    helperText: 'Se toma del código de la farmacia.',
                  ),
                ),
                const SizedBox(height: 12),
                _buildCommonAccessFields(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Perfiles vendedores',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                    if (!_isNew)
                      TextButton.icon(
                        onPressed: _addPharmacyProfile,
                        icon: const Icon(Icons.person_add_alt_1, size: 16),
                        label: const Text('Agregar'),
                      ),
                  ],
                ),
                if (_isNew)
                  DropdownButtonFormField<int>(
                    initialValue: _profileCount,
                    decoration: const InputDecoration(
                      labelText: 'Cantidad de perfiles',
                      helperText: 'Todos tendrán función de vendedor.',
                    ),
                    items: [
                      for (var count = 1; count <= 10; count++)
                        DropdownMenuItem(
                          value: count,
                          child: Text(
                            '$count ${count == 1 ? 'perfil' : 'perfiles'}',
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _setProfileCount(value);
                    },
                  )
                else
                  const Text(
                    'Cambia el nombre o desactiva un perfil para conservar su historial.',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 8),
                ..._pharmacyProfiles.asMap().entries.map(
                  (entry) => _AdminPharmacyProfileEditor(
                    key: ObjectKey(entry.value),
                    position: entry.key,
                    profile: entry.value,
                    onRemove: () => _removePharmacyProfile(entry.key),
                    onChanged: () => setState(() {}),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Nombre completo',
                    hintText: 'Ej. Leonardo Acosta',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 10,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono',
                    hintText: 'Ej. 3001234567',
                    helperText: 'Empieza por 3 y usa 10 números.',
                  ),
                ),
                const SizedBox(height: 12),
                _buildCommonAccessFields(),
              ],
              if (widget.initial != null) ...[
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Usuario activo'),
                  subtitle: Text(
                    _active ? 'Puede iniciar sesión.' : 'No puede iniciar sesión, pero se conserva su historial.',
                  ),
                  value: _active,
                  onChanged: (value) => setState(() => _active = value),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.danger.withAlpha(18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: _role == null ? null : _save,
        child: Text(
          widget.initial == null ? 'Crear usuario' : 'Guardar cambios',
        ),
      ),
    ],
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.profile});

  final SupabaseUserProfile? profile;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Delivery> _deliveries = SupabaseConfig.isConfigured
      ? <Delivery>[]
      : StageZeroDemoStore.instance.deliveries.value.toList();
  StreamSubscription<List<Delivery>>? _remoteDeliveriesSubscription;
  Timer? _offerRefreshTimer;
  final Map<String, DeliveryStatus> _remoteDeliveryStatuses = {};
  final Map<String, String?> _remoteAcceptedCouriers = {};
  final Map<String, String> _equivalentStatuses = {};
  bool _remoteDeliveryBaselineReady = false;
  bool _connected = true;
  bool _appInBackground = false;
  bool _autoAccepting = false;
  Timer? _presenceHeartbeat;
  List<AdminShift> _courierShifts = const [];
  DateTime _courierWeekStart = adminPublishWeekStart(_adminToday());
  bool _loadingCourierShifts = false;
  String? _courierShiftError;
  CourierFeeSummary? _feeSummary;
  bool _loadingFeeSummary = false;
  List<CourierPharmacyBreakdown> _courierPharmacyBreakdown = const [];
  bool _loadingCourierBreakdown = false;
  String? _courierPharmacyBreakdownError;

  String get _courierName {
    final name = widget.profile?.fullName.trim() ?? '';
    return name.isEmpty ? 'Domiciliario' : name;
  }

  String get _courierId {
    final id = widget.profile?.id.trim() ?? '';
    return id.isEmpty ? OperationsBackend.courierId : id;
  }

  String? get _basePharmacyCode {
    final today = _adminToday();
    for (final shift in _courierShifts) {
      if (DateUtils.isSameDay(shift.scheduledFor, today) &&
          shift.pharmacy != adminNoPharmacy) {
        return shift.pharmacy;
      }
    }
    if (!SupabaseConfig.isConfigured) {
      for (final shift in _courierShifts) {
        if (shift.pharmacy != adminNoPharmacy) return shift.pharmacy;
      }
    }
    return courierBasePharmacyCode.isEmpty ? null : courierBasePharmacyCode;
  }

  bool get _hasGlobalSupportShiftToday => _courierShifts.any(
    (shift) =>
        DateUtils.isSameDay(shift.scheduledFor, _adminToday()) &&
        shift.isSupport,
  );

  String get _baseLabel {
    if (_hasGlobalSupportShiftToday && _basePharmacyCode == null) {
      return 'Apoyo general · toda la red';
    }
    final code = _basePharmacyCode;
    return code == null ? 'Punto base pendiente de asignación' : 'FN $code';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AppNotificationAudio.initialize());
    AppNotificationNavigation.pending.addListener(_onPendingNotification);
    StageZeroDemoStore.instance.deliveries.addListener(
      _onLocalDeliveriesChanged,
    );
    unawaited(_connectToOperations());
    unawaited(_consumePendingNotification());
    unawaited(_loadCourierEquivalentStatuses());
    unawaited(_loadCourierPharmacyBreakdown());
    unawaited(_loadCourierShifts());
    _publishPresence(true);
    _presenceHeartbeat = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      _publishPresence(_connected && !_appInBackground);
    });
    // Prioridad de zona (migración 039): al terminar los 3 minutos de reserva
    // la base no emite ningún cambio, así que la lista se vuelve a leer cada
    // 30 s para que el apoyo vea la oferta liberada sin recargar la app.
    _offerRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || _appInBackground) return;
      if (!SupabaseConfig.isConfigured ||
          !SupabaseOperationsService.instance.hasAuthenticatedUser) {
        return;
      }
      unawaited(_reconnectOperations());
    });
  }

  Future<void> _reconnectOperations() async {
    final previous = _remoteDeliveriesSubscription;
    _remoteDeliveriesSubscription = null;
    await previous?.cancel();
    if (!mounted) return;
    await _connectToOperations();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppNotificationNavigation.pending.removeListener(_onPendingNotification);
    StageZeroDemoStore.instance.deliveries.removeListener(
      _onLocalDeliveriesChanged,
    );
    unawaited(_remoteDeliveriesSubscription?.cancel());
    _offerRefreshTimer?.cancel();
    _presenceHeartbeat?.cancel();
    _publishPresence(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isBackground =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (_appInBackground == isBackground) return;
    if (mounted) setState(() => _appInBackground = isBackground);
    // The push token continues working while the app is in the background;
    // the presence row is marked paused so the pharmacy sees the real state.
    _publishPresence(!isBackground && _connected);
    if (!isBackground && _autoAccepting) {
      unawaited(_autoAcceptBaseOffers());
    }
  }

  void _publishPresence(bool connected) {
    unawaited(
      OperationsBackend.instance.publishCourierConnection(
        courierId: _courierId,
        connected: connected,
      ),
    );
  }

  void _onPendingNotification() {
    unawaited(_consumePendingNotification());
  }

  Future<void> _consumePendingNotification() async {
    if (!mounted) return;
    final action = AppNotificationNavigation.pending.value;
    if (action == null) return;
    final delivery = _deliveries.cast<Delivery?>().firstWhere(
      (item) => item?.id == action.deliveryId,
      orElse: () => null,
    );
    if (delivery == null) {
      // Si la lista real ya cargó y el domicilio no está, otro domiciliario
      // lo tomó o ya no está disponible: se informa en vez de esperar siempre.
      if (_remoteDeliveryBaselineReady) {
        AppNotificationNavigation.pending.value = null;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Ese domicilio ya no está disponible para ti.'),
            ),
          );
      }
      return;
    }
    AppNotificationNavigation.pending.value = null;
    if (action.openChat) {
      _openDeliveryChat(delivery);
    } else {
      await _openDeliveryDetail(delivery);
    }
  }

  void _onLocalDeliveriesChanged() {
    if (!mounted) return;
    if (SupabaseConfig.isConfigured &&
        SupabaseOperationsService.instance.hasAuthenticatedUser) {
      return;
    }
    setState(
      () => _deliveries = StageZeroDemoStore.instance.deliveries.value.toList(),
    );
  }

  Future<void> _connectToOperations() async {
    final stream = await OperationsBackend.instance.watchDeliveries();
    if (!mounted || stream == null) return;
    _remoteDeliveriesSubscription = stream.listen((remoteDeliveries) {
      if (!mounted) return;
      final newOffers = _remoteDeliveryBaselineReady
          ? remoteDeliveries.where((delivery) {
              final previousStatus = _remoteDeliveryStatuses[delivery.id];
              return delivery.status == DeliveryStatus.offered &&
                  previousStatus != DeliveryStatus.offered;
            }).toList()
          : const <Delivery>[];
      final newAssignments = _remoteDeliveryBaselineReady
          ? remoteDeliveries.where((delivery) {
              final previousStatus = _remoteDeliveryStatuses[delivery.id];
              final previousCourier = _remoteAcceptedCouriers[delivery.id];
              return delivery.status == DeliveryStatus.accepted &&
                  delivery.acceptedCourierId == _courierId &&
                  (previousStatus != DeliveryStatus.accepted ||
                      previousCourier != _courierId);
            }).toList()
          : const <Delivery>[];
      _remoteDeliveryStatuses
        ..clear()
        ..addEntries(
          remoteDeliveries.map(
            (delivery) => MapEntry(delivery.id, delivery.status),
          ),
        );
      _remoteAcceptedCouriers
        ..clear()
        ..addEntries(
          remoteDeliveries.map(
            (delivery) => MapEntry(delivery.id, delivery.acceptedCourierId),
          ),
        );
      _remoteDeliveryBaselineReady = true;
      setState(() => _deliveries = remoteDeliveries);
      unawaited(_consumePendingNotification());
      unawaited(_loadCourierEquivalentStatuses());
      unawaited(_loadCourierPharmacyBreakdown());
      if (newOffers.isNotEmpty) {
        unawaited(
          AppNotificationAudio.playDeliveryAlertFor(
            newOffers.map((delivery) => delivery.id),
            assigned: false,
          ),
        );
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                newOffers.length == 1
                    ? 'Nuevo domicilio disponible.'
                    : '${newOffers.length} domicilios nuevos disponibles.',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
      }
      if (newAssignments.isNotEmpty) {
        unawaited(
          AppNotificationAudio.playDeliveryAlertFor(
            newAssignments.map((delivery) => delivery.id),
            assigned: true,
          ),
        );
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                newAssignments.length == 1
                    ? 'La farmacia te asignó un domicilio.'
                    : 'La farmacia te asignó ${newAssignments.length} domicilios.',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
      }
      if (_autoAccepting) unawaited(_autoAcceptBaseOffers());
    });
  }

  Future<void> _loadCourierShifts() async {
    if (!mounted) return;
    setState(() {
      _loadingCourierShifts = true;
      _courierShiftError = null;
    });
    try {
      var shifts = await OperationsBackend.instance.loadCourierShifts(
        courierId: _courierId,
        weekStart: _courierWeekStart,
      );
      final currentWeek = _adminWeekStart(_adminToday());
      if (SupabaseConfig.isConfigured && _courierWeekStart != currentWeek) {
        final currentShifts = await OperationsBackend.instance
            .loadCourierShifts(courierId: _courierId, weekStart: currentWeek);
        shifts = [...currentShifts, ...shifts];
      }
      if (!SupabaseConfig.isConfigured && shifts.isEmpty) {
        shifts = demoAdminShifts
            .where((shift) => shift.courierName == _courierName)
            .toList();
        if (shifts.isNotEmpty) {
          _courierWeekStart = _adminWeekStart(shifts.first.scheduledFor);
        }
      }
      if (!mounted) return;
      setState(() => _courierShifts = shifts);
      unawaited(_loadCourierFeeSummary());
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _courierShiftError = '$error'.replaceFirst('Bad state: ', ''),
      );
    } finally {
      if (mounted) setState(() => _loadingCourierShifts = false);
    }
  }

  Future<void> _loadCourierFeeSummary() async {
    if (!SupabaseConfig.isConfigured || !mounted) return;
    setState(() => _loadingFeeSummary = true);
    try {
      final summary = await OperationsBackend.instance.loadCourierFeeSummary(
        weekStart: _courierWeekStart,
      );
      if (mounted) setState(() => _feeSummary = summary);
    } catch (_) {
      if (mounted) setState(() => _feeSummary = null);
    } finally {
      if (mounted) setState(() => _loadingFeeSummary = false);
    }
  }

  Future<void> _loadCourierEquivalentStatuses() async {
    if (!SupabaseConfig.isConfigured || !mounted) return;
    try {
      final statuses = await OperationsBackend.instance
          .loadCourierEquivalentStatuses();
      if (!mounted) return;
      setState(() {
        _equivalentStatuses
          ..clear()
          ..addAll(statuses);
      });
    } catch (_) {
      // La operación continúa; si no se pudo consultar, el equivalente no se
      // considera liberado y no se suma a las ganancias.
    }
  }

  Future<void> _loadCourierPharmacyBreakdown() async {
    if (!mounted) return;
    setState(() {
      _loadingCourierBreakdown = true;
      _courierPharmacyBreakdownError = null;
    });
    try {
      final breakdown = await OperationsBackend.instance
          .loadCourierPharmacyBreakdown();
      if (mounted) {
        setState(() {
          _courierPharmacyBreakdown = breakdown;
          _courierPharmacyBreakdownError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _courierPharmacyBreakdown = const [];
          _courierPharmacyBreakdownError = error
              .toString()
              .replaceFirst('PostgrestException(message: ', '')
              .split(', code:')
              .first
              .replaceFirst('Exception: ', '')
              .trim();
        });
      }
    } finally {
      if (mounted) setState(() => _loadingCourierBreakdown = false);
    }
  }

  List<Delivery> get _available => _deliveries
      .where(
        (item) =>
            item.status == DeliveryStatus.offered && !item.approvalPending,
      )
      .toList();

  List<Delivery> get _pendingApprovals =>
      _deliveries.where((item) => item.approvalPending).toList();

  List<Delivery> get _active => _deliveries
      .where(
        (item) =>
            item.status == DeliveryStatus.accepted ||
            item.status == DeliveryStatus.pickedUp,
      )
      .toList();

  bool _equivalentReleased(Delivery item) =>
      _equivalentStatuses[item.id] == 'signed' ||
      _equivalentStatuses[item.id] == 'acknowledged';

  List<Delivery> get _completedDeliveries => _deliveries
      .where(
        (item) =>
            item.status == DeliveryStatus.delivered ||
            item.status == DeliveryStatus.notDelivered,
      )
      .toList();

  int get _pendingEquivalentCount =>
      _completedDeliveries.where((item) => !_equivalentReleased(item)).length;

  double get _pendingEquivalentAmount => _completedDeliveries
      .where((item) => !_equivalentReleased(item))
      .fold(0.0, (total, item) => total + item.serviceFee);

  double get _earnings => _deliveries
      .where(
        (item) =>
            item.status == DeliveryStatus.delivered &&
            _equivalentReleased(item),
      )
      .fold(0.0, (total, item) => total + item.serviceFee);

  Future<void> _openDeliveryDetail(Delivery item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeliveryDetailScreen(delivery: item, onChanged: _replace),
      ),
    );
    await _loadCourierEquivalentStatuses();
  }

  void _replace(Delivery item) {
    final index = _deliveries.indexWhere((delivery) => delivery.id == item.id);
    if (index >= 0) {
      if (!SupabaseConfig.isConfigured) {
        StageZeroDemoStore.instance.updateDelivery(item);
      }
      setState(() => _deliveries[index] = item);
    }
  }

  void _setConnected(bool connected) {
    setState(() {
      _connected = connected;
      if (!connected) _autoAccepting = false;
    });
    _publishPresence(connected && !_appInBackground);
  }

  void _setAutoAccepting(bool enabled) {
    if (!enabled || !_connected) {
      setState(() => _autoAccepting = false);
      return;
    }
    final baseCode = _basePharmacyCode;
    final globalSupport = _hasGlobalSupportShiftToday;
    if (baseCode == null && !globalSupport) {
      setState(() => _autoAccepting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'No hay un punto base asignado en tu turno. El administrador debe asignarlo primero.',
            ),
          ),
        );
      return;
    }

    setState(() {
      _autoAccepting = true;
    });
    unawaited(_autoAcceptBaseOffers());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            globalSupport
                ? 'Autoaceptado activo para todas las zonas como apoyo general.'
                : 'Autoaceptado activo solo para $baseCode. Los demás domicilios se aceptan manualmente.',
          ),
        ),
      );
  }

  Future<void> _autoAcceptBaseOffers() async {
    final baseCode = _basePharmacyCode;
    final globalSupport = _hasGlobalSupportShiftToday;
    if ((baseCode == null && !globalSupport) || !_connected) return;
    final baseOffers = _deliveries
        .where(
          (item) =>
              item.status == DeliveryStatus.offered &&
              !item.approvalPending &&
              (globalSupport || item.pharmacyCode == baseCode),
        )
        .toList();
    for (final item in baseOffers) {
      if (SupabaseConfig.isConfigured) {
        bool accepted = false;
        try {
          accepted = await OperationsBackend.instance.acceptDelivery(
            deliveryId: item.id,
            asSupport:
                globalSupport &&
                (baseCode == null || item.pharmacyCode != baseCode),
          );
        } catch (_) {
          // Otro cambio en tiempo real puede haber cerrado la oferta. El resto
          // de los domicilios debe seguir procesándose sin romper el flujo.
          continue;
        }
        if (!accepted || !mounted) continue;
      } else {
        StageZeroDemoStore.instance.updateDelivery(
          item.copyWith(status: DeliveryStatus.accepted),
        );
      }
      if (!mounted) return;
      final index = _deliveries.indexWhere(
        (delivery) => delivery.id == item.id,
      );
      if (index >= 0) {
        setState(
          () => _deliveries[index] = item.copyWith(
            status: DeliveryStatus.accepted,
          ),
        );
      }
    }
  }

  void _accept(Delivery item) {
    if (!_connected) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Activa tu conexión para aceptar domicilios.'),
          ),
        );
      return;
    }
    if (item.status != DeliveryStatus.offered) return;

    // En producción cada domicilio es una operación independiente: el mismo
    // domiciliario puede aceptar varios pedidos distintos. La aprobación
    // adicional se conserva únicamente para el modo de demostración antiguo.
    if (SupabaseConfig.isConfigured) {
      unawaited(_acceptRealDelivery(item));
      return;
    }

    if (_active.isNotEmpty) {
      StageZeroDemoStore.instance.requestPharmacyApproval(
        deliveryId: item.id,
        courierName: _courierName,
      );
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Solicitud enviada a la farmacia. Tiene 5 minutos para aprobar.',
            ),
          ),
        );
      return;
    }

    if (SupabaseConfig.isConfigured) {
      unawaited(_acceptRealDelivery(item));
      return;
    }
    final accepted = item.copyWith(status: DeliveryStatus.accepted);
    _replace(accepted);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeliveryDetailScreen(delivery: accepted, onChanged: _replace),
      ),
    );
  }

  Future<void> _acceptRealDelivery(Delivery item) async {
    bool accepted;
    try {
      accepted = await OperationsBackend.instance.acceptDelivery(
        deliveryId: item.id,
        asSupport:
            _hasGlobalSupportShiftToday &&
            (_basePharmacyCode == null ||
                item.pharmacyCode != _basePharmacyCode),
      );
    } catch (error) {
      if (!mounted) return;
      final detail = '$error'
          .replaceFirst('PostgrestException(message: ', '')
          .split(', code:')
          .first
          .replaceFirst('Exception: ', '')
          .trim();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('No se pudo aceptar: $detail')));
      return;
    }
    if (!mounted) return;
    if (!accepted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Otro domiciliario tomó este pedido o ya no está disponible.',
            ),
          ),
        );
      return;
    }
    final next = item.copyWith(status: DeliveryStatus.accepted);
    final index = _deliveries.indexWhere((delivery) => delivery.id == item.id);
    if (index >= 0) setState(() => _deliveries[index] = next);
    unawaited(_loadCourierPharmacyBreakdown());
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeliveryDetailScreen(delivery: next, onChanged: _replace),
      ),
    );
  }

  void _openShiftSchedule() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .82,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Turnos de la semana',
                          style: TextStyle(
                            color: AppColors.ink,
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Actualizar turnos',
                        onPressed: _loadingCourierShifts
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                unawaited(_loadCourierShifts());
                              },
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  Text(
                    'Semana del ${_adminCalendarDate(_courierWeekStart)} al '
                    '${_adminCalendarDate(_courierWeekStart.add(const Duration(days: 6)))} · $_baseLabel',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_loadingCourierShifts)
                    const LinearProgressIndicator()
                  else if (_courierShiftError != null)
                    _AdminEmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: 'No se pudieron cargar los turnos',
                      message: _courierShiftError!,
                    )
                  else
                    _CourierWeeklyCalendar(
                      weekStart: _courierWeekStart,
                      shifts: _courierShifts,
                    ),
                  const SizedBox(height: 12),
                  if (_courierShifts.isEmpty && !_loadingCourierShifts)
                    const Text(
                      'Todavía no hay turnos publicados para esta semana.',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _courierShifts.isEmpty
                            ? null
                            : () => unawaited(_downloadCourierWeekPdf()),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Descargar PDF'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Cerrar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadCourierWeekPdf() async {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: pdf.PdfPageFormat.a4,
        build: (context) => [
          pw.Text(
            'farmanorte · Turnos de $_courierName',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Semana del ${_adminCalendarDate(_courierWeekStart)} al '
            '${_adminCalendarDate(_courierWeekStart.add(const Duration(days: 6)))}',
          ),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: const ['Día', 'Horario', 'Zona', 'Punto base'],
            data: [
              for (var day = 0; day < 7; day++)
                () {
                  final date = _courierWeekStart.add(Duration(days: day));
                  final dayShifts = _courierShifts
                      .where(
                        (shift) =>
                            DateUtils.isSameDay(shift.scheduledFor, date),
                      )
                      .toList();
                  if (dayShifts.isEmpty) {
                    return [
                      '${_adminWeekdayShort(date)} ${_adminCalendarDate(date)}',
                      'Descanso',
                      '—',
                      '—',
                    ];
                  }
                  final shift = dayShifts.first;
                  return [
                    '${_adminWeekdayShort(date)} ${_adminCalendarDate(date)}',
                    shift.displayHours,
                    shift.zone,
                    shift.pharmacyLabel,
                  ];
                }(),
            ],
          ),
          pw.SizedBox(height: 20),
          pw.Text('Documento generado desde la aplicación farmanorte.'),
        ],
      ),
    );
    final bytes = await document.save();
    if (!mounted) return;
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'turnos-${_courierName.replaceAll(' ', '-').toLowerCase()}.pdf',
    );
  }

  Future<void> _callSupport() async {
    final opened = await _launchPhoneCall(farmanorteSupportPhone);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('No se pudo abrir la aplicación de teléfono.'),
          ),
        );
    }
  }

  void _openAlertSoundSettings() {
    unawaited(BackgroundNotificationService.refreshPermissionStatus());
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sonidos de alerta',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Controla las alertas de domicilios y mensajes del chat.',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<NotificationPermissionStatus>(
                  valueListenable:
                      BackgroundNotificationService.permissionStatus,
                  builder: (context, status, _) {
                    final granted =
                        status == NotificationPermissionStatus.granted;
                    final denied =
                        status == NotificationPermissionStatus.denied;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        granted
                            ? Icons.notifications_active_outlined
                            : Icons.notifications_off_outlined,
                        color: granted
                            ? AppColors.primary
                            : denied
                            ? AppColors.danger
                            : AppColors.muted,
                      ),
                      title: Text(
                        granted
                            ? 'Notificaciones activadas'
                            : denied
                            ? 'Notificaciones desactivadas'
                            : 'Notificaciones sin confirmar',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        granted
                            ? 'Recibirás domicilios con la app en segundo plano.'
                            : 'Actívalas para recibir domicilios con la app cerrada.',
                      ),
                      trailing: granted
                          ? null
                          : TextButton(
                              onPressed: () => unawaited(
                                BackgroundNotificationService.enableFromUserTap(),
                              ),
                              child: const Text('Activar'),
                            ),
                    );
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Sonido de notificaciones',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('También recibirás la alerta visual.'),
                  value: AppNotificationAudio.enabled,
                  onChanged: (value) {
                    unawaited(() async {
                      await AppNotificationAudio.setEnabled(value);
                      if (context.mounted) setSheetState(() {});
                    }());
                  },
                ),
                Row(
                  children: [
                    const Icon(
                      Icons.volume_down_outlined,
                      color: AppColors.muted,
                      size: 18,
                    ),
                    Expanded(
                      child: Slider(
                        value: AppNotificationAudio.volume,
                        min: .1,
                        max: 1.0,
                        divisions: 9,
                        label:
                            '${(AppNotificationAudio.volume * 100).round()}%',
                        onChanged: (value) {
                          unawaited(AppNotificationAudio.setVolume(value));
                          setSheetState(() {});
                        },
                      ),
                    ),
                    const Icon(
                      Icons.volume_up_outlined,
                      color: AppColors.muted,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8E8),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.warning.withValues(alpha: .28),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.draw_outlined, color: AppColors.warning),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          _pendingEquivalentCount == 0
                              ? 'No tienes equivalentes pendientes por firmar.'
                              : 'Tienes $_pendingEquivalentCount equivalente(s) pendiente(s) por firmar. ${_money(_pendingEquivalentAmount)} no suma todavía a tus ganancias.',
                          style: const TextStyle(
                            color: AppColors.ink,
                            fontSize: 11,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                RadioGroup<String>(
                  groupValue: AppNotificationAudio.selectedSound.id,
                  onChanged: (value) {
                    if (value == null) return;
                    unawaited(() async {
                      await AppNotificationAudio.selectSound(value);
                      if (context.mounted) setSheetState(() {});
                    }());
                  },
                  child: Column(
                    children: [
                      for (final option in courierAlertSoundOptions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Radio<String>(value: option.id),
                          title: Text(
                            option.label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(option.description),
                          trailing: IconButton(
                            tooltip: 'Probar ${option.label}',
                            onPressed: () => unawaited(
                              AppNotificationAudio.preview(option.id),
                            ),
                            icon: const Icon(Icons.volume_up_outlined),
                          ),
                          onTap: () {
                            unawaited(() async {
                              await AppNotificationAudio.selectSound(option.id);
                              if (context.mounted) setSheetState(() {});
                            }());
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Cerrar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openDeliveryHistory() async {
    final history = _deliveries
        .where(
          (delivery) =>
              delivery.status == DeliveryStatus.delivered ||
              delivery.status == DeliveryStatus.notDelivered,
        )
        .toList()
        .reversed
        .toList();
    final selected = await showModalBottomSheet<Delivery>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (_) => _CourierDeliveryHistorySheet(
        deliveries: history,
        equivalentStatuses: _equivalentStatuses,
      ),
    );
    if (!mounted || selected == null) return;
    await _openDeliveryDetail(selected);
  }

  void _logout() {
    unawaited(() async {
      try {
        await OperationsBackend.instance.signOut();
      } catch (_) {
        // La navegación local no debe quedar bloqueada por un error remoto.
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }());
  }

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * .88,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: AppColors.mint,
                    child: Icon(
                      Icons.person_rounded,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  title: Text(
                    _courierName,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text('Domiciliario · $_baseLabel'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.logout_rounded,
                    color: AppColors.danger,
                  ),
                  title: const Text('Cerrar sesión'),
                  subtitle: const Text('Salir de la cuenta actual'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _logout();
                  },
                ),
                const Divider(height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text('Turnos de la semana'),
                  subtitle: const Text('Ver punto base y horario publicado'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openShiftSchedule();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Configuración'),
                  subtitle: Text('Alertas, sonido y equivalentes pendientes'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openAlertSoundSettings();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('Historial de domicilios'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openDeliveryHistory();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.support_agent_rounded),
                  title: const Text('Ayuda y soporte'),
                  subtitle: Text(
                    '$farmanorteSupportName · $farmanorteSupportPhone',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_callSupport());
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDeliveryChat(Delivery delivery) {
    if (!SupabaseConfig.isConfigured) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'El chat requiere la conexión real de Supabase; no se usan mensajes locales.',
            ),
          ),
        );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => FractionallySizedBox(
        heightFactor: .78,
        child: DeliveryChatSheet(deliveryId: delivery.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _HomeTopBar(
                connected: _connected,
                inBackground: _appInBackground,
                courierName: _courierName,
                onMenu: _openMenu,
                onChanged: _setConnected,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _HomeSheet(
                connected: _connected && !_appInBackground,
                baseLabel: _baseLabel,
                autoAccepting: _autoAccepting,
                available: _available,
                active: _active,
                pendingApprovals: _pendingApprovals,
                earnings: _earnings,
                feeSummary: _feeSummary,
                loadingFeeSummary: _loadingFeeSummary,
                onAutoAccept: _setAutoAccepting,
                onAccept: _accept,
                onDetail: (item) {
                  unawaited(_openDeliveryDetail(item));
                },
                onChat: _openDeliveryChat,
                pendingEquivalentCount: _pendingEquivalentCount,
                pendingEquivalentAmount: _pendingEquivalentAmount,
                courierPharmacyBreakdown: _courierPharmacyBreakdown,
                loadingCourierBreakdown: _loadingCourierBreakdown,
                courierPharmacyBreakdownError: _courierPharmacyBreakdownError,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({
    required this.connected,
    required this.inBackground,
    required this.courierName,
    required this.onMenu,
    required this.onChanged,
  });

  final bool connected;
  final bool inBackground;
  final String courierName;
  final VoidCallback onMenu;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: .96),
    borderRadius: BorderRadius.circular(22),
    elevation: 5,
    shadowColor: Colors.black.withValues(alpha: .12),
    child: SizedBox(
      height: 66,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Abrir menú',
            onPressed: onMenu,
            icon: const Icon(Icons.menu_rounded),
          ),
          SizedBox(
            width: 82,
            height: 30,
            child: Image.asset(
              'assets/farmanorte-brand.png',
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              semanticLabel: 'farmanorte',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (connected && !inBackground) ...[
                      const _LiveDot(),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        inBackground
                            ? 'En segundo plano'
                            : connected
                            ? 'Conectado'
                            : 'Desconectado',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  inBackground
                      ? 'Avisos activos'
                      : connected
                      ? 'Pedidos activos'
                      : 'Actívate',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: connected,
            onChanged: onChanged,
            activeTrackColor: AppColors.primary,
            activeThumbColor: Colors.white,
          ),
          const SizedBox(width: 9),
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.mint,
            child: Text(
              _courierInitials(courierName),
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    ),
  );
}

class _HomeSheet extends StatelessWidget {
  const _HomeSheet({
    required this.connected,
    required this.baseLabel,
    required this.autoAccepting,
    required this.available,
    required this.active,
    required this.pendingApprovals,
    required this.onAutoAccept,
    required this.onAccept,
    required this.onDetail,
    required this.onChat,
    required this.earnings,
    required this.feeSummary,
    required this.loadingFeeSummary,
    required this.pendingEquivalentCount,
    required this.pendingEquivalentAmount,
    required this.courierPharmacyBreakdown,
    required this.loadingCourierBreakdown,
    required this.courierPharmacyBreakdownError,
  });

  final bool connected;
  final String baseLabel;
  final bool autoAccepting;
  final List<Delivery> available;
  final List<Delivery> active;
  final List<Delivery> pendingApprovals;
  final ValueChanged<bool> onAutoAccept;
  final ValueChanged<Delivery> onAccept;
  final ValueChanged<Delivery> onDetail;
  final ValueChanged<Delivery> onChat;
  final double earnings;
  final CourierFeeSummary? feeSummary;
  final bool loadingFeeSummary;
  final int pendingEquivalentCount;
  final double pendingEquivalentAmount;
  final List<CourierPharmacyBreakdown> courierPharmacyBreakdown;
  final bool loadingCourierBreakdown;
  final String? courierPharmacyBreakdownError;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.canvas,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
    elevation: 16,
    shadowColor: Colors.black.withValues(alpha: .2),
    clipBehavior: Clip.antiAlias,
    child: ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
      children: [
        Center(
          child: Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFFCAD5D9),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Resumen de tu conexión',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$baseLabel · Montería',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            _ConnectionBadge(connected: connected),
          ],
        ),
        const SizedBox(height: 16),
        if (!connected)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.muted,
                  size: 18,
                ),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Estás desconectado: los botones de aceptar están bloqueados.',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: autoAccepting ? AppColors.mint : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: autoAccepting
                  ? AppColors.primary.withValues(alpha: .18)
                  : AppColors.line,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: autoAccepting
                      ? AppColors.primary.withValues(alpha: .12)
                      : AppColors.canvas,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  autoAccepting
                      ? Icons.bolt_rounded
                      : Icons.notifications_none_rounded,
                  color: autoAccepting
                      ? AppColors.primaryDark
                      : AppColors.muted,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Autoaceptar pedidos del punto base',
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      !connected
                          ? 'Conéctate para activar la recepción automática.'
                          : autoAccepting
                          ? baseLabel.startsWith('Apoyo general')
                                ? 'Autoacepta domicilios de todas las zonas como apoyo general.'
                                : 'Solo autoacepta domicilios de $baseLabel; los demás se toman manualmente.'
                          : 'Desactivado. Actívalo solo si quieres priorizar tu punto base.',
                      maxLines: 2,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: autoAccepting,
                onChanged: connected ? onAutoAccept : null,
                activeTrackColor: AppColors.primary,
                activeThumbColor: Colors.white,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _QuickStat(
                value: '${available.length}',
                label: 'Disponibles',
                icon: Icons.inbox_rounded,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickStat(
                value: _money(earnings),
                label: 'Ganancias hoy',
                icon: Icons.account_balance_wallet_rounded,
                color: AppColors.violet,
              ),
            ),
          ],
        ),
        if (pendingEquivalentCount > 0) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E8),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: .3),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.draw_outlined, color: AppColors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Equivalentes pendientes por firmar',
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$pendingEquivalentCount servicio(s) · ${_money(pendingEquivalentAmount)} aún no suma a tus ganancias.',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 10.5,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cuota de esta semana',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      loadingFeeSummary
                          ? 'Calculando según tus turnos…'
                          : feeSummary == null
                          ? 'Disponible cuando el administrador publique los turnos.'
                          : '${feeSummary!.scheduledDays} días · ${feeSummary!.doubleShiftCount} dobles · pagado ${_money(feeSummary!.totalPaid)}',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                feeSummary == null ? '—' : _money(feeSummary!.balanceDue),
                style: const TextStyle(
                  color: AppColors.warning,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _CourierPharmacyBreakdownCard(
          breakdown: courierPharmacyBreakdown,
          loading: loadingCourierBreakdown,
          error: courierPharmacyBreakdownError,
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Pedidos disponibles',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              '${available.length} cerca de ti',
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (available.isEmpty)
          _Notice(
            icon: connected
                ? Icons.check_circle_outline_rounded
                : Icons.pause_circle_outline_rounded,
            title: connected ? 'Todo al día' : 'Conexión pausada',
            message: connected
                ? 'No hay nuevos domicilios disponibles en este momento.'
                : 'Activa tu conexión para comenzar a recibir domicilios.',
          )
        else
          ...available.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DeliveryListItem(
                delivery: item,
                onPressed: connected ? () => onAccept(item) : null,
              ),
            ),
          ),
        if (pendingApprovals.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text(
            'Esperando aprobación de farmacia',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'La solicitud vence en 5 minutos. Puedes seguir recibiendo otros domicilios.',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          ...pendingApprovals.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DeliveryListItem(
                delivery: item,
                compact: true,
                onPressed: () => onDetail(item),
                onChat: () => onChat(item),
              ),
            ),
          ),
        ],
        if (active.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'En curso',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          ...active.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DeliveryListItem(
                delivery: item,
                compact: true,
                onPressed: () => onDetail(item),
                onChat: () => onChat(item),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _CourierDeliveryHistorySheet extends StatelessWidget {
  const _CourierDeliveryHistorySheet({
    required this.deliveries,
    required this.equivalentStatuses,
  });

  final List<Delivery> deliveries;
  final Map<String, String> equivalentStatuses;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Historial de domicilios',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: 21,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Servicios terminados y novedades registrados desde Supabase.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: deliveries.isEmpty
                  ? const _Notice(
                      icon: Icons.history_toggle_off_rounded,
                      title: 'Todavía no hay domicilios terminados',
                      message: 'Cuando entregues un servicio aparecerá aquí.',
                    )
                  : ListView.separated(
                      itemCount: deliveries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final delivery = deliveries[index];
                        final status = equivalentStatuses[delivery.id];
                        final released =
                            status == 'signed' || status == 'acknowledged';
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DeliveryListItem(
                              delivery: delivery,
                              compact: true,
                              onPressed: () => Navigator.pop(context, delivery),
                            ),
                            if (!released)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  'Pendiente por firmar · no suma a tus ganancias',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: AppColors.warning,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: connected ? AppColors.mint : Colors.white,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: connected ? AppColors.primary : AppColors.muted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          connected ? 'Activo' : 'Pausado',
          style: TextStyle(
            color: connected ? AppColors.primaryDark : AppColors.muted,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _CourierPharmacyBreakdownCard extends StatelessWidget {
  const _CourierPharmacyBreakdownCard({
    required this.breakdown,
    required this.loading,
    required this.error,
  });

  final List<CourierPharmacyBreakdown> breakdown;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.pharmacyBlueSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.bar_chart_rounded,
                color: AppColors.pharmacyBlue,
              ),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Domicilios por farmacia',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Entregas realizadas · ganancias liberadas al firmar',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text(
                  'Actualizando desglose…',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        else if (error != null && error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No se pudo consultar el desglose: $error',
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 11,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        else if (breakdown.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Aún no tienes domicilios entregados para mostrar.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        else
          ...breakdown.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FN ${item.pharmacyCode}',
                          style: const TextStyle(
                            color: AppColors.ink,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '${item.serviceCount} entregado(s) · ${item.baseCount} base · ${item.supportCount} apoyo',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _money(item.totalEarnings),
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class _QuickStat extends StatelessWidget {
  const _QuickStat({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 10),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class DeliveryListItem extends StatelessWidget {
  const DeliveryListItem({
    required this.delivery,
    required this.onPressed,
    this.onChat,
    this.compact = false,
    super.key,
  });

  final Delivery delivery;
  final VoidCallback? onPressed;
  final VoidCallback? onChat;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final active = delivery.status != DeliveryStatus.offered;
    final overflow = delivery.kind == DeliveryKind.overflow;

    final card = Card(
      child: InkWell(
        onTap: active ? onPressed : null,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: EdgeInsets.all(compact ? 13 : 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // El consecutivo (FN167009) es lo que se dicta y se busca:
              // va primero y en azul; estado y tipo quedan debajo.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      delivery.id,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.primaryDark,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusPill(status: delivery.status),
                ],
              ),
              if (!active && delivery.expiresAt != null) ...[
                const SizedBox(height: 10),
                _OfferCountdown(delivery: delivery),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _TypePill(kind: delivery.kind, service: delivery.service),
                  if (delivery.status != DeliveryStatus.offered)
                    _AssignmentPill(support: delivery.assignedAsSupport),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: overflow
                          ? AppColors.warning.withValues(alpha: .13)
                          : AppColors.mint,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      delivery.kind.icon,
                      color: delivery.kind.color,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          delivery.storeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          delivery.storeAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _money(delivery.serviceFee),
                        style: const TextStyle(
                          color: AppColors.primaryDark,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Text(
                        'Tu pago',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _RoutePreview(delivery: delivery),
              const SizedBox(height: 13),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Meta(
                    icon: Icons.route_rounded,
                    label: '${delivery.distance.toStringAsFixed(1)} km',
                  ),
                  _Meta(
                    icon: Icons.schedule_rounded,
                    label: '${delivery.estimatedTime} min',
                  ),
                  _Meta(
                    icon: delivery.paymentMethod.icon,
                    label: delivery.paymentMethod.label,
                    color: delivery.paymentMethod.color,
                  ),
                  _Meta(
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Ganas ${_money(delivery.serviceFee)}',
                    color: AppColors.primaryDark,
                  ),
                  if (active)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onChat != null)
                          OutlinedButton.icon(
                            onPressed: onChat,
                            icon: const Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 16,
                            ),
                            label: const Text('Chat'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.blue,
                              side: BorderSide(
                                color: AppColors.blue.withValues(alpha: .28),
                              ),
                              backgroundColor: AppColors.pharmacyBlueSoft,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        const SizedBox(width: 10),
                        TextButton.icon(
                          onPressed: onPressed,
                          icon: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                          ),
                          label: const Text('Ver detalle'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.primaryDark,
                            padding: EdgeInsets.zero,
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              // Una sola acción grande por tarjeta, al alcance del pulgar
              // (botón principal del tema: 54 px, radio 17).
              if (!active) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onPressed,
                    child: Text(
                      overflow ? 'Tomar domicilio' : 'Aceptar domicilio',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    final live =
        !active &&
        delivery.expiresAt != null &&
        delivery.expiresAt!.isAfter(DateTime.now());
    return _LiveEntrance(child: live ? _LiveOfferFrame(child: card) : card);
  }
}

/// Punto verde que late mientras el domiciliario está conectado.
class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ping = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  Timer? _beat;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _beat?.cancel();
    if (MediaQuery.of(context).disableAnimations) return;
    _beat = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (mounted) _ping.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _beat?.cancel();
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ping,
    builder: (context, _) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: AppColors.success,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.success.withValues(alpha: .45 * (1 - _ping.value)),
            spreadRadius: 6 * _ping.value,
          ),
        ],
      ),
    ),
  );
}

/// Entrada suave de cada tarjeta la primera vez que aparece.
class _LiveEntrance extends StatelessWidget {
  const _LiveEntrance({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 14),
          child: child,
        ),
      ),
    );
  }
}

/// Oferta viva: el borde late en azul mientras el domicilio está publicado.
class _LiveOfferFrame extends StatefulWidget {
  const _LiveOfferFrame({required this.child});
  final Widget child;

  @override
  State<_LiveOfferFrame> createState() => _LiveOfferFrameState();
}

class _LiveOfferFrameState extends State<_LiveOfferFrame>
    with SingleTickerProviderStateMixin {
  // Un latido corto cada 1,8 s (no una animación infinita): así la interfaz
  // queda quieta entre latidos y respeta "reducir movimiento".
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _beat;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _beat?.cancel();
    if (MediaQuery.of(context).disableAnimations) return;
    _beat = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (mounted) _pulse.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _beat?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  double get _glow => math.sin(_pulse.value * math.pi);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    child: widget.child,
    builder: (context, child) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.primary, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: .06 + _glow * .14),
            blurRadius: 4 + _glow * 10,
            spreadRadius: _glow * 3,
          ),
        ],
      ),
      child: child,
    ),
  );
}

/// Anillo con el tiempo que queda: primero la reserva para la zona que pide,
/// luego el tiempo para el resto del recorrido y el apoyo.
class _OfferCountdown extends StatefulWidget {
  const _OfferCountdown({required this.delivery});
  final Delivery delivery;

  @override
  State<_OfferCountdown> createState() => _OfferCountdownState();
}

class _OfferCountdownState extends State<_OfferCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final priority = widget.delivery.priorityUntil?.toLocal();
    final expires = widget.delivery.expiresAt!.toLocal();
    final inPriority = priority != null && priority.isAfter(now);
    final end = inPriority ? priority : expires;
    final start = inPriority
        ? end.subtract(const Duration(minutes: 3))
        : (priority ?? end.subtract(const Duration(minutes: 5)));
    final remaining = end.difference(now);
    final total = end.difference(start).inMilliseconds;
    final expired = remaining.isNegative || remaining == Duration.zero;
    final fraction = expired || total <= 0
        ? 0.0
        : (remaining.inMilliseconds / total).clamp(0.0, 1.0);
    final minutes = expired ? 0 : remaining.inMinutes;
    final seconds = expired
        ? '00'
        : (remaining.inSeconds % 60).toString().padLeft(2, '0');
    final label = expired
        ? 'Oferta vencida'
        : inPriority
        ? 'Reservado para la zona que pide · $minutes:$seconds'
        : 'Abierto al recorrido y apoyo · $minutes:$seconds';
    return Row(
      children: [
        SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: 3.5,
            backgroundColor: AppColors.mint,
            color: expired ? AppColors.warning : AppColors.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: expired ? AppColors.muted : AppColors.primary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoutePreview extends StatelessWidget {
  const _RoutePreview({required this.delivery});
  final Delivery delivery;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Column(
        children: [
          const Icon(
            Icons.store_rounded,
            color: AppColors.primaryDark,
            size: 15,
          ),
          Container(width: 1.5, height: 17, color: AppColors.line),
          const Icon(
            Icons.location_on_rounded,
            color: AppColors.danger,
            size: 17,
          ),
        ],
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              delivery.storeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 15),
            Text(
              delivery.destination,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
      const Icon(Icons.more_horiz_rounded, color: AppColors.muted, size: 18),
    ],
  );
}

class DeliveryDetailScreen extends StatefulWidget {
  const DeliveryDetailScreen({
    required this.delivery,
    this.onChanged,
    super.key,
  });

  final Delivery delivery;
  final ValueChanged<Delivery>? onChanged;

  @override
  State<DeliveryDetailScreen> createState() => _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState extends State<DeliveryDetailScreen> {
  late Delivery _delivery;
  bool _savingStatus = false;

  @override
  void initState() {
    super.initState();
    _delivery = widget.delivery;
  }

  Future<void> _setStatus(DeliveryStatus status) async {
    if (_savingStatus || status == _delivery.status) return;
    setState(() => _savingStatus = true);
    try {
      if (_delivery.status == DeliveryStatus.offered &&
          status == DeliveryStatus.accepted &&
          SupabaseConfig.isConfigured) {
        final accepted = await OperationsBackend.instance.acceptDelivery(
          deliveryId: _delivery.id,
          asSupport: _delivery.assignedAsSupport,
        );
        if (!accepted) {
          throw StateError('El domicilio ya no está disponible para aceptar.');
        }
      } else {
        await OperationsBackend.instance.updateDeliveryStatus(
          deliveryId: _delivery.id,
          status: status,
        );
      }
      if (!mounted) return;
      final updated = _delivery.copyWith(status: status);
      setState(() => _delivery = updated);
      widget.onChanged?.call(updated);
    } catch (error) {
      if (!mounted) return;
      final detail = '$error'
          .replaceFirst('PostgrestException(message: ', '')
          .split(', code:')
          .first
          .replaceFirst('Exception: ', '')
          .trim();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('No se pudo actualizar: $detail')),
        );
    } finally {
      if (mounted) setState(() => _savingStatus = false);
    }
  }

  void _selectDestination(int index) {
    final options = _delivery.addressOptions;
    if (index < 0 || index >= options.length) return;
    final selected = options[index];
    final updated = _delivery.copyWith(
      destination: selected.label,
      destinationAddress: selected.address,
      destinationPoint: selected.point,
      selectedAddressIndex: index,
    );
    setState(() => _delivery = updated);
    widget.onChanged?.call(updated);
  }

  Future<void> _callClient() async {
    final opened = await _launchPhoneCall(_delivery.recipientPhone);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('No se pudo abrir la aplicación de teléfono.'),
          ),
        );
    }
  }

  Future<void> _askCashReceived() async {
    final controller = TextEditingController(
      text: _delivery.cashReceived?.round().toString() ?? '',
    );
    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Cuánto dinero te entregó el cliente?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            prefixText: '\$ ',
            labelText: 'Efectivo recibido',
            hintText: 'Ej. 50000',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(
                controller.text.replaceAll('.', '').replaceAll(',', '.'),
              );
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Calcular cambio'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null || !mounted) return;
    final updated = _delivery.copyWith(cashReceived: amount);
    setState(() => _delivery = updated);
    widget.onChanged?.call(updated);
  }

  Future<void> _openGoogleMaps({
    required String address,
    required LatLng fallback,
  }) async {
    final destination = _mapsDestination(address, fallback);
    final uri = Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': destination,
      'travelmode': 'driving',
    });
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('No se pudo abrir Google Maps en este dispositivo.'),
          ),
        );
    }
  }

  void _openPickupStop(DeliveryPickupStop stop) {
    _openGoogleMaps(address: stop.address, fallback: stop.point);
  }

  void _openChat() {
    if (!SupabaseConfig.isConfigured) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'El chat requiere la conexión real de Supabase; no se usan mensajes locales.',
            ),
          ),
        );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => FractionallySizedBox(
        heightFactor: .78,
        child: DeliveryChatSheet(deliveryId: _delivery.id),
      ),
    );
  }

  void _openEquivalent() {
    if (!SupabaseConfig.isConfigured) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'El equivalente requiere la conexión real de Supabase; no se generan soportes locales.',
            ),
          ),
        );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => FractionallySizedBox(
        heightFactor: .86,
        child: DeliveryEquivalentSheet(deliveryId: _delivery.id),
      ),
    );
  }

  String _mapsDestination(String address, LatLng fallback) {
    final cleanAddress = address.trim();
    final normalized = cleanAddress.toLowerCase();
    final addressIsMissing =
        cleanAddress.isEmpty ||
        normalized == 'dirección por confirmar' ||
        normalized == 'direccion por confirmar';

    if (addressIsMissing) {
      return '${fallback.latitude},${fallback.longitude}';
    }

    final includesMonteria =
        normalized.contains('montería') || normalized.contains('monteria');
    return includesMonteria
        ? cleanAddress
        : '$cleanAddress, Montería, Córdoba, Colombia';
  }

  String get _action => switch (_delivery.status) {
    DeliveryStatus.offered => 'Aceptar domicilio',
    DeliveryStatus.accepted => 'Recoger pedido e iniciar recorrido',
    DeliveryStatus.pickedUp => 'Confirmar entrega',
    DeliveryStatus.delivered => 'Domicilio completado',
    DeliveryStatus.notDelivered => 'Novedad registrada',
  };

  Future<void> _advance() async {
    switch (_delivery.status) {
      case DeliveryStatus.offered:
        await _setStatus(DeliveryStatus.accepted);
      case DeliveryStatus.accepted:
        await _setStatus(DeliveryStatus.pickedUp);
      case DeliveryStatus.pickedUp:
        await _setStatus(DeliveryStatus.delivered);
      case DeliveryStatus.delivered:
        Navigator.pop(context);
      case DeliveryStatus.notDelivered:
        Navigator.pop(context);
    }
  }

  Future<void> _report() async {
    final outcome = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reportar domicilio'),
        content: const Text(
          'Selecciona la novedad que ocurrió en el servicio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('Cerrar'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, 'customer_refused'),
            child: const Text('Cliente no recibió'),
          ),
        ],
      ),
    );
    if (outcome != 'customer_refused' || !mounted) return;
    await _setStatus(DeliveryStatus.notDelivered);
    if (!mounted || _delivery.status != DeliveryStatus.notDelivered) return;
    final updated = _delivery.copyWith(
      deliveryOutcome:
          'Cliente no recibió el pedido. La farmacia debe pagar \$5.000.',
    );
    setState(() => _delivery = updated);
    widget.onChanged?.call(updated);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Novedad registrada. Cobro a la farmacia: \$5.000.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  _RoundButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Volver',
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .95),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .1),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color:
                                    _delivery.status == DeliveryStatus.delivered
                                    ? AppColors.primary
                                    : AppColors.warning,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                _delivery.status == DeliveryStatus.delivered
                                    ? 'Domicilio completado'
                                    : _delivery.status ==
                                          DeliveryStatus.notDelivered
                                    ? 'Domicilio no entregado'
                                    : 'Pedido ${_delivery.id}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.ink,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _RoundButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    tooltip: 'Abrir chat',
                    onPressed: _openChat,
                  ),
                  const SizedBox(width: 8),
                  _RoundButton(
                    icon: Icons.flag_outlined,
                    tooltip: 'Reportar',
                    onPressed: _report,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          top: MediaQuery.paddingOf(context).top + 12 + 46,
          child: _DetailSheet(
            delivery: _delivery,
            action: _action,
            advancing: _savingStatus,
            onAdvance: _advance,
            onOrigin: () => _openGoogleMaps(
              address: _delivery.storeAddress,
              fallback: _delivery.origin,
            ),
            onDestination: () => _openGoogleMaps(
              address: _delivery.destinationAddress,
              fallback: _delivery.destinationPoint,
            ),
            onDestinationChanged: _selectDestination,
            onCallClient: _callClient,
            onCashReceived: _askCashReceived,
            onPickupStop: _openPickupStop,
            onChat: _openChat,
            onEquivalent: _openEquivalent,
          ),
        ),
      ],
    ),
  );
}

class DeliveryChatSheet extends StatefulWidget {
  const DeliveryChatSheet({required this.deliveryId, super.key});

  final String deliveryId;

  @override
  State<DeliveryChatSheet> createState() => _DeliveryChatSheetState();
}

class _DeliveryChatSheetState extends State<DeliveryChatSheet> {
  final _messageController = TextEditingController();
  StreamSubscription<List<DeliveryChatMessage>>? _chatSubscription;
  List<DeliveryChatMessage> _messages = const [];
  String? _error;
  bool _loading = true;
  bool _sending = false;
  bool _chatBaselineReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startChat());
  }

  Future<void> _startChat() async {
    final stream = await OperationsBackend.instance.watchDeliveryChat(
      deliveryId: widget.deliveryId,
    );
    if (!mounted) return;
    if (stream == null) {
      setState(() {
        _loading = false;
        _error = 'No se pudo conectar al chat real de este domicilio.';
      });
      return;
    }
    _chatSubscription = stream.listen(
      (messages) {
        if (!mounted) return;
        final existingIds = _messages.map((message) => message.id).toSet();
        final currentUserId = OperationsBackend.instance.currentUserId;
        final incoming = _chatBaselineReady
            ? messages.where(
                (message) =>
                    !existingIds.contains(message.id) &&
                    message.senderId != currentUserId,
              )
            : const <DeliveryChatMessage>[];
        _chatBaselineReady = true;
        setState(() {
          _messages = messages;
          _loading = false;
        });
        // Una sola alerta por mensaje aunque también llegue el push.
        final firstAlert = incoming
            .map(
              (message) =>
                  AppNotificationAudio.claimAlert('chat:${message.id}'),
            )
            .toList()
            .contains(true);
        if (firstAlert) {
          unawaited(AppNotificationAudio.playMessageAlert());
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudieron cargar los mensajes: $error';
        });
      },
    );
  }

  Future<void> _sendMessage() async {
    final body = _messageController.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final sent = await OperationsBackend.instance.sendDeliveryChat(
        deliveryId: widget.deliveryId,
        body: body,
      );
      if (!mounted) return;
      if (!_messages.any((message) => message.id == sent.id)) {
        setState(() => _messages = [..._messages, sent]);
      }
      _messageController.clear();
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo enviar: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _timeLabel(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _roleLabel(String role) => switch (role) {
    'pharmacy' => 'Farmacia',
    'courier' => 'Domiciliario',
    'admin' => 'Administrador',
    _ => 'Operador',
  };

  @override
  void dispose() {
    _chatSubscription?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = OperationsBackend.instance.currentUserId;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chat del domicilio',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Conversación guardada para ${widget.deliveryId}.',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                  ? const Center(
                      child: Text(
                        'Todavía no hay mensajes. Coordina aquí con la farmacia.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : ListView.separated(
                      reverse: false,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _messages.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        final own = message.senderId == currentUserId;
                        return Align(
                          alignment: own
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * .82,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: own ? AppColors.mint : AppColors.canvas,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(14),
                                  topRight: const Radius.circular(14),
                                  bottomLeft: Radius.circular(own ? 14 : 4),
                                  bottomRight: Radius.circular(own ? 4 : 14),
                                ),
                                border: Border.all(color: AppColors.line),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  11,
                                  9,
                                  11,
                                  9,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          message.senderName,
                                          style: const TextStyle(
                                            color: AppColors.ink,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const SizedBox(width: 7),
                                        Text(
                                          _roleLabel(message.senderRole),
                                          style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(width: 7),
                                        Text(
                                          _timeLabel(message.createdAt),
                                          style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 9,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      message.body,
                                      style: const TextStyle(
                                        color: AppColors.ink,
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 10),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    enabled: !_sending,
                    maxLength: 2000,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => unawaited(_sendMessage()),
                    decoration: const InputDecoration(
                      counterText: '',
                      labelText: 'Escribe un mensaje',
                      prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Enviar mensaje',
                  onPressed: _sending ? null : () => unawaited(_sendMessage()),
                  icon: _sending
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DeliveryEquivalentSheet extends StatefulWidget {
  const DeliveryEquivalentSheet({required this.deliveryId, super.key});

  final String deliveryId;

  @override
  State<DeliveryEquivalentSheet> createState() =>
      _DeliveryEquivalentSheetState();
}

class _DeliveryEquivalentSheetState extends State<DeliveryEquivalentSheet> {
  final _signaturePadController = SignatureController(
    penStrokeWidth: 2.6,
    penColor: AppColors.ink,
    exportBackgroundColor: Colors.white,
  );
  final _receiptKey = GlobalKey();
  DeliveryEquivalent? _equivalent;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEquivalent());
  }

  Future<void> _loadEquivalent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final equivalent = await OperationsBackend.instance
          .loadDeliveryEquivalent(deliveryId: widget.deliveryId);
      if (!mounted) return;
      setState(() {
        _equivalent = equivalent;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar el equivalente: $error';
      });
    }
  }

  Future<void> _signEquivalent() async {
    final equivalent = _equivalent;
    if (equivalent != null && _signatureWindowExpired(equivalent)) {
      if (mounted) {
        setState(
          () => _error =
              'Venció el plazo de seis días para firmar este equivalente.',
        );
      }
      return;
    }
    if (equivalent == null || _signaturePadController.isEmpty || _saving) {
      if (mounted && equivalent != null && _signaturePadController.isEmpty) {
        setState(
          () => _error = 'Dibuja tu firma en el recuadro antes de guardar.',
        );
      }
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final signatureBytes = await _signaturePadController.toPngBytes(
        width: 720,
        height: 220,
      );
      if (signatureBytes == null || signatureBytes.isEmpty) {
        throw StateError('No se pudo capturar la firma manuscrita.');
      }
      await OperationsBackend.instance.signDeliveryEquivalent(
        equivalentId: equivalent.id,
        signatureName: 'Firma manuscrita',
        signatureImage: 'data:image/png;base64,${base64Encode(signatureBytes)}',
      );
      await _loadEquivalent();
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo firmar: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _dateLabel(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year} · ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  bool _signatureWindowExpired(DeliveryEquivalent equivalent) =>
      DateTime.now().isAfter(equivalent.createdAt.add(const Duration(days: 6)));

  String _invoiceNumber(DeliveryEquivalent equivalent) {
    final raw =
        '${equivalent.metadata['public_code'] ?? equivalent.deliveryId}';
    return formatDeliveryPublicCode(raw);
  }

  String _concept(DeliveryEquivalent equivalent) {
    final service = equivalent.serviceLabel.toLowerCase();
    final description = equivalent.description.trim();
    final rawStops = equivalent.metadata['pickup_stops'];
    final crossRoutes = rawStops is List
        ? rawStops
              .whereType<Map>()
              .map((stop) {
                final origin =
                    stop['origin_pharmacy_code'] ??
                    stop['originPharmacyCode'] ??
                    stop['pharmacy_code'];
                final destination =
                    stop['destination_pharmacy_code'] ??
                    stop['destinationPharmacyCode'];
                if (origin == null || destination == null) return null;
                return '${formatPharmacyCodeLabel(origin)} a '
                    '${formatPharmacyCodeLabel(destination)}';
              })
              .whereType<String>()
              .toList()
        : const <String>[];
    if (service.contains('cruce') && crossRoutes.isNotEmpty) {
      final prefix = service.contains('compra')
          ? 'Se realiza domicilio con compra y cruce.'
          : 'Se realiza cruce de';
      final routeText = prefix == 'Se realiza cruce de'
          ? '$prefix ${crossRoutes.join(' · ')}.'
          : '$prefix Cruce de ${crossRoutes.join(' · ')}.';
      return routeText;
    }
    if (service.contains('compra') && service.contains('cruce')) {
      return 'Se hace domicilio con compra y cruce. $description'.trim();
    }
    if (service.contains('cruce')) {
      return 'Se hace domicilio con cruce. $description'.trim();
    }
    if (service.contains('compra')) {
      return 'Se hace compra externa. $description'.trim();
    }
    if (service.contains('domicilio')) {
      final payment = switch (equivalent.paymentMethod) {
        'cash' => 'efectivo',
        'card' || 'qr' => 'datáfono',
        _ => 'el método de pago registrado',
      };
      return 'Se hace domicilio con $payment.';
    }
    return description.isEmpty
        ? 'Servicio de mensajería registrado.'
        : description;
  }

  Future<void> _downloadPdf(DeliveryEquivalent equivalent) async {
    final logoData = await rootBundle.load('assets/jr-mensajeria-express.png');
    final logo = pw.MemoryImage(logoData.buffer.asUint8List());
    final invoiceNumber = _invoiceNumber(equivalent);
    final concept = _concept(equivalent);
    final signatureImageBytes = _signatureImageBytes(
      equivalent.courierSignatureImage,
    );
    final document = pw.Document();
    document.addPage(
      pw.Page(
        pageFormat: pdf.PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(22),
        build: (context) => pw.Container(
          padding: const pw.EdgeInsets.all(13),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: pdf.PdfColors.blueGrey400),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Image(logo, width: 75, height: 47, fit: pw.BoxFit.contain),
                  pw.SizedBox(width: 7),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'JR Mensajería Express',
                          style: pw.TextStyle(
                            fontSize: 9,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          '324 660 2056',
                          style: const pw.TextStyle(
                            fontSize: 7,
                            color: pdf.PdfColors.blueGrey700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  pw.Container(
                    padding: const pw.EdgeInsets.all(5),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: pdf.PdfColors.blueGrey300),
                    ),
                    child: pw.Column(
                      children: [
                        pw.Text(
                          'No.',
                          style: const pw.TextStyle(
                            fontSize: 6,
                            color: pdf.PdfColors.blueGrey600,
                          ),
                        ),
                        pw.Text(
                          invoiceNumber,
                          style: pw.TextStyle(
                            fontSize: 7,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.Divider(color: pdf.PdfColors.blueGrey200),
              pw.Row(
                children: [
                  pw.Expanded(
                    child: _pdfField('Fecha', _dateLabel(equivalent.createdAt)),
                  ),
                  pw.SizedBox(width: 12),
                  pw.Expanded(
                    child: _pdfField('Valor \$', _money(equivalent.amount)),
                  ),
                ],
              ),
              _pdfLine(
                'Recibo de',
                formatPharmacyDisplay(equivalent.pharmacyCode),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                'POR CONCEPTO DE',
                style: pw.TextStyle(
                  fontSize: 6,
                  color: pdf.PdfColors.blueGrey600,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                concept,
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 26),
              pw.Divider(color: pdf.PdfColors.blueGrey200),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        _pdfField(
                          'Firma',
                          equivalent.courierSignatureName ??
                              'Pendiente de firma',
                        ),
                        if (signatureImageBytes != null) ...[
                          pw.SizedBox(height: 4),
                          pw.Image(
                            pw.MemoryImage(signatureImageBytes),
                            width: 78,
                            height: 27,
                            fit: pw.BoxFit.contain,
                          ),
                        ],
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 12),
                  pw.Expanded(
                    child: _pdfField('Total \$', _money(equivalent.amount)),
                  ),
                ],
              ),
              pw.SizedBox(height: 9),
              pw.Text(
                equivalent.paymentStatus == 'paid'
                    ? 'Firmado y pago registrado.'
                    : equivalent.status == 'acknowledged'
                    ? 'Recibido por la farmacia.'
                    : equivalent.status == 'signed'
                    ? 'Firmado por el domiciliario.'
                    : 'Pendiente de firma del domiciliario.',
                style: const pw.TextStyle(
                  fontSize: 7,
                  color: pdf.PdfColors.blueGrey700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final bytes = await document.save();
    if (!mounted) return;
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'equivalente-${equivalent.id.substring(0, 8)}.pdf',
    );
  }

  pw.Widget _pdfField(String label, String value) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        label.toUpperCase(),
        style: const pw.TextStyle(
          fontSize: 6,
          color: pdf.PdfColors.blueGrey600,
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        value,
        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
      ),
    ],
  );

  pw.Widget _pdfLine(String label, String value) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(vertical: 7),
    decoration: const pw.BoxDecoration(
      border: pw.Border(
        bottom: pw.BorderSide(color: pdf.PdfColors.blueGrey200),
      ),
    ),
    child: pw.Row(
      children: [
        pw.SizedBox(
          width: 62,
          child: pw.Text(
            label,
            style: const pw.TextStyle(
              fontSize: 6,
              color: pdf.PdfColors.blueGrey600,
            ),
          ),
        ),
        pw.Expanded(
          child: pw.Text(
            value,
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ],
    ),
  );

  Uint8List? _signatureImageBytes(String? dataUrl) {
    if (dataUrl == null || dataUrl.isEmpty) return null;
    final separator = dataUrl.indexOf(',');
    if (separator < 0 || separator == dataUrl.length - 1) return null;
    try {
      return base64Decode(dataUrl.substring(separator + 1));
    } catch (_) {
      return null;
    }
  }

  Future<void> _downloadImage(DeliveryEquivalent equivalent) async {
    try {
      final renderObject = _receiptKey.currentContext?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        throw StateError(
          'El equivalente todavía no está listo para capturarse.',
        );
      }
      final image = await renderObject.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('No se pudo generar la imagen.');
      final bytes = byteData.buffer.asUint8List();
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'image/png',
              name: 'equivalente-${equivalent.id.substring(0, 8)}.png',
            ),
          ],
          text:
              'Equivalente ${_invoiceNumber(equivalent)} · JR Mensajería Express',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('No se pudo generar la imagen: $error')),
        );
    }
  }

  Widget _receiptField(String label, String value, {Color? valueColor}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 7,
              fontWeight: FontWeight.w900,
              letterSpacing: .35,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? AppColors.ink,
              fontSize: 9,
              height: 1.25,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      );

  Widget _receiptLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _signaturePadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final equivalent = _equivalent;
    final signatureExpired =
        equivalent != null && _signatureWindowExpired(equivalent);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Equivalente digital',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar equivalente',
                  onPressed: _loading ? null : _loadEquivalent,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const Text(
              'Soporte real del servicio, guardado en Supabase para ambas partes.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.danger),
                  ),
                ),
              )
            else if (equivalent == null)
              const Expanded(
                child: Center(
                  child: Text(
                    'El equivalente se habilitará cuando la entrega quede guardada como entregada.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  children: [
                    RepaintBoundary(
                      key: _receiptKey,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF9FB5C8)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Image.asset(
                                  'assets/jr-mensajeria-express.png',
                                  width: 76,
                                  height: 48,
                                  fit: BoxFit.contain,
                                ),
                                const SizedBox(width: 7),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'JR Mensajería Express',
                                        style: TextStyle(
                                          color: AppColors.ink,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      SizedBox(height: 3),
                                      Text(
                                        '324 660 2056',
                                        style: TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 8,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: AppColors.line),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    children: [
                                      const Text(
                                        'No.',
                                        style: TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 7,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        _invoiceNumber(equivalent),
                                        style: const TextStyle(
                                          color: AppColors.ink,
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: _receiptField(
                                    'Fecha',
                                    _dateLabel(equivalent.createdAt),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _receiptField(
                                    'Valor \$',
                                    _money(equivalent.amount),
                                    valueColor: AppColors.primaryDark,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 16),
                            _receiptLine(
                              'Recibo de',
                              formatPharmacyDisplay(equivalent.pharmacyCode),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'POR CONCEPTO DE',
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 7,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .4,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _concept(equivalent),
                              style: const TextStyle(
                                color: AppColors.ink,
                                fontSize: 10,
                                height: 1.3,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 25),
                            const Divider(height: 1),
                            const SizedBox(height: 9),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _receiptField(
                                        'Firma',
                                        equivalent.courierSignatureName ??
                                            'Pendiente de firma',
                                      ),
                                      if (_signatureImageBytes(
                                            equivalent.courierSignatureImage,
                                          )
                                          case final signatureBytes?) ...[
                                        const SizedBox(height: 5),
                                        Image.memory(
                                          signatureBytes,
                                          width: 105,
                                          height: 34,
                                          fit: BoxFit.contain,
                                          alignment: Alignment.centerLeft,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _receiptField(
                                    'Total \$',
                                    _money(equivalent.amount),
                                    valueColor: AppColors.primaryDark,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: equivalent.status == 'draft'
                            ? const Color(0xFFFFF8E8)
                            : AppColors.mint,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: equivalent.status == 'draft'
                              ? AppColors.warning.withValues(alpha: .3)
                              : AppColors.primary.withValues(alpha: .2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            equivalent.status == 'draft'
                                ? Icons.lock_clock_outlined
                                : Icons.verified_outlined,
                            color: equivalent.status == 'draft'
                                ? AppColors.warning
                                : AppColors.primaryDark,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              equivalent.paymentStatus == 'paid'
                                  ? 'Firmado y pago registrado. El soporte quedó liquidado.'
                                  : equivalent.status == 'draft'
                                  ? signatureExpired
                                        ? 'Venció el plazo de seis días para firmar. El soporte se conserva como pendiente.'
                                        : 'Pendiente por firmar. No se envía a la farmacia ni suma a tus ganancias. Puedes firmarlo hasta ${_dateLabel(equivalent.createdAt.add(const Duration(days: 6)))}.'
                                  : equivalent.status == 'acknowledged'
                                  ? 'Firmado y recibido por la farmacia.'
                                  : 'Firmado. Ya puede verlo la farmacia; el pago queda pendiente de liquidación.',
                              style: const TextStyle(
                                color: AppColors.ink,
                                fontSize: 11,
                                height: 1.3,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (equivalent.status == 'draft' && signatureExpired)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0EF),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Ya pasaron seis días desde la entrega. El sistema conserva el registro, pero ya no permite firmarlo.',
                          style: TextStyle(
                            color: AppColors.danger,
                            fontSize: 11,
                            height: 1.35,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    else if (equivalent.status == 'draft') ...[
                      const Text(
                        'Firma manuscrita',
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 128,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.line),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Signature(
                          controller: _signaturePadController,
                          backgroundColor: Colors.white,
                          placeholder: const Center(
                            child: Text(
                              'Firma aquí con el dedo',
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _saving
                              ? null
                              : () => setState(_signaturePadController.clear),
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Borrar firma'),
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _signEquivalent,
                          icon: _saving
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.draw_rounded),
                          label: Text(
                            _saving ? 'Guardando firma…' : 'Firmar equivalente',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _downloadPdf(equivalent),
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              label: const Text('Descargar PDF'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _downloadImage(equivalent),
                              icon: const Icon(Icons.image_outlined),
                              label: const Text('Descargar imagen'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailSheet extends StatelessWidget {
  const _DetailSheet({
    required this.delivery,
    required this.action,
    required this.advancing,
    required this.onAdvance,
    required this.onOrigin,
    required this.onDestination,
    required this.onDestinationChanged,
    required this.onCallClient,
    required this.onCashReceived,
    required this.onPickupStop,
    required this.onChat,
    required this.onEquivalent,
  });

  final Delivery delivery;
  final String action;
  final bool advancing;
  final VoidCallback onAdvance;
  final VoidCallback onOrigin;
  final VoidCallback onDestination;
  final ValueChanged<int> onDestinationChanged;
  final VoidCallback onCallClient;
  final VoidCallback onCashReceived;
  final ValueChanged<DeliveryPickupStop> onPickupStop;
  final VoidCallback onChat;
  final VoidCallback onEquivalent;

  @override
  Widget build(BuildContext context) {
    final done =
        delivery.status == DeliveryStatus.delivered ||
        delivery.status == DeliveryStatus.notDelivered;
    final addressOptions = delivery.addressOptions;
    final customerAddress = [
      delivery.destinationAddress,
      if (delivery.neighborhood.isNotEmpty) 'Barrio: ${delivery.neighborhood}',
      if (delivery.addressReference.isNotEmpty)
        'Referencia: ${delivery.addressReference}',
    ].join(' · ');
    final selectedAddressIndex =
        delivery.selectedAddressIndex < addressOptions.length
        ? delivery.selectedAddressIndex
        : 0;
    return Material(
      color: AppColors.canvas,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: .2),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        children: [
          Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFCAD5D9),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      children: [
                        _TypePill(
                          kind: delivery.kind,
                          service: delivery.service,
                        ),
                        _StatusPill(status: delivery.status),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Detalle del domicilio',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Actualiza cada paso desde aquí',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                delivery.id,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _Progress(status: delivery.status),
          const SizedBox(height: 16),
          Material(
            color: AppColors.pharmacyBlueSoft,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: onChat,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .82),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.chat_bubble_rounded,
                        color: AppColors.primaryDark,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chat con la farmacia',
                            style: TextStyle(
                              color: AppColors.primaryDark,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Coordina el servicio desde este domicilio',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: AppColors.primaryDark,
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DetailCard(
            title: 'Servicio solicitado',
            icon: delivery.service.hasDataphone
                ? Icons.point_of_sale_rounded
                : delivery.kind.icon,
            iconColor: delivery.kind.color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        delivery.service.label,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _money(delivery.serviceFee),
                          style: const TextStyle(
                            color: AppColors.primaryDark,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Text(
                          'Tu ganancia',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  delivery.productSummary,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (delivery.service.crossCount > 0)
                      _Meta(
                        icon: Icons.swap_horiz_rounded,
                        label: delivery.service.crossCount == 1
                            ? '1 cruce'
                            : '${delivery.service.crossCount} cruces',
                        color: AppColors.blue,
                      ),
                    if (delivery.service.purchaseCount > 0)
                      _Meta(
                        icon: Icons.shopping_cart_outlined,
                        label: delivery.service.purchaseCount == 1
                            ? '1 compra'
                            : '${delivery.service.purchaseCount} compras',
                        color: AppColors.violet,
                      ),
                    if (delivery.service.changeOfMoney)
                      const _Meta(
                        icon: Icons.currency_exchange_rounded,
                        label: 'Cambio de menudo',
                        color: AppColors.warning,
                      ),
                    if (delivery.service.hasDataphone)
                      const _Meta(
                        icon: Icons.point_of_sale_rounded,
                        label: 'Datáfono +\$1.000',
                        color: AppColors.primaryDark,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _DetailCard(
            title: 'Ruta del servicio',
            icon: Icons.route_rounded,
            child: Column(
              children: [
                _AddressRow(
                  icon: Icons.store_rounded,
                  color: AppColors.primaryDark,
                  eyebrow: 'RECOGER EN',
                  title: delivery.storeName,
                  address: delivery.storeAddress,
                  action: 'Ir a tienda',
                  onAction: onOrigin,
                ),
                if (delivery.pickupStops.length > 1) ...[
                  const SizedBox(height: 10),
                  for (final stop in delivery.pickupStops.skip(1))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: _PickupStopRow(
                        stop: stop,
                        onOpen: () => onPickupStop(stop),
                      ),
                    ),
                ],
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Container(
                    width: 1.5,
                    height: 20,
                    color: AppColors.line,
                  ),
                ),
                if (addressOptions.length > 1) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: selectedAddressIndex,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Dirección del cliente',
                      prefixIcon: Icon(Icons.swap_vert_rounded),
                    ),
                    items: [
                      for (
                        var index = 0;
                        index < addressOptions.length;
                        index++
                      )
                        DropdownMenuItem(
                          value: index,
                          child: Text(
                            addressOptions[index].label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) onDestinationChanged(value);
                    },
                  ),
                ],
                _AddressRow(
                  icon: Icons.location_on_rounded,
                  color: AppColors.danger,
                  eyebrow: 'ENTREGAR EN',
                  title: delivery.destination,
                  address: customerAddress,
                  action: 'Ir a destino',
                  onAction: onDestination,
                ),
                const SizedBox(height: 13),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onDestination,
                    icon: const Icon(Icons.navigation_rounded, size: 19),
                    label: const Text('Abrir destino en Google Maps'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primaryDark,
                      minimumSize: const Size.fromHeight(48),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth < 560
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: cardWidth,
                    child: _DetailCard(
                      title: 'Cobro',
                      icon: delivery.paymentMethod.icon,
                      iconColor: delivery.paymentMethod.color,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            delivery.paymentMethod.label,
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _money(delivery.amountToCollect),
                            style: TextStyle(
                              color: delivery.paymentMethod.color,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Total a cobrar',
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (delivery.cashExpected != null &&
                              delivery.cashExpected! > 0) ...[
                            const SizedBox(height: 5),
                            Text(
                              'Cliente paga con: ${_money(delivery.cashExpected!)}',
                              style: const TextStyle(
                                color: AppColors.warning,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            'Pedido: ${_money(delivery.paymentAmount)}',
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Domicilio: ${_money(delivery.serviceFee)}',
                            style: const TextStyle(
                              color: AppColors.primaryDark,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _paymentHelper(delivery.paymentMethod),
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 10.5,
                              height: 1.25,
                            ),
                          ),
                          if (delivery.paymentMethod == PaymentMethod.cash) ...[
                            const SizedBox(height: 8),
                            if (delivery.cashReceived != null)
                              Text(
                                _changeLabel(delivery.changeDue),
                                style: TextStyle(
                                  color: (delivery.changeDue ?? 0) >= 0
                                      ? AppColors.primaryDark
                                      : AppColors.danger,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            const SizedBox(height: 4),
                            OutlinedButton.icon(
                              onPressed: onCashReceived,
                              icon: const Icon(
                                Icons.calculate_outlined,
                                size: 15,
                              ),
                              label: Text(
                                delivery.cashReceived == null
                                    ? 'Calcular cambio'
                                    : 'Cambiar efectivo',
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(0, 34),
                                textStyle: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _DetailCard(
                      title: 'Cliente',
                      icon: Icons.person_outline_rounded,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  delivery.recipientName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.ink,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Llamar al cliente',
                                onPressed: onCallClient,
                                icon: const Icon(Icons.call_rounded, size: 18),
                                color: AppColors.primaryDark,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            delivery.recipientPhone,
                            style: const TextStyle(
                              color: AppColors.primaryDark,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            'Toca el teléfono para llamar',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          _DetailCard(
            title: 'Indicaciones',
            icon: Icons.sticky_note_2_outlined,
            child: Text(
              delivery.note,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (done)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: delivery.status == DeliveryStatus.delivered
                    ? AppColors.mint
                    : const Color(0xFFFFF0EF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    delivery.status == DeliveryStatus.delivered
                        ? Icons.check_circle_rounded
                        : Icons.warning_amber_rounded,
                    color: delivery.status == DeliveryStatus.delivered
                        ? AppColors.primaryDark
                        : AppColors.danger,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      delivery.status == DeliveryStatus.delivered
                          ? 'Entrega registrada correctamente.'
                          : delivery.deliveryOutcome ?? 'Novedad registrada.',
                      style: TextStyle(
                        color: delivery.status == DeliveryStatus.delivered
                            ? AppColors.primaryDark
                            : AppColors.danger,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            FilledButton.icon(
              onPressed: advancing ? null : onAdvance,
              icon: Icon(
                advancing
                    ? Icons.hourglass_top_rounded
                    : delivery.status == DeliveryStatus.accepted
                    ? Icons.inventory_2_outlined
                    : delivery.status == DeliveryStatus.pickedUp
                    ? Icons.check_rounded
                    : Icons.handshake_outlined,
              ),
              label: Text(advancing ? 'Guardando…' : action),
            ),
          if (done) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onEquivalent,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Ver y firmar equivalente'),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Center(
            child: Text(
              '${delivery.distance.toStringAsFixed(1)} km · ${delivery.estimatedTime} min estimados',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.status});
  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final current = status.index;
    const steps = <(IconData, String)>[
      (Icons.touch_app_rounded, 'Aceptado'),
      (Icons.route_rounded, 'En recorrido'),
      (Icons.home_rounded, 'Entregado'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 15, 14, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            Expanded(
              child: Column(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: current >= i + 1
                          ? AppColors.primary
                          : AppColors.canvas,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      steps[i].$1,
                      size: 17,
                      color: current >= i + 1 ? Colors.white : AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    steps[i].$2,
                    style: TextStyle(
                      color: current >= i + 1
                          ? AppColors.primaryDark
                          : AppColors.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (i < steps.length - 1)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 23),
                  color: current > i ? AppColors.primary : AppColors.line,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _PickupStopRow extends StatelessWidget {
  const _PickupStopRow({required this.stop, required this.onOpen});

  final DeliveryPickupStop stop;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 9, 7, 9),
    decoration: BoxDecoration(
      color: AppColors.canvas,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.line),
    ),
    child: Row(
      children: [
        const Icon(Icons.swap_horiz_rounded, color: AppColors.blue, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stop.label,
                style: const TextStyle(
                  color: AppColors.blue,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                stop.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                stop.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onOpen,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            minimumSize: const Size(0, 36),
            textStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
          child: const Text('Abrir'),
        ),
      ],
    ),
  );
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.icon,
    required this.color,
    required this.eyebrow,
    required this.title,
    required this.address,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final Color color;
  final String eyebrow;
  final String title;
  final String address;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 27,
        height: 27,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 15),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: .6,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              address,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      TextButton(
        onPressed: onAction,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryDark,
          padding: const EdgeInsets.only(left: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w900,
          ),
        ),
        child: Text(action),
      ),
    ],
  );
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.title,
    required this.icon,
    required this.child,
    this.iconColor = AppColors.primaryDark,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 17),
              const SizedBox(width: 7),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

enum _LocationState {
  idle,
  searching,
  active,
  serviceDisabled,
  permissionDenied,
  permissionPermanentlyDenied,
  unavailable,
}

class CourierMap extends StatefulWidget {
  const CourierMap({
    required this.delivery,
    required this.showCurrentLocation,
    required this.showHomeStops,
    super.key,
  });

  final Delivery? delivery;
  final bool showCurrentLocation;
  final bool showHomeStops;

  @override
  State<CourierMap> createState() => _CourierMapState();
}

class _CourierMapState extends State<CourierMap> {
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionSubscription;
  Position? _currentPosition;
  _LocationState _locationState = _LocationState.idle;
  bool _hasCenteredOnLocation = false;
  bool _openingSettings = false;

  bool get _hasLocationPermission =>
      _locationState == _LocationState.active && _currentPosition != null;

  @override
  void initState() {
    super.initState();
    if (widget.showCurrentLocation) {
      unawaited(_startLocationTracking());
    }
  }

  @override
  void didUpdateWidget(covariant CourierMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delivery?.id != widget.delivery?.id &&
        widget.delivery != null &&
        MapsConfig.hasApiKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusDelivery());
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _startLocationTracking() async {
    if (!widget.showCurrentLocation) return;
    if (mounted) {
      setState(() => _locationState = _LocationState.searching);
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setLocationState(_LocationState.serviceDisabled);
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!mounted) return;

      if (permission == LocationPermission.denied) {
        _setLocationState(_LocationState.permissionDenied);
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _setLocationState(_LocationState.permissionPermanentlyDenied);
        return;
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        _setLocationState(_LocationState.permissionDenied);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );
      _updatePosition(position);

      await _positionSubscription?.cancel();
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen(
            _updatePosition,
            onError: (_) {
              if (_currentPosition == null) {
                _setLocationState(_LocationState.unavailable);
              }
            },
          );
    } catch (_) {
      // En pruebas sin un dispositivo real y ante errores del proveedor,
      // mantenemos la vista usable y mostramos un estado comprensible.
      _setLocationState(_LocationState.unavailable);
    }
  }

  void _setLocationState(_LocationState state) {
    if (!mounted) return;
    setState(() => _locationState = state);
  }

  void _updatePosition(Position position) {
    if (!mounted) return;
    setState(() {
      _currentPosition = position;
      _locationState = _LocationState.active;
    });
    if (!_hasCenteredOnLocation) {
      _hasCenteredOnLocation = true;
      unawaited(_focusPosition(position));
    }
    unawaited(
      OperationsBackend.instance.publishCourierLocation(
        courierId: OperationsBackend.courierId,
        position: position,
      ),
    );
  }

  LatLng? get _currentLatLng {
    final position = _currentPosition;
    if (position == null) return null;
    return LatLng(position.latitude, position.longitude);
  }

  Future<void> _focusPosition(Position position, {double zoom = 16}) async {
    final controller = _mapController;
    if (controller == null) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: zoom,
          ),
        ),
      );
    } catch (_) {
      // El mapa puede seguir inicializándose cuando llega la primera posición.
    }
  }

  Future<void> _focusDelivery() async {
    final item = widget.delivery;
    final controller = _mapController;
    if (item == null || controller == null) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              item.origin.latitude < item.destinationPoint.latitude
                  ? item.origin.latitude
                  : item.destinationPoint.latitude,
              item.origin.longitude < item.destinationPoint.longitude
                  ? item.origin.longitude
                  : item.destinationPoint.longitude,
            ),
            northeast: LatLng(
              item.origin.latitude > item.destinationPoint.latitude
                  ? item.origin.latitude
                  : item.destinationPoint.latitude,
              item.origin.longitude > item.destinationPoint.longitude
                  ? item.origin.longitude
                  : item.destinationPoint.longitude,
            ),
          ),
          72,
        ),
      );
    } catch (_) {
      // La cámara se podrá mover manualmente aunque todavía no haya tamaño.
    }
  }

  Future<void> _focusCurrentLocation() async {
    final position = _currentPosition;
    if (position == null) {
      await _startLocationTracking();
      return;
    }
    _hasCenteredOnLocation = true;
    await _focusPosition(position);
  }

  Future<void> _handleLocationAction() async {
    if (_locationState == _LocationState.permissionPermanentlyDenied) {
      if (_openingSettings) return;
      _openingSettings = true;
      try {
        await Geolocator.openAppSettings();
      } catch (_) {
        // El usuario todavía puede revisar los permisos desde Ajustes.
      } finally {
        _openingSettings = false;
      }
      return;
    }
    if (_locationState == _LocationState.serviceDisabled) {
      try {
        await Geolocator.openLocationSettings();
      } catch (_) {
        // El botón de reintento seguirá disponible si el sistema no abre Ajustes.
      }
      return;
    }
    await _startLocationTracking();
  }

  Future<void> _zoomIn() async {
    try {
      await _mapController?.animateCamera(CameraUpdate.zoomIn());
    } catch (_) {}
  }

  Future<void> _zoomOut() async {
    try {
      await _mapController?.animateCamera(CameraUpdate.zoomOut());
    } catch (_) {}
  }

  Set<Marker> _markers() {
    final markers = <Marker>{};
    if (widget.showCurrentLocation) {
      markers.add(
        Marker(
          markerId: const MarkerId('current'),
          position: _currentLatLng ?? const LatLng(8.7582, -75.8853),
          infoWindow: const InfoWindow(title: 'Tu ubicación'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }
    if (widget.showHomeStops) {
      for (var i = 0; i < demoDeliveries.length; i++) {
        final item = demoDeliveries[i];
        markers.add(
          Marker(
            markerId: MarkerId('store-$i'),
            position: item.origin,
            infoWindow: InfoWindow(title: item.storeName),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              item.kind == DeliveryKind.overflow
                  ? BitmapDescriptor.hueOrange
                  : BitmapDescriptor.hueGreen,
            ),
          ),
        );
      }
    }
    final item = widget.delivery;
    if (item != null) {
      markers
        ..add(
          Marker(
            markerId: const MarkerId('origin'),
            position: item.origin,
            infoWindow: InfoWindow(title: item.storeName),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
          ),
        )
        ..add(
          Marker(
            markerId: const MarkerId('destination'),
            position: item.destinationPoint,
            infoWindow: InfoWindow(title: item.destination),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
          ),
        );
    }
    return markers;
  }

  Set<Polyline> _polylines() {
    final item = widget.delivery;
    if (item == null) return {};
    final middle = LatLng(
      (item.origin.latitude + item.destinationPoint.latitude) / 2 + .001,
      (item.origin.longitude + item.destinationPoint.longitude) / 2,
    );
    return {
      Polyline(
        polylineId: const PolylineId('delivery-route'),
        color: AppColors.primary,
        width: 5,
        jointType: JointType.round,
        points: [item.origin, middle, item.destinationPoint],
      ),
    };
  }

  String get _locationLabel => switch (_locationState) {
    _LocationState.idle => 'Preparando ubicación',
    _LocationState.searching => 'Buscando tu ubicación…',
    _LocationState.active =>
      MapsConfig.hasApiKey
          ? 'Ubicación en tiempo real'
          : 'Ubicación activa · mapa de respaldo',
    _LocationState.serviceDisabled => 'Activa la ubicación del teléfono',
    _LocationState.permissionDenied => 'Permitir ubicación para continuar',
    _LocationState.permissionPermanentlyDenied =>
      'Permite ubicación en Ajustes',
    _LocationState.unavailable => 'Ubicación no disponible · reintentar',
  };

  Color get _locationColor => switch (_locationState) {
    _LocationState.active => AppColors.blue,
    _LocationState.searching => AppColors.primaryDark,
    _LocationState.idle => AppColors.muted,
    _LocationState.serviceDisabled ||
    _LocationState.permissionDenied ||
    _LocationState.permissionPermanentlyDenied ||
    _LocationState.unavailable => AppColors.warning,
  };

  IconData get _locationIcon => switch (_locationState) {
    _LocationState.active => Icons.my_location_rounded,
    _LocationState.searching => Icons.gps_fixed_rounded,
    _LocationState.idle => Icons.gps_not_fixed_rounded,
    _LocationState.serviceDisabled => Icons.location_disabled_rounded,
    _LocationState.permissionDenied ||
    _LocationState.permissionPermanentlyDenied => Icons.lock_outline_rounded,
    _LocationState.unavailable => Icons.gps_off_rounded,
  };

  Widget _statusPill() => Positioned(
    left: 16,
    top: 94,
    right: 72,
    child: Align(
      alignment: Alignment.centerLeft,
      child: _MapStatusPill(
        label: _locationLabel,
        icon: _locationIcon,
        color: _locationColor,
        onPressed: _handleLocationAction,
      ),
    ),
  );

  List<Widget> _mapControls() => [
    Positioned(
      right: 16,
      top: 100,
      child: _FloatingButton(
        icon: Icons.my_location_rounded,
        onPressed: _focusCurrentLocation,
      ),
    ),
    Positioned(
      right: 16,
      top: 158,
      child: Column(
        children: [
          _MapButton(icon: Icons.add_rounded, onPressed: _zoomIn),
          const SizedBox(height: 1),
          _MapButton(icon: Icons.remove_rounded, onPressed: _zoomOut),
        ],
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (MapsConfig.hasApiKey) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: widget.delivery?.origin ?? MapsConfig.monteria,
                zoom: 13.8,
              ),
              onMapCreated: (controller) {
                _mapController = controller;
                final position = _currentPosition;
                if (position != null && !_hasCenteredOnLocation) {
                  _hasCenteredOnLocation = true;
                  unawaited(_focusPosition(position));
                }
              },
              markers: _markers(),
              polylines: _polylines(),
              myLocationEnabled: _hasLocationPermission,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: true,
              buildingsEnabled: true,
              rotateGesturesEnabled: true,
              scrollGesturesEnabled: true,
              tiltGesturesEnabled: true,
              zoomGesturesEnabled: true,
              padding: const EdgeInsets.only(bottom: 80),
            ),
          ),
          _statusPill(),
          ..._mapControls(),
        ],
      );
    }
    return _StyledMap(
      delivery: widget.delivery,
      showCurrentLocation: widget.showCurrentLocation,
      showHomeStops: widget.showHomeStops,
      currentLocation: _currentLatLng,
      locationLabel: _locationLabel,
      locationColor: _locationColor,
      onLocationAction: _handleLocationAction,
      onLocate: _focusCurrentLocation,
    );
  }
}

class _StyledMap extends StatefulWidget {
  const _StyledMap({
    required this.delivery,
    required this.showCurrentLocation,
    required this.showHomeStops,
    required this.currentLocation,
    required this.locationLabel,
    required this.locationColor,
    required this.onLocationAction,
    required this.onLocate,
  });

  final Delivery? delivery;
  final bool showCurrentLocation;
  final bool showHomeStops;
  final LatLng? currentLocation;
  final String locationLabel;
  final Color locationColor;
  final VoidCallback onLocationAction;
  final VoidCallback onLocate;

  @override
  State<_StyledMap> createState() => _StyledMapState();
}

class _StyledMapState extends State<_StyledMap> {
  late final TransformationController _transformationController;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  Offset _projectPoint(LatLng point, Size size) {
    const minLatitude = 8.70;
    const maxLatitude = 8.82;
    const minLongitude = -75.94;
    const maxLongitude = -75.83;
    final x = ((point.longitude - minLongitude) / (maxLongitude - minLongitude))
        .clamp(.08, .86)
        .toDouble();
    final y = (1 - (point.latitude - minLatitude) / (maxLatitude - minLatitude))
        .clamp(.08, .90)
        .toDouble();
    return Offset(size.width * x, size.height * y);
  }

  void _scaleBy(double factor) {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final nextScale = (currentScale * factor).clamp(1.0, 4.0).toDouble();
    final matrix = _transformationController.value.clone();
    final ratio = nextScale / currentScale;
    matrix.scaleByDouble(ratio, ratio, ratio, 1.0);
    _transformationController.value = matrix;
  }

  void _resetToCurrentLocation() {
    _transformationController.value = Matrix4.identity();
    widget.onLocate();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final origin = Offset(size.width * .38, size.height * .38);
      final destination = Offset(size.width * .71, size.height * .58);
      final current = _projectPoint(
        widget.currentLocation ?? const LatLng(8.7582, -75.8853),
        size,
      );
      final mapLayer = Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CityMapPainter(
                delivery: widget.delivery,
                showHomeStops: widget.showHomeStops,
                currentLocation: widget.currentLocation,
              ),
            ),
          ),
          if (widget.showHomeStops) ...[
            _MapPin(
              position: Offset(size.width * .24, size.height * .31),
              label: '155',
              color: AppColors.primaryDark,
            ),
            _MapPin(
              position: Offset(size.width * .61, size.height * .27),
              label: '183',
              color: AppColors.primaryDark,
            ),
            _MapPin(
              position: Offset(size.width * .27, size.height * .64),
              label: '232',
              color: AppColors.warning,
            ),
            _MapPin(
              position: Offset(size.width * .76, size.height * .70),
              label: '219',
              color: AppColors.primaryDark,
            ),
          ],
          if (widget.delivery != null) ...[
            _MapPin(
              position: origin,
              label: 'Recogida',
              color: AppColors.primaryDark,
              icon: Icons.store_rounded,
            ),
            _MapPin(
              position: destination,
              label: 'Entrega',
              color: AppColors.danger,
              icon: Icons.location_on_rounded,
            ),
          ],
          if (widget.showCurrentLocation) _CurrentLocation(position: current),
        ],
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transformationController,
              minScale: 1,
              maxScale: 4,
              panEnabled: true,
              scaleEnabled: true,
              boundaryMargin: const EdgeInsets.all(160),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: mapLayer,
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 94,
            right: 72,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _MapStatusPill(
                label: widget.locationLabel,
                icon: Icons.layers_outlined,
                color: widget.locationColor,
                onPressed: widget.onLocationAction,
              ),
            ),
          ),
          Positioned(
            right: 16,
            top: 100,
            child: _FloatingButton(
              icon: Icons.my_location_rounded,
              onPressed: _resetToCurrentLocation,
            ),
          ),
          Positioned(
            right: 16,
            top: 158,
            child: Column(
              children: [
                _MapButton(
                  icon: Icons.add_rounded,
                  onPressed: () => _scaleBy(1.25),
                ),
                const SizedBox(height: 1),
                _MapButton(
                  icon: Icons.remove_rounded,
                  onPressed: () => _scaleBy(.8),
                ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            bottom: widget.delivery == null ? 220 : 280,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .93),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .09),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_outlined, size: 15, color: AppColors.muted),
                  SizedBox(width: 6),
                  Text(
                    'Mapa de zona',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _CityMapPainter extends CustomPainter {
  const _CityMapPainter({
    required this.delivery,
    required this.showHomeStops,
    required this.currentLocation,
  });

  final Delivery? delivery;
  final bool showHomeStops;
  final LatLng? currentLocation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFEAF0F2),
    );
    final water = Paint()..color = const Color(0xFFD6EEF0);
    final waterPath = Path()
      ..moveTo(size.width * .84, 0)
      ..cubicTo(
        size.width * .72,
        size.height * .18,
        size.width * .94,
        size.height * .30,
        size.width * .80,
        size.height * .47,
      )
      ..cubicTo(
        size.width * .69,
        size.height * .64,
        size.width * .91,
        size.height * .78,
        size.width * .78,
        size.height,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(waterPath, water);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .02,
          size.height * .50,
          size.width * .19,
          size.height * .26,
        ),
        const Radius.circular(22),
      ),
      Paint()..color = const Color(0xFFDDEEDC),
    );

    final broad = Paint()
      ..color = Colors.white.withValues(alpha: .94)
      ..strokeWidth = 23
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final slim = Paint()
      ..color = const Color(0xFFD5DEE2)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final roads = <List<Offset>>[
      [
        Offset(-30, size.height * .19),
        Offset(size.width * .25, size.height * .31),
        Offset(size.width * .55, size.height * .25),
        Offset(size.width + 30, size.height * .38),
      ],
      [
        Offset(-30, size.height * .43),
        Offset(size.width * .28, size.height * .49),
        Offset(size.width * .62, size.height * .44),
        Offset(size.width + 30, size.height * .55),
      ],
      [
        Offset(-30, size.height * .70),
        Offset(size.width * .25, size.height * .63),
        Offset(size.width * .54, size.height * .73),
        Offset(size.width + 30, size.height * .67),
      ],
      [
        Offset(size.width * .19, -20),
        Offset(size.width * .30, size.height * .34),
        Offset(size.width * .23, size.height * .67),
        Offset(size.width * .33, size.height + 20),
      ],
      [
        Offset(size.width * .48, -20),
        Offset(size.width * .43, size.height * .29),
        Offset(size.width * .59, size.height * .61),
        Offset(size.width * .53, size.height + 20),
      ],
      [
        Offset(size.width * .72, -20),
        Offset(size.width * .64, size.height * .28),
        Offset(size.width * .78, size.height * .57),
        Offset(size.width * .69, size.height + 20),
      ],
    ];
    for (final road in roads) {
      final broadPath = Path()..moveTo(road.first.dx, road.first.dy);
      final slimPath = Path()..moveTo(road.first.dx, road.first.dy);
      for (var i = 1; i < road.length; i++) {
        broadPath.lineTo(road[i].dx, road[i].dy);
        slimPath.lineTo(road[i].dx, road[i].dy);
      }
      canvas.drawPath(broadPath, broad);
      canvas.drawPath(slimPath, slim);
    }

    final minor = Paint()
      ..color = const Color(0xFFDCE4E7)
      ..strokeWidth = 1;
    for (var i = 0; i < 11; i++) {
      final y = size.height * (.06 + i * .083);
      canvas.drawLine(
        Offset(size.width * .02, y),
        Offset(size.width * .83, y + size.height * .06),
        minor,
      );
    }
    for (var i = 0; i < 9; i++) {
      final x = size.width * (.06 + i * .10);
      canvas.drawLine(
        Offset(x, size.height * .06),
        Offset(x + size.width * .12, size.height * .86),
        minor,
      );
    }

    if (delivery != null) {
      final route = Paint()
        ..color = AppColors.primary
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()
        ..moveTo(size.width * .38, size.height * .38)
        ..quadraticBezierTo(
          size.width * .53,
          size.height * .45,
          size.width * .71,
          size.height * .58,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: .7)
          ..strokeWidth = 9
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawPath(path, route);
    }

    _label(
      canvas,
      'MONTERÍA',
      Offset(size.width * .09, size.height * .11),
      11,
      const Color(0xFF89969C),
    );
    _label(
      canvas,
      'Centro',
      Offset(size.width * .38, size.height * .18),
      10,
      const Color(0xFF87949B),
    );
    _label(
      canvas,
      'La Castellana',
      Offset(size.width * .47, size.height * .79),
      10,
      const Color(0xFF87949B),
    );
    _label(
      canvas,
      'Río Sinú',
      Offset(size.width * .82, size.height * .28),
      10,
      const Color(0xFF7BA9AD),
    );
    _label(
      canvas,
      'Parque',
      Offset(size.width * .04, size.height * .58),
      9,
      const Color(0xFF77A078),
    );
    _label(
      canvas,
      showHomeStops ? 'ZONA ASIGNADA' : 'RUTA ACTIVA',
      Offset(size.width * .08, size.height * .88),
      9,
      showHomeStops ? AppColors.primaryDark : AppColors.blue,
    );
  }

  void _label(
    Canvas canvas,
    String text,
    Offset offset,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.w800,
          letterSpacing: .3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CityMapPainter oldDelegate) =>
      oldDelegate.delivery?.id != delivery?.id ||
      oldDelegate.delivery?.status != delivery?.status ||
      oldDelegate.showHomeStops != showHomeStops ||
      oldDelegate.currentLocation?.latitude != currentLocation?.latitude ||
      oldDelegate.currentLocation?.longitude != currentLocation?.longitude;
}

class _MapPin extends StatelessWidget {
  const _MapPin({
    required this.position,
    required this.label,
    required this.color,
    this.icon = Icons.local_pharmacy_rounded,
  });

  final Offset position;
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Positioned(
    left: position.dx - 18,
    top: position.dy - 18,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .18),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 14),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CurrentLocation extends StatelessWidget {
  const _CurrentLocation({required this.position});
  final Offset position;

  @override
  Widget build(BuildContext context) => Positioned(
    left: position.dx - 20,
    top: position.dy - 20,
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.blue.withValues(alpha: .16),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            color: AppColors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: AppColors.blue.withValues(alpha: .45),
                blurRadius: 10,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MapStatusPill extends StatelessWidget {
  const _MapStatusPill({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: .95),
    borderRadius: BorderRadius.circular(15),
    elevation: 4,
    shadowColor: Colors.black.withValues(alpha: .14),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: .95),
    borderRadius: BorderRadius.circular(12),
    elevation: 3,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(icon, color: AppColors.ink, size: 20),
      ),
    ),
  );
}

class _FloatingButton extends StatelessWidget {
  const _FloatingButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.primary,
    borderRadius: BorderRadius.circular(16),
    elevation: 5,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 50,
        height: 50,
        child: Icon(icon, color: Colors.white, size: 21),
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: .95),
    borderRadius: BorderRadius.circular(15),
    elevation: 5,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(15),
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, color: AppColors.ink, size: 21),
        ),
      ),
    ),
  );
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.kind, this.service});

  final DeliveryKind kind;
  final DeliveryServicePlan? service;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: kind.color.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(kind.icon, color: kind.color, size: 13),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            service?.label ?? kind.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kind.color,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  );
}

class _AssignmentPill extends StatelessWidget {
  const _AssignmentPill({required this.support});

  final bool support;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: support
          ? AppColors.violet.withValues(alpha: .11)
          : AppColors.primary.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      support ? 'Apoyo' : 'Base',
      style: TextStyle(
        color: support ? AppColors.violet : AppColors.primaryDark,
        fontSize: 10,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    // Azul en curso, verde entregado, rojo no entregado (skill farmanorte).
    final color = switch (status) {
      DeliveryStatus.delivered => AppColors.success,
      DeliveryStatus.notDelivered => AppColors.danger,
      DeliveryStatus.offered => AppColors.primary,
      _ => AppColors.primaryDark,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: status == DeliveryStatus.delivered
            ? AppColors.successSoft
            : color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({
    required this.icon,
    required this.label,
    this.color = AppColors.muted,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 14),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: AppColors.line),
    ),
    child: Row(
      children: [
        Icon(icon, color: AppColors.primaryDark, size: 25),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                message,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String _money(double value) {
  final text = value.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write('.');
    buffer.write(text[i]);
  }
  return '\$${buffer.toString()}';
}

String _paymentHelper(PaymentMethod method) => switch (method) {
  PaymentMethod.cash => 'Cobrar al entregar',
  PaymentMethod.card => 'Pago con tarjeta',
  PaymentMethod.qr => 'Validar código QR',
};

String _changeLabel(double? change) {
  final amount = change ?? 0;
  return amount >= 0
      ? 'Devuelve: ${_money(amount)}'
      : 'Falta: ${_money(amount.abs())}';
}

Future<bool> _launchPhoneCall(String phone) {
  final normalized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (normalized.isEmpty) return Future.value(false);
  return launchUrl(
    Uri(scheme: 'tel', path: normalized),
    mode: LaunchMode.externalApplication,
  );
}
