# farmanorte_domiciliarios — instrucciones para Claude

Responde en español, corto y claro. En cada avance di solo: qué encontraste, qué
corregiste, qué comprobaste y qué falta probar.

**Al empezar una sesión, lee `docs/CONTINUAR-SESION-LOCAL.md`** (estado actual y
siguiente paso) y `docs/PUSH-NOTIFICACIONES-2026-10-15.md`.

## Proyecto

- APK Flutter de domiciliarios y administradores: `lib/main.dart`, `android/`, `assets/`.
- Web de farmacias (React/Vite): `pharmacy_web/`. Se publica en GitHub Pages desde el
  repositorio `jhersonrodriguezaguilar-code/farmanorte-pharmacy-web`.
- PWA de domiciliarios (Flutter Web) publicada en `/farmanorte-pharmacy-web/courier/`.
- Backend: Supabase producción `farmanorte-produccion` (ref `hilqtrsufjevhtzhyrom`),
  `supabase/migrations/`, `supabase/functions/`.
- Firebase `farmanorte-notificaciones`, paquete `com.farmanorte.farmanorte_domiciliarios`.
- Herramientas: Flutter en `C:\Users\jhers\Documents\Codex\tools\flutter`, Android SDK en
  `C:\Users\jhers\Documents\Codex\tools\android-sdk`.
- Compilar APK: `tools/compilar-apk.ps1` (lee Supabase de `pharmacy_web/.env.local` sin
  imprimir valores; APK en `salidas-apk/`). Sin keystore release: usa
  `-PallowDebugSigning=true` y no es APK final para Play Store.

## Prohibido

- Crear domicilios, clientes o usuarios ficticios; publicar notificaciones falsas.
- Borrar domicilios, turnos, usuarios o pagos sin autorización explícita.
- Imprimir claves, tokens o el JSON de la cuenta de servicio de Firebase; guardar claves
  privadas en el repositorio o en la APK.
- `git reset --hard`, `git checkout --`, limpiezas forzadas o borrar cambios locales.
- Aplicar migraciones a producción sin comprobar antes si ya están aplicadas y sin
  explicar qué se va a cambiar. Igual para RLS, servicios y despliegues.
- Afirmar que algo funciona al 100 % sin probarlo con backend real y dispositivo real.

## Reglas de negocio clave

- Marca en minúscula: `farmanorte`; farmacia `farmanorte 357`; rutas `FN 167`;
  consecutivo pegado `FN167001`, incremental por farmacia.
- Roles: administrador, domiciliario, farmacia. La farmacia usa solo la web, nunca la APK.
- Domiciliario de apoyo recibe de cualquier zona; con cruce se evalúa toda la ruta.
- Flujo: publicar → notificar elegibles → aceptar/asignar → recoger → recorrido →
  entregar → equivalente pendiente hasta firma dibujada (hasta 6 días, conserva la fecha
  del servicio) → farmacia recibe equivalente → pago → se libera ganancia.
- Pago: efectivo; tarjeta y QR se muestran como datáfono.
- Cliente: nombre, teléfono (10 dígitos, empieza por 3), dirección, documento opcional.
- Push: mostrar la notificación, sonar según permisos, al tocar abrir el domicilio o el
  chat. Nunca prometer abrir la app sola encima de otra.
- Diseño azul y blanco (ver skill `farmanorte-diseno` si está disponible).

## Validación antes de entregar

`dart format lib/main.dart`, `flutter analyze`, `flutter test`; compilar con Supabase
real y verificar applicationId, versión, `POST_NOTIFICATIONS`, google-services y sonidos
dentro del APK. Web: `npm run build` y comprobar que carguen la web y `/courier/`.
