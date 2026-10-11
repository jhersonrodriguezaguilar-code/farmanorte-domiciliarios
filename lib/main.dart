import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FarmaNorteApp());
}

class AppColors {
  AppColors._();
  static const primary = Color(0xFF00BFA6);
  static const primaryDark = Color(0xFF008F7A);
  static const mint = Color(0xFFE6FBF7);
  static const ink = Color(0xFF14212B);
  static const muted = Color(0xFF6D7B86);
  static const canvas = Color(0xFFF5F8FA);
  static const line = Color(0xFFE3EAED);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFE55353);
  static const blue = Color(0xFF3D7FF2);
  static const violet = Color(0xFF7657D7);
}

class MapsConfig {
  MapsConfig._();
  static const apiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  static const hasApiKey =
      apiKey != '' && apiKey != 'REPLACE_WITH_GOOGLE_MAPS_API_KEY';
  static const monteria = LatLng(8.7575, -75.8857);
}

const farmanorteSupportName = 'Andrés Vargas';
const farmanorteSupportPhone = '3045530618';
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

class FirebaseConfig {
  FirebaseConfig._();

  // Se completan mediante --dart-define para no guardar credenciales de un
  // proyecto concreto dentro del código fuente de la aplicación.
  static const commonApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const commonAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const androidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  static const iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const databaseUrl = String.fromEnvironment('FIREBASE_DATABASE_URL');

  static String get apiKey => defaultTargetPlatform == TargetPlatform.iOS
      ? (iosApiKey.isEmpty ? commonApiKey : iosApiKey)
      : (androidApiKey.isEmpty ? commonApiKey : androidApiKey);

  static String get appId => defaultTargetPlatform == TargetPlatform.iOS
      ? (iosAppId.isEmpty ? commonAppId : iosAppId)
      : (androidAppId.isEmpty ? commonAppId : androidAppId);

  static bool get isConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty &&
      databaseUrl.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
    databaseURL: databaseUrl,
  );
}

class SupabaseConfig {
  SupabaseConfig._();

