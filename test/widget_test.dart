// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:farmanorte_domiciliarios/main.dart';

void main() {
  test('aplica las excepciones operativas de farmacia por zona', () {
    expect(adminZoneAllowsAnyPharmacy('Zona 41'), isTrue);
    expect(adminZoneAllowsAnyPharmacy('Cantaclaro'), isTrue);
    expect(adminZoneAllowsAnyPharmacy('Pradera'), isTrue);
    expect(adminZoneAllowsAnyPharmacy('Margen izquierda'), isTrue);
    expect(adminZoneAllowsAnyPharmacy('Granja'), isTrue);
    expect(adminZoneAllowsAnyPharmacy('Zona norte'), isFalse);
    expect(adminShiftPharmacyLabel(adminNoPharmacy), 'Toda la zona');
    expect(adminShiftPharmacyLabel('155'), '155');
  });

  test(
    'rota las zonas semanales sin repetir mas de dos veces cuando puede',
    () {
      final sequence = adminSuggestedZoneSequence(
        zones: ['357', 'Margen izquierda', '183', 'Cantaclaro'],
        courierIndex: 0,
      );
      final counts = <String, int>{};
      for (final zone in sequence) {
        counts[zone] = (counts[zone] ?? 0) + 1;
      }

      expect(sequence, hasLength(7));
      expect(counts.values.every((count) => count <= 2), isTrue);
      expect(sequence.toSet(), hasLength(4));
    },
  );

  test('publica el sábado la semana del lunes siguiente', () {
    expect(
      adminPublishWeekStart(DateTime(2026, 10, 10)),
      DateTime(2026, 10, 12),
    );
    expect(
      adminPublishWeekStart(DateTime(2026, 10, 12)),
      DateTime(2026, 10, 12),
    );
  });

  test('agrupa turnos reales por el UUID del domiciliario', () {
    final shift = AdminShift(
      id: 'shift-1',
      courierId: 'courier-uuid-1',
      zoneId: 'zone-1',
      courierName: 'Leonardo',
      hours: '07:00 – 15:00',
      zone: 'Zona norte',
      pharmacy: '155',
      isDouble: false,
      scheduledFor: DateTime(2026, 10, 12),
      color: Colors.teal,
    );
    final localShift = AdminShift(
      courierName: 'Leonardo',
      hours: '07:00 – 15:00',
      zone: 'Zona norte',
      pharmacy: '155',
      isDouble: false,
      scheduledFor: DateTime(2026, 10, 12),
      color: Colors.teal,
    );

    expect(adminCourierGroupKey(shift), 'courier-uuid-1');
    expect(adminCourierGroupKey(localShift), 'name:Leonardo');
  });

  test('aplica la tabla oficial de pagos de FarmaNorte', () {
    expect(const DeliveryServicePlan().fee, 5000);
    expect(const DeliveryServicePlan(hasDataphone: true).fee, 6000);
    expect(const DeliveryServicePlan(purchaseCount: 1).fee, 7000);
    expect(const DeliveryServicePlan(crossCount: 1).fee, 7000);
    expect(
      const DeliveryServicePlan(crossCount: 1, hasDataphone: true).fee,
      8000,
    );
    expect(const DeliveryServicePlan(changeOfMoney: true).fee, 4000);
    expect(
      const DeliveryServicePlan(hasDomicilio: false, crossCount: 1).fee,
      3000,
    );
    expect(
      const DeliveryServicePlan(
        crossCount: 1,
        purchaseCount: 1,
        hasDataphone: true,
      ).fee,
      11000,
    );
    expect(
      const DeliveryServicePlan(
        crossCount: 1,
        purchaseCount: 2,
        hasDataphone: true,
      ).fee,
      13000,
    );
    expect(
      const DeliveryServicePlan(crossCount: 3, hasDataphone: true).fee,
      13000,
    );

    final textPlan = DeliveryServicePlan.fromMap({
      'serviceType': 'Domicilio con dos cruces y plataforma',
    });
    expect(textPlan.crossCount, 2);
    expect(textPlan.hasDataphone, isTrue);
    expect(textPlan.fee, 10000);

    final purchasePlan = DeliveryServicePlan.fromMap({
      'serviceType': 'Compra',
    }, kind: DeliveryKind.storeToStore);
    expect(purchasePlan.hasDomicilio, isFalse);
    expect(purchasePlan.purchaseCount, 1);
    expect(purchasePlan.fee, 4000);
  });

  testWidgets('muestra el acceso para domiciliarios', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FarmaNorteApp());

    expect(find.bySemanticsLabel('Bienvenido a FarmaNorte'), findsOneWidget);
    expect(find.text('Acceso domiciliario'), findsOneWidget);
    expect(find.text('Ingresar'), findsOneWidget);
  });

  testWidgets('muestra pedidos y ganancias sin mapa en el inicio', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const FarmaNorteApp());
    await tester.tap(find.text('Ingresar'));
    await tester.pumpAndSettle();

    expect(find.text('Resumen de tu conexión'), findsOneWidget);
    expect(find.text('Pedidos disponibles'), findsOneWidget);
    expect(find.text('Ganancias hoy'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Estás conectado')).dy, lessThan(100));
    expect(
      tester.getTopLeft(find.text('Resumen de tu conexión')).dy,
      lessThan(300),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bloquea la aceptación cuando el domiciliario está desconectado',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const FarmaNorteApp());
      await tester.tap(find.text('Ingresar'));
      await tester.pumpAndSettle();

      final connectionSwitch = find.byType(Switch).first;
      await tester.tap(connectionSwitch);
      await tester.pumpAndSettle();

      expect(find.text('Estás desconectado'), findsOneWidget);
      expect(
        find.text(
          'Estás desconectado: los botones de aceptar están bloqueados.',
        ),
        findsOneWidget,
      );

      final acceptButtons = find.widgetWithText(FilledButton, 'Aceptar');
      expect(acceptButtons, findsWidgets);
      for (final element in acceptButtons.evaluate()) {
        expect((element.widget as FilledButton).onPressed, isNull);
      }
    },
  );

  testWidgets('abre el panel administrativo con zonas y turnos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FarmaNorteApp());

    await tester.tap(find.text('Administrador'));
    await tester.pump();

    expect(find.text('Acceso administrativo'), findsOneWidget);
    expect(find.text('Entrar al panel'), findsOneWidget);

    await tester.tap(find.text('Entrar al panel'));
    await tester.pumpAndSettle();

    expect(find.text('Centro de operaciones'), findsOneWidget);
    expect(find.text('Zonas operativas'), findsOneWidget);
    expect(find.text('Turnos programados'), findsOneWidget);
    expect(find.text('Ganancias hoy'), findsNothing);
  });

  testWidgets('adapta el panel administrativo a móvil', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const FarmaNorteApp());
    await tester.tap(find.text('Administrador'));
    await tester.pump();
    await tester.tap(find.text('Entrar al panel'));
    await tester.pumpAndSettle();

    expect(find.text('Centro de operaciones'), findsOneWidget);
    expect(find.text('Zonas'), findsOneWidget);
    expect(find.text('Turnos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('administra farmacias y muestra turnos dobles', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const FarmaNorteApp());
    await tester.tap(find.text('Administrador'));
    await tester.pump();
    await tester.tap(find.text('Entrar al panel'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Farmacias'));
    await tester.pumpAndSettle();
    expect(find.text('Nueva farmacia'), findsOneWidget);
    expect(find.text('FN 234'), findsOneWidget);
    expect(find.text('FN 252'), findsOneWidget);

    final shiftsTab = find.widgetWithText(ChoiceChip, 'Turnos');
    await tester.ensureVisible(shiftsTab);
    await tester.tap(shiftsTab);
    await tester.pumpAndSettle();
    expect(find.text('Juan Sebastián Ríos'), findsNWidgets(2));
    expect(find.textContaining('Turno único'), findsNothing);
    expect(find.text('Toca para ver el calendario completo'), findsWidgets);
    final openCourierWeek = find
        .text('Toca para ver el calendario completo')
        .first;
    await tester.ensureVisible(openCourierWeek);
    await tester.tap(openCourierWeek);
    await tester.pumpAndSettle();
    expect(find.text('Turnos de Juan Sebastián Ríos'), findsOneWidget);
    expect(find.text('Semana de turnos'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('muestra tarifa, cobro y contacto en el detalle', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const FarmaNorteApp());
    await tester.tap(find.text('Ingresar'));
    await tester.pumpAndSettle();

    final acceptButton = find.widgetWithText(FilledButton, 'Aceptar').first;
    await tester.tap(acceptButton);
    await tester.pumpAndSettle();
    expect(find.text('Detalle del domicilio'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('Domicilio normal', skipOffstage: false), findsWidgets);
    expect(find.text('Tu ganancia', skipOffstage: false), findsOneWidget);
    expect(find.text('Cobro', skipOffstage: false), findsOneWidget);
    expect(find.byTooltip('Llamar al cliente'), findsOneWidget);
    expect(
      find.text('Dirección del cliente', skipOffstage: false),
      findsOneWidget,
    );
    final exception = tester.takeException();
    expect(exception, isNull);
  });
}