  // Solo se usa la clave pública/publishable en la aplicación. La clave
  // secreta de Supabase nunca debe compilarse dentro de una APK o PWA.
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

class SupabaseUserProfile {
  const SupabaseUserProfile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.active,
    this.pharmacyCode,
  });

  final String id;
  final String fullName;
  final String role;
  final bool active;
  final String? pharmacyCode;

  factory SupabaseUserProfile.fromMap(Map<String, dynamic> row) {
    return SupabaseUserProfile(
      id: '${row['id'] ?? ''}',
      fullName: '${row['full_name'] ?? ''}',
      role: '${row['role'] ?? ''}',
      active: row['active'] == true,
      pharmacyCode: row['pharmacy_code']?.toString(),
    );
  }
}

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
    final paymentAmount = _doubleValue(data['paymentAmount']);
    final reportedEarnings = _doubleValue(
      data['courierEarnings'] ?? data['earnings'],
    );
    return Delivery(
      id: id,
      storeName: '${data['storeName'] ?? 'FarmaNorte'}',
      storeAddress: '${data['storeAddress'] ?? 'Dirección por confirmar'}',
      destination: '${data['destination'] ?? 'Destino por confirmar'}',
      destinationAddress:
          '${data['destinationAddress'] ?? 'Dirección por confirmar'}',
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
      pickupStops: _pickupStopsFromMap(data['pickupStops']),
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
      deliveryOutcome: data['deliveryOutcome']?.toString(),
    );
  }

  double? _optionalDouble(dynamic value) =>
      value == null ? null : _doubleValue(value);

  List<DeliveryPickupStop> _pickupStopsFromMap(dynamic raw) {
    return _listLike(raw).whereType<Map>().map((item) {
      final data = Map<dynamic, dynamic>.from(item);
      return DeliveryPickupStop(
        title: '${data['title'] ?? data['name'] ?? 'Punto de recogida'}',
        address: '${data['address'] ?? 'Dirección por confirmar'}',
        point: _latLngValue(data['point'], MapsConfig.monteria),
        label: '${data['label'] ?? 'Recoger'}',
      );
    }).toList();
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

  bool get isReady => _client != null;
  bool get hasAuthenticatedUser => _client?.auth.currentUser != null;

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
    final row = await _client!
        .from('profiles')
        .select('id, full_name, role, pharmacy_code, active')
        .eq('id', user.id)
        .maybeSingle();
    if (row == null) return null;
    return SupabaseUserProfile.fromMap(row);
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
        .select('id, username, full_name, role, pharmacy_code, active')
        .order('full_name');
    final shiftRows = await _client!
        .from('shifts')
        .select(
          'id, courier_id, pharmacy_code, zone_id, scheduled_for, '
          'starts_at, ends_at, is_double, status',
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

    final users = profileRows.map((row) {
      final id = '${row['id'] ?? ''}';
      final role = '${row['role'] ?? ''}';
      return AdminUser(
        id: id,
        name: '${row['full_name'] ?? 'Sin nombre'}',
        username: '${row['username'] ?? ''}'.trim().isEmpty
            ? 'Perfil Auth · ${id.substring(0, id.length < 8 ? id.length : 8)}'
            : '${row['username']}',
        role: _adminRoleLabel(role),
        pharmacy: row['pharmacy_code']?.toString() ?? 'Sin farmacia asignada',
        active: row['active'] == true,
      );
    }).toList();
    final profilesById = <String, Map<String, dynamic>>{
      for (final row in profileRows) '${row['id']}': row,
    };

    final shifts = shiftRows.map((row) {
      final zoneId = '${row['zone_id'] ?? ''}';
      final courierId = '${row['courier_id'] ?? ''}';
      final zone = zonesById[zoneId];
      final profile = profilesById[courierId];
      final isDouble = row['is_double'] == true;
      return AdminShift(
        id: '${row['id'] ?? ''}',
        // Nunca conviertas un UUID ausente en un texto vacío. Un valor vacío
        // puede terminar en el filtro de borrado y afectar cero filas sin
        // explicar al administrador qué ocurrió.
        courierId: courierId.trim().isEmpty ? null : courierId.trim(),
        zoneId: zoneId,
        courierName: '${profile?['full_name'] ?? 'Domiciliario'}',
        hours:
            '${_adminTime(row['starts_at'])} – ${_adminTime(row['ends_at'])}',
        zone: zone?.name ?? 'Zona sin nombre',
        pharmacy: row['pharmacy_code']?.toString() ?? adminNoPharmacy,
        isDouble: isDouble,
        secondHours: isDouble ? adminDoubleHours : null,
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
          'starts_at, ends_at, is_double, status',
        )
        .eq('courier_id', courierId)
        .gte('scheduled_for', _adminDateIso(weekStart))
        .lt('scheduled_for', _adminDateIso(end))
        .order('scheduled_for')
        .order('starts_at');

    return rows.map((row) {
      final zone = zoneById['${row['zone_id'] ?? ''}'];
      final isDouble = row['is_double'] == true;
      return AdminShift(
        id: '${row['id'] ?? ''}',
        courierId: '${row['courier_id'] ?? courierId}',
        zoneId: '${row['zone_id'] ?? ''}',
        courierName: courierName,
        hours:
            '${_adminTime(row['starts_at'])} – ${_adminTime(row['ends_at'])}',
        zone: zone?.name ?? 'Zona sin nombre',
        pharmacy: row['pharmacy_code']?.toString() ?? adminNoPharmacy,
        isDouble: isDouble,
        secondHours: isDouble ? adminDoubleHours : null,
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
      'Vendedor de farmacia' => 'pharmacy',
      _ => 'courier',
    };
    final pharmacy = user.pharmacy == 'Sin farmacia asignada'
        ? null
        : user.pharmacy;
    await _client!
        .from('profiles')
        .update({
          'full_name': user.name,
          'role': role,
          'pharmacy_code': pharmacy,
          'active': user.active,
        })
        .eq('id', user.id!);
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
      'Vendedor de farmacia' => 'pharmacy',
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
        'role': role,
        'pharmacy_code': pharmacyCode,
        'password': password,
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
    return AdminUser(
      id: '${created['id'] ?? ''}',
      name: '${created['full_name'] ?? user.name}',
      username: '${created['username'] ?? user.username}',
      role: user.role,
      pharmacy: '${created['pharmacy_code'] ?? user.pharmacy}',
      active: created['active'] == true,
    );
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
    final zoneRow = await _client!
        .from('zones')
        .select('id')
        .eq('name', shift.zone)
        .maybeSingle();
    if (zoneRow == null) throw StateError('La zona seleccionada no existe.');

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
      'pharmacy_code': shift.pharmacy == adminNoPharmacy
          ? null
          : shift.pharmacy,
      'zone_id': zoneRow['id'],
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
      final zoneId = zonesByName[shift.zone];
      if (zoneId == null) {
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
        'pharmacy_code': shift.pharmacy == adminNoPharmacy
            ? null
            : shift.pharmacy,
        'zone_id': zoneId,
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
    'pharmacy' => 'Vendedor de farmacia',
    _ => 'Domiciliario',
  };

  Future<void> signOut() async {
    if (!await initialize()) return;
    await _client!.auth.signOut();
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
            'deliveryOutcome': row['delivery_outcome'],
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

  Future<void> updateDeliveryStatus({
    required String deliveryId,
    required DeliveryStatus status,
  }) async {
    if (!await initialize() || !hasAuthenticatedUser) return;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _client!
          .from('deliveries')
          .update({
            'status': status.name,
            'updated_at': now,
            if (status == DeliveryStatus.pickedUp) 'picked_up_at': now,
            if (status == DeliveryStatus.delivered ||
                status == DeliveryStatus.notDelivered)
              'delivered_at': now,
          })
          .eq('id', deliveryId);

      await _client!.from('delivery_events').insert({
        'delivery_id': deliveryId,
        'actor_id': _client!.auth.currentUser!.id,
        'event_type': 'status_changed',
        'to_status': status.name,
        'metadata': {'source': 'courier_app'},
      });
    } catch (_) {
      // El flujo local sigue funcionando si el servidor está temporalmente
      // fuera de línea; el próximo ciclo de sincronización podrá reintentar.
    }
  }

  Future<bool> acceptDelivery({required String deliveryId}) async {
    if (!await initialize() || !hasAuthenticatedUser) return false;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final rows = await _client!
          .from('deliveries')
          .update({
            'status': DeliveryStatus.accepted.name,
            'accepted_courier_id': _client!.auth.currentUser!.id,
            'accepted_at': now,
            'updated_at': now,
          })
          .eq('id', deliveryId)
          .eq('status', DeliveryStatus.offered.name)
          .isFilter('accepted_courier_id', null)
          .select('id');
      if (rows.isEmpty) return false;
      await _client!.from('delivery_events').insert({
        'delivery_id': deliveryId,
        'actor_id': _client!.auth.currentUser!.id,
        'event_type': 'status_changed',
        'to_status': DeliveryStatus.accepted.name,
        'metadata': {'source': 'courier_app_autoaccept'},
      });
      return true;
    } catch (_) {
      return false;
    }
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

  Future<void> resetAdminUserPassword({
    required String userId,
    required String password,
  }) => SupabaseOperationsService.instance.resetAdminUserPassword(
    userId: userId,
    password: password,
  );

  Future<void> signOut() async {
    if (!SupabaseConfig.isConfigured) return;
    await SupabaseOperationsService.instance.signOut();
  }

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

  Future<Stream<List<Delivery>>?> watchDeliveries() =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.watchDeliveries()
      : RealtimeOperationsService.instance.watchDeliveries();

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

  Future<bool> acceptDelivery({required String deliveryId}) =>
      SupabaseConfig.isConfigured
      ? SupabaseOperationsService.instance.acceptDelivery(
          deliveryId: deliveryId,
        )
      : Future.value(false);
}

enum DeliveryKind { pharmacyToHome, storeToStore, overflow }

enum PaymentMethod { cash, card, qr }

enum DeliveryStatus { offered, accepted, pickedUp, delivered, notDelivered }

extension DeliveryKindX on DeliveryKind {
  String get label => switch (this) {
    DeliveryKind.pharmacyToHome => 'Domicilio',
    DeliveryKind.storeToStore => 'Traslado',
    DeliveryKind.overflow => 'Desborde',
  };

  IconData get icon => switch (this) {
    DeliveryKind.pharmacyToHome => Icons.shopping_bag_outlined,
    DeliveryKind.storeToStore => Icons.swap_horiz_rounded,
    DeliveryKind.overflow => Icons.bolt_rounded,
  };

  Color get color => switch (this) {
    DeliveryKind.pharmacyToHome => AppColors.primary,
    DeliveryKind.storeToStore => AppColors.blue,
    DeliveryKind.overflow => AppColors.warning,
  };
}

extension PaymentMethodX on PaymentMethod {
  String get label => switch (this) {
    PaymentMethod.cash => 'Efectivo',
    PaymentMethod.card => 'Tarjeta',
    PaymentMethod.qr => 'QR',
  };

  IconData get icon => switch (this) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.card => Icons.credit_card_outlined,
    PaymentMethod.qr => Icons.qr_code_2_rounded,
  };

  Color get color => switch (this) {
    PaymentMethod.cash => AppColors.warning,
    PaymentMethod.card => AppColors.blue,
    PaymentMethod.qr => AppColors.violet,
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
      'Tarifa oficial FarmaNorte · $label · ${_money(fee.toDouble())}';

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
        : kind != DeliveryKind.storeToStore || rawType.contains('domicilio');
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
    this.destinationOptions = const [],
    this.selectedAddressIndex = 0,
    this.pharmacyCode = '',
    this.neighborhood = '',
    this.addressReference = '',
    this.cashExpected,
    this.approvalPending = false,
    this.approvalCourierName,
    this.deliveryOutcome,
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
  final List<DeliveryAddress> destinationOptions;
  final int selectedAddressIndex;
  final String pharmacyCode;
  final String neighborhood;
  final String addressReference;
  final double? cashExpected;
  final bool approvalPending;
  final String? approvalCourierName;
  final String? deliveryOutcome;

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
    destinationOptions: destinationOptions,
    selectedAddressIndex: selectedAddressIndex ?? this.selectedAddressIndex,
    pharmacyCode: pharmacyCode,
    neighborhood: neighborhood,
    addressReference: addressReference,
    cashExpected: cashExpected,
    approvalPending: approvalPending ?? this.approvalPending,
    approvalCourierName: approvalCourierName ?? this.approvalCourierName,
    deliveryOutcome: deliveryOutcome ?? this.deliveryOutcome,
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

class AdminUser {
  const AdminUser({
    this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.pharmacy,
    required this.active,
    this.temporaryPassword,
  });

  final String? id;
  final String name;
  final String username;
  final String role;
  final String pharmacy;
  final bool active;
  final String? temporaryPassword;

  AdminUser copyWith({
    String? id,
    String? name,
    String? username,
    String? role,
    String? pharmacy,
    bool? active,
    String? temporaryPassword,
  }) => AdminUser(
    id: id ?? this.id,
    name: name ?? this.name,
    username: username ?? this.username,
    role: role ?? this.role,
    pharmacy: pharmacy ?? this.pharmacy,
    active: active ?? this.active,
    temporaryPassword: temporaryPassword ?? this.temporaryPassword,
  );
}

String _adminUserOptionKey(AdminUser user) => user.id ?? user.username;

class AdminWeeklyDayDraft {
  AdminWeeklyDayDraft({
    required this.hours,
    required this.zone,
    required this.pharmacy,
    this.isDouble = false,
  });

  String hours;
  String zone;
  String pharmacy;
  bool isDouble;
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

  String get name => courierName;

  String get displayHours =>
      isDouble && secondHours != null ? '$hours + $secondHours' : hours;

  String get pharmacyLabel => adminShiftPharmacyLabel(pharmacy);

  String get assignmentLabel =>
      pharmacy == adminNoPharmacy ? 'Toda la zona' : 'Farmacia $pharmacy';

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
    id: 'FN-155-001',
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
    id: 'FN-183-002',
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
    id: 'FN-232-003',
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
    productSummary: 'Un producto debe recogerse en otra FarmaNorte',
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
    id: 'FN-219-004',
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
    id: 'FN-177-005',
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
  const FarmaNorteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FarmaNorte Domicilios',
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
            borderSide: BorderSide.none,
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
      ),
      home: const SessionGate(),
    );
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

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
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
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
    if (_profile != null) {
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
    return const LoginScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
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
  }

  void _setInitialCredentials() {
    if (SupabaseConfig.isConfigured) return;
    _user.text = 'domiciliario@farmanorte.co';
    _password.text = '123456';
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

    if (!SupabaseConfig.isConfigured) {
      _enterLocalReview();
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
              : 'Este usuario no tiene rol de domiciliario.',
        );
      }

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
      _user.text = SupabaseConfig.isConfigured
          ? ''
          : admin
          ? 'admin@farmanorte.co'
          : 'domiciliario@farmanorte.co';
    });
    unawaited(_introController.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    final title = _adminMode
        ? 'Control de FarmaNorte'
        : 'Bienvenido a FarmaNorte';
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 470),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedBuilder(
                    animation: _introProgress,
                    builder: (context, child) {
                      final progress = reducedMotion
                          ? 1.0
                          : _introProgress.value;
                      return Transform.translate(
                        offset: Offset(0, (1 - progress) * 8),
                        child: Opacity(
                          opacity: .72 + progress * .28,
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: .22),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.local_pharmacy_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    _adminMode
                        ? 'Acceso administrativo'
                        : 'Acceso domiciliario',
                    style: TextStyle(
                      color: AppColors.primaryDark,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  AnimatedBuilder(
                    animation: _introProgress,
                    builder: (context, child) {
                      final progress = reducedMotion
                          ? 1.0
                          : _introProgress.value;
                      final characterCount = (title.length * progress)
                          .round()
                          .clamp(0, title.length)
                          .toInt();
                      final animatedTitle = title.substring(0, characterCount);
                      return Text(
                        '$animatedTitle${characterCount < title.length ? '▌' : ''}',
                        semanticsLabel: title,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 34,
                          height: 1.08,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -.8,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _adminMode
                        ? 'Configura zonas, turnos y cobertura de tu equipo en un solo lugar.'
                        : 'Acepta domicilios, revisa la ruta y entrega con toda la información a la mano.',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Perfil de acceso',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Domiciliario'),
                          icon: Icon(Icons.delivery_dining_rounded),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text('Administrador'),
                          icon: Icon(Icons.admin_panel_settings_outlined),
                        ),
                      ],
                      selected: {_adminMode},
                      onSelectionChanged: (selection) {
                        if (selection.isNotEmpty) {
                          _selectRole(selection.first);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: _user,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [
                            AutofillHints.username,
                            AutofillHints.email,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Usuario o correo',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _password,
                          obscureText: _obscure,
                          autofillHints: const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: 'Contraseña',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              tooltip: 'Mostrar contraseña',
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Checkbox.adaptive(
                            value: _rememberCredentials,
                            onChanged: (value) => setState(
                              () => _rememberCredentials = value ?? false,
                            ),
                          ),
                          const Expanded(
                            child: Text(
                              'Permitir guardar acceso en Google Password Manager',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => ScaffoldMessenger.of(context)
                              .showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Solicita al administrador una nueva contraseña temporal.',
                                  ),
                                ),
                              ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                          ),
                          child: const Text('¿Olvidaste tu clave?'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
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
                            _adminMode
                                ? Icons.dashboard_customize_rounded
                                : Icons.arrow_forward_rounded,
                          ),
                    label: Text(
                      _isLoading
                          ? 'Verificando…'
                          : _adminMode
                          ? 'Entrar al panel'
                          : 'Ingresar',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  Center(
                    child: Text(
                      'Versión operativa 0.9.0',
                      style: TextStyle(
                        color: AppColors.muted.withValues(alpha: .8),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
    final id = 'FN-155-${DateTime.now().millisecondsSinceEpoch % 100000}';
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
    unawaited(OperationsBackend.instance.signOut());
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
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
            label: const Text('Publicar domicilio · oferta de 3 minutos'),
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

enum _AdminSection { overview, zones, pharmacies, shifts, users }

extension _AdminSectionX on _AdminSection {
  String get label => switch (this) {
    _AdminSection.overview => 'Resumen',
    _AdminSection.zones => 'Zonas',
    _AdminSection.pharmacies => 'Farmacias',
    _AdminSection.shifts => 'Turnos',
    _AdminSection.users => 'Usuarios',
  };

  IconData get icon => switch (this) {
    _AdminSection.overview => Icons.space_dashboard_rounded,
    _AdminSection.zones => Icons.map_outlined,
    _AdminSection.pharmacies => Icons.local_pharmacy_outlined,
    _AdminSection.shifts => Icons.schedule_rounded,
    _AdminSection.users => Icons.manage_accounts_outlined,
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
    } catch (error) {
      if (!mounted) return;
      setState(() => _remoteError = '$error'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _loadingRemote = false);
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
    unawaited(OperationsBackend.instance.signOut());
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
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
          await SupabaseOperationsService.instance.createAdminUser(
            user: user,
            password: password,
          );
          await _loadRemote();
          _showRemoteMessage(
            'Usuario ${user.username} creado. Entrará con ese usuario y la contraseña inicial definida.',
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
          'No se pudo actualizar el perfil: ${'$error'.replaceFirst('Bad state: ', '')}',
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
          'Contraseña restablecida para ${user.name}. El perfil y su historial se conservaron.',
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
  };

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
              : 'Organiza la cobertura de FarmaNorte y prepara el día de tu equipo.',
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
      ],
    );
  }

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
        subtitle: 'Crea usuarios individuales para vendedores, domiciliarios y administradores.',
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
                    'FarmaNorte',
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
            Text(
              section.label,
              style: TextStyle(
                color: selected ? AppColors.primaryDark : AppColors.ink,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
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
                    'FarmaNorte / Administración',
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
        final pharmacyOptions = _pharmaciesForZone(zone);
        AdminPharmacy? pharmacy;
        if (!adminZoneAllowsAnyPharmacy(zone) && pharmacyOptions.isNotEmpty) {
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
          ..zone = zone
          ..pharmacy = pharmacy?.code ?? adminNoPharmacy
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
        if (!zoneExists ||
            (requiresPharmacy && _pharmacyByCode(dayDraft.pharmacy) == null)) {
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
            zone: dayDraft.zone,
            pharmacy: adminZoneAllowsAnyPharmacy(dayDraft.zone)
                ? adminNoPharmacy
                : pharmacy!.code,
            isDouble: dayDraft.isDouble,
            secondHours: dayDraft.isDouble ? adminDoubleHours : null,
            scheduledFor: _weekStart.add(Duration(days: day)),
            color: AppColors.primaryDark,
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

  Widget _dayDraft(AdminWeeklyShiftDraft draft, int dayIndex) {
    final dayDraft = draft.days[dayIndex];
    final date = _weekStart.add(Duration(days: dayIndex));
    final pharmacyOptions = _pharmaciesForZone(dayDraft.zone);
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
                    child: Text('${pharmacy.code} · ${pharmacy.name}'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => dayDraft.pharmacy = value);
                }
              },
            ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: dayDraft.isDouble,
            onChanged: (value) => setState(() => dayDraft.isDouble = value),
            title: const Text(
              'Doble turno',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              dayDraft.isDouble
                  ? 'Incluye el bloque adicional de $adminDoubleHours.'
                  : 'Solo se programa el turno base.',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickWeek,
                  icon: const Icon(Icons.calendar_month_outlined, size: 17),
                  label: Text(
                    'Semana: ${_adminCalendarDate(_weekStart)} – '
                    '${_adminCalendarDate(_weekStart.add(const Duration(days: 6)))}',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _suggest,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                  label: const Text('Sugerir automáticamente'),
                ),
              ],
            ),
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
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Guardar semana')),
    ],
  );
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
          '${pharmacy.code} · ${pharmacy.name.replaceFirst('FarmaNorte ', '')}',
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
              pharmacy.name,
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
                        pharmacy.name,
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
    final zoneNames = widget.zones.map((zone) => zone.name).toList();
    _zone = shift?.zone != null && zoneNames.contains(shift!.zone)
        ? shift.zone
        : zoneNames.isEmpty
        ? 'Sin zona asignada'
        : zoneNames.first;
    final pharmacyCodes = widget.pharmacies
        .where((pharmacy) => pharmacy.zone == _zone)
        .map((pharmacy) => pharmacy.code)
        .toList();
    _pharmacy =
        shift?.pharmacy != null &&
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
    if (_zone == 'Sin zona asignada') {
      setState(() => _error = 'Selecciona una zona operativa.');
      return;
    }
    if (!adminZoneAllowsAnyPharmacy(_zone) && _pharmacy == adminNoPharmacy) {
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
        zone: _zone,
        pharmacy: adminZoneAllowsAnyPharmacy(_zone)
            ? adminNoPharmacy
            : _pharmacy,
        isDouble: _isDouble,
        secondHours: _isDouble ? adminDoubleHours : null,
        scheduledFor: _scheduledFor,
        color: widget.initial?.color ?? AppColors.primaryDark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
                (zone) =>
                    DropdownMenuItem(value: zone.name, child: Text(zone.name)),
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
              decoration: const InputDecoration(labelText: 'Farmacia asignada'),
              items: [
                if (_availablePharmacies.isEmpty)
                  const DropdownMenuItem(
                    value: adminNoPharmacy,
                    child: Text(adminNoPharmacy),
                  ),
                for (final pharmacy in _availablePharmacies)
                  DropdownMenuItem(
                    value: pharmacy.code,
                    child: Text('${pharmacy.code} · ${pharmacy.name}'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _pharmacy = value);
              },
            ),
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
              : user.role == 'Vendedor de farmacia'
              ? Icons.storefront_outlined
              : Icons.delivery_dining_rounded,
          color: user.active ? AppColors.primaryDark : AppColors.muted,
        ),
      ),
      title: Text(
        user.name,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text('${user.role} · ${user.pharmacy}\n${user.username}'),
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

class _AdminUserDialog extends StatefulWidget {
  const _AdminUserDialog({required this.initial, required this.pharmacies});

  final AdminUser? initial;
  final List<AdminPharmacy> pharmacies;

  @override
  State<_AdminUserDialog> createState() => _AdminUserDialogState();
}

class _AdminUserDialogState extends State<_AdminUserDialog> {
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late String _role;
  late String _pharmacy;
  late bool _active;
  String? _error;

  @override
  void initState() {
    super.initState();
    final user = widget.initial;
    _name = TextEditingController(text: user?.name ?? '');
    _username = TextEditingController(text: user?.username ?? '');
    _password = TextEditingController();
    _role = user?.role ?? 'Domiciliario';
    final knownPharmacies = {
      'Sin farmacia asignada',
      ...widget.pharmacies.map((pharmacy) => pharmacy.code),
    };
    _pharmacy = knownPharmacies.contains(user?.pharmacy)
        ? user!.pharmacy
        : 'Sin farmacia asignada';
    _active = user?.active ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final username = _username.text.trim().toLowerCase();
    final password = _password.text;
    if (name.isEmpty || username.isEmpty) {
      setState(() => _error = 'Completa nombre y usuario.');
      return;
    }
    if (password.isNotEmpty && password.length < 8) {
      setState(() => _error = 'La contraseña debe tener mínimo 8 caracteres.');
      return;
    }
    if (_role == 'Vendedor de farmacia' &&
        _pharmacy == 'Sin farmacia asignada') {
      setState(() => _error = 'Selecciona la farmacia del vendedor.');
      return;
    }
    Navigator.pop(
      context,
      AdminUser(
        id: widget.initial?.id,
        name: name,
        username: username,
        role: _role,
        pharmacy: _pharmacy,
        active: _active,
        temporaryPassword: password.isEmpty ? null : password,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Nuevo usuario' : 'Editar usuario'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nombre completo'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            keyboardType: TextInputType.text,
            readOnly: widget.initial != null,
            decoration: const InputDecoration(
              labelText: 'Usuario',
              hintText: 'Ej. juan.perez',
              helperText: 'No necesita correo personal.',
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
                  ? 'Mínimo 8 caracteres. Entrégala de forma segura.'
                  : 'Déjala vacía para conservar la actual. Mínimo 8 caracteres.',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Rol'),
            items: const [
              DropdownMenuItem(
                value: 'Domiciliario',
                child: Text('Domiciliario'),
              ),
              DropdownMenuItem(
                value: 'Vendedor de farmacia',
                child: Text('Vendedor de farmacia'),
              ),
              DropdownMenuItem(
                value: 'Administrador',
                child: Text('Administrador'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _pharmacy,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Farmacia asignada',
              helperText:
                  'El domiciliario se vincula a farmacia desde el turno.',
            ),
            items: [
              const DropdownMenuItem(
                value: 'Sin farmacia asignada',
                child: Text('Sin farmacia asignada'),
              ),
              ...widget.pharmacies.map(
                (pharmacy) => DropdownMenuItem(
                  value: pharmacy.code,
                  child: Text('FN ${pharmacy.code} · ${pharmacy.zone}'),
                ),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _pharmacy = value);
            },
          ),
          if (widget.initial != null) ...[
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Usuario activo'),
              subtitle: Text(
                _active
                    ? 'Puede iniciar sesión.'
                    : 'No puede iniciar sesión, pero se conserva su historial.',
              ),
              value: _active,
              onChanged: (value) => setState(() => _active = value),
            ),
          ],
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
      FilledButton(onPressed: _save, child: const Text('Guardar usuario')),
    ],
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.profile});

  final SupabaseUserProfile? profile;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Delivery> _deliveries = SupabaseConfig.isConfigured
      ? <Delivery>[]
      : StageZeroDemoStore.instance.deliveries.value.toList();
  StreamSubscription<List<Delivery>>? _remoteDeliveriesSubscription;
  bool _connected = true;
  bool _autoAccepting = false;
  List<AdminShift> _courierShifts = const [];
  DateTime _courierWeekStart = adminPublishWeekStart(_adminToday());
  bool _loadingCourierShifts = false;
  String? _courierShiftError;

  String get _courierName {
    final name = widget.profile?.fullName.trim() ?? '';
    return name.isEmpty ? 'Juan Sebastián Ríos' : name;
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

  String get _baseLabel {
    final code = _basePharmacyCode;
    return code == null ? 'Punto base pendiente de asignación' : 'FN $code';
  }

  @override
  void initState() {
    super.initState();
    StageZeroDemoStore.instance.deliveries.addListener(
      _onLocalDeliveriesChanged,
    );
    unawaited(_connectToOperations());
    unawaited(_loadCourierShifts());
    unawaited(
      OperationsBackend.instance.publishCourierConnection(
        courierId: _courierId,
        connected: true,
      ),
    );
  }

  @override
  void dispose() {
    StageZeroDemoStore.instance.deliveries.removeListener(
      _onLocalDeliveriesChanged,
    );
    unawaited(_remoteDeliveriesSubscription?.cancel());
    unawaited(
      OperationsBackend.instance.publishCourierConnection(
        courierId: _courierId,
        connected: false,
      ),
    );
    super.dispose();
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
      setState(() => _deliveries = remoteDeliveries);
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
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _courierShiftError = '$error'.replaceFirst('Bad state: ', ''),
      );
    } finally {
      if (mounted) setState(() => _loadingCourierShifts = false);
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

  double get _earnings => _deliveries
      .where((item) => item.status == DeliveryStatus.delivered)
      .fold(0.0, (total, item) => total + item.serviceFee);

  void _replace(Delivery item) {
    final index = _deliveries.indexWhere((delivery) => delivery.id == item.id);
    if (index >= 0) {
      if (!SupabaseConfig.isConfigured) {
        StageZeroDemoStore.instance.updateDelivery(item);
      }
      setState(() => _deliveries[index] = item);
      unawaited(
        OperationsBackend.instance.updateDeliveryStatus(
          deliveryId: item.id,
          status: item.status,
        ),
      );
    }
  }

  void _setConnected(bool connected) {
    setState(() {
      _connected = connected;
      if (!connected) _autoAccepting = false;
    });
    unawaited(
      OperationsBackend.instance.publishCourierConnection(
        courierId: _courierId,
        connected: connected,
      ),
    );
  }

  void _setAutoAccepting(bool enabled) {
    if (!enabled || !_connected) {
      setState(() => _autoAccepting = false);
      return;
    }
    final baseCode = _basePharmacyCode;
    if (baseCode == null) {
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
            'Autoaceptado activo solo para $baseCode. Los demás domicilios se aceptan manualmente.',
          ),
        ),
      );
  }

  Future<void> _autoAcceptBaseOffers() async {
    final baseCode = _basePharmacyCode;
    if (baseCode == null || !_connected) return;
    final baseOffers = _deliveries
        .where(
          (item) =>
              item.status == DeliveryStatus.offered &&
              !item.approvalPending &&
              item.pharmacyCode == baseCode,
        )
        .toList();
    for (final item in baseOffers) {
      if (SupabaseConfig.isConfigured) {
        final accepted = await OperationsBackend.instance.acceptDelivery(
          deliveryId: item.id,
        );
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

    if (_active.isNotEmpty) {
      if (SupabaseConfig.isConfigured) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'La aprobación de un segundo domicilio aún no está habilitada en el backend real.',
              ),
            ),
          );
        return;
      }
      StageZeroDemoStore.instance.requestPharmacyApproval(
        deliveryId: item.id,
        courierName: _courierName,
      );
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Solicitud enviada a la farmacia. Tiene 3 minutos para aprobar.',
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
    final accepted = await OperationsBackend.instance.acceptDelivery(
      deliveryId: item.id,
    );
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
            'FarmaNorte · Turnos de $_courierName',
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
          pw.Text('Documento generado desde la aplicación FarmaNorte.'),
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

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
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
                leading: const Icon(Icons.history_rounded),
                title: const Text('Historial de domicilios'),
                onTap: () => Navigator.pop(sheetContext),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.logout_rounded,
                  color: AppColors.danger,
                ),
                title: const Text('Cerrar sesión'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(OperationsBackend.instance.signOut());
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute<void>(
                      builder: (_) => const LoginScreen(),
                    ),
                    (_) => false,
                  );
                },
              ),
            ],
          ),
        ),
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
                courierName: _courierName,
                onMenu: _openMenu,
                onChanged: _setConnected,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _HomeSheet(
                connected: _connected,
                baseLabel: _baseLabel,
                autoAccepting: _autoAccepting,
                available: _available,
                active: _active,
                pendingApprovals: _pendingApprovals,
                earnings: _earnings,
                onAutoAccept: _setAutoAccepting,
                onAccept: _accept,
                onDetail: (item) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DeliveryDetailScreen(
                        delivery: item,
                        onChanged: _replace,
                      ),
                    ),
                  );
                },
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
    required this.courierName,
    required this.onMenu,
    required this.onChanged,
  });

  final bool connected;
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
          const CircleAvatar(
            radius: 17,
            backgroundColor: AppColors.mint,
            child: Icon(
              Icons.delivery_dining_rounded,
              color: AppColors.primaryDark,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? 'Estás conectado' : 'Estás desconectado',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  connected
                      ? 'Recibiendo pedidos de tu zona'
                      : 'Activa para recibir pedidos',
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
            backgroundColor: AppColors.ink,
            child: Text(
              _courierInitials(courierName),
              style: const TextStyle(
                color: Colors.white,
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
    required this.earnings,
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
  final double earnings;

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
                          ? 'Solo autoacepta domicilios de $baseLabel; los demás se toman manualmente.'
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
        if (!connected)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
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
            'La solicitud vence en 3 minutos. Puedes seguir recibiendo otros domicilios.',
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
              ),
            ),
          ),
        ],
      ],
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
    this.compact = false,
    super.key,
  });

  final Delivery delivery;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final active = delivery.status != DeliveryStatus.offered;
    final overflow = delivery.kind == DeliveryKind.overflow;

    return Card(
      child: InkWell(
        onTap: active ? onPressed : null,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: EdgeInsets.all(compact ? 13 : 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _TypePill(
                          kind: delivery.kind,
                          service: delivery.service,
                        ),
                        _StatusPill(status: delivery.status),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      delivery.id,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
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
                  if (!active)
                    SizedBox(
                      height: 37,
                      child: FilledButton(
                        onPressed: onPressed,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 15),
                          minimumSize: Size.zero,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        child: Text(overflow ? 'Tomar' : 'Aceptar'),
                      ),
                    )
                  else
                    TextButton.icon(
                      onPressed: onPressed,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 16),
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
        ),
      ),
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

  @override
  void initState() {
    super.initState();
    _delivery = widget.delivery;
  }

  void _setStatus(DeliveryStatus status) {
    final updated = _delivery.copyWith(status: status);
    setState(() => _delivery = updated);
    widget.onChanged?.call(updated);
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
    final messageController = TextEditingController();
    final messages = <String>[
      'Canal del domicilio ${_delivery.id}.',
      'Farmacia y domiciliario pueden coordinar aquí.',
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            4,
            18,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chat del domicilio',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'La farmacia, el domiciliario y el administrador pueden participar.',
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
                const SizedBox(height: 14),
                ...messages.map(
                  (message) => Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 7),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.canvas,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: messageController,
                        decoration: const InputDecoration(
                          labelText: 'Escribe un mensaje',
                          prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Enviar mensaje',
                      onPressed: () {
                        final message = messageController.text.trim();
                        if (message.isEmpty) return;
                        setSheetState(() {
                          messages.add(message);
                          messageController.clear();
                        });
                      },
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.photo_camera_outlined, size: 17),
                      label: const Text('Foto opcional'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () =>
                          _launchPhoneCall(_delivery.recipientPhone),
                      icon: const Icon(Icons.call_outlined, size: 17),
                      label: const Text('Llamar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(messageController.dispose);
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

  void _advance() {
    switch (_delivery.status) {
      case DeliveryStatus.offered:
        _setStatus(DeliveryStatus.accepted);
      case DeliveryStatus.accepted:
        _setStatus(DeliveryStatus.pickedUp);
      case DeliveryStatus.pickedUp:
        _setStatus(DeliveryStatus.delivered);
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
    final updated = _delivery.copyWith(
      status: DeliveryStatus.notDelivered,
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
    body: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: CourierMap(
            delivery: _delivery,
            showCurrentLocation: true,
            showHomeStops: false,
          ),
        ),
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
          height: MediaQuery.sizeOf(context).height * .72,
          child: _DetailSheet(
            delivery: _delivery,
            action: _action,
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
          ),
        ),
      ],
    ),
  );
}

class _DetailSheet extends StatelessWidget {
  const _DetailSheet({
    required this.delivery,
    required this.action,
    required this.onAdvance,
    required this.onOrigin,
    required this.onDestination,
    required this.onDestinationChanged,
    required this.onCallClient,
    required this.onCashReceived,
    required this.onPickupStop,
  });

  final Delivery delivery;
  final String action;
  final VoidCallback onAdvance;
  final VoidCallback onOrigin;
  final VoidCallback onDestination;
  final ValueChanged<int> onDestinationChanged;
  final VoidCallback onCallClient;
  final VoidCallback onCashReceived;
  final ValueChanged<DeliveryPickupStop> onPickupStop;

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
              onPressed: onAdvance,
              icon: Icon(
                delivery.status == DeliveryStatus.accepted
                    ? Icons.inventory_2_outlined
                    : delivery.status == DeliveryStatus.pickedUp
                    ? Icons.check_rounded
                    : Icons.handshake_outlined,
              ),
              label: Text(action),
            ),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      DeliveryStatus.delivered => AppColors.primaryDark,
      DeliveryStatus.offered => AppColors.warning,
      _ => AppColors.blue,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(9),
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
