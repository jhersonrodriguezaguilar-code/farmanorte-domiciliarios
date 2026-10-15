# FarmaNorte Domicilios

Aplicación móvil para domiciliarios de FarmaNorte.

## Estado de implementación: siete etapas · 2026-10-12

El panel administrativo, la APK de domiciliarios y la página de farmacias
usan Supabase como backend real. El modo local queda aislado para pruebas
automatizadas y no debe confundirse con datos de operación. No se cargan
domicilios ficticios en una cuenta real.

## Incluido en la etapa 0

- Acceso de domiciliario contra Supabase Auth; el modo local solo se usa en
  pruebas automatizadas.
- Estado disponible/pausado.
- Zona y turno asignados.
- Resumen de servicios disponibles, en curso y entregados.
- Servicios normales y servicios de desborde.
- Flujo de aceptación del servicio.
- Flujo de estados: aceptar, iniciar recogida, confirmar recogida, iniciar entrega y marcar como entregado.
- Reporte de novedades.
- Historial básico del turno.
- Perfil del domiciliario.
- Ficha completa del domicilio después de aceptar.
- Forma de pago: efectivo, tarjeta o código QR. QR y transferencia se manejan
  como el mismo medio; no se muestra una opción separada de transferencia.
- Información separada de tienda, recogida, entrega y destinatario.
- Tabla oficial de pagos: domicilio normal, plataforma/datáfono, compras,
  cambio de menudo, cruces y combinaciones de estos servicios.
- Desglose de lo que gana el domiciliario por cada servicio.
- Paradas de recogida para cruces y compras externas, con navegación individual.
- Selector de direcciones alternativas del cliente.
- Cálculo de efectivo recibido y cambio pendiente por entregar.
- Llamada directa al cliente y contacto de soporte de Andrés Vargas.
- Botones de navegación directa a la tienda y al destino con Google Maps.
- Sin minimapa embebido en la operación: los botones abren Google Maps con la
  dirección de recogida o destino.
- Perfil administrativo responsive en el mismo proyecto.
- Resumen operativo con zonas, farmacias y turnos.
- Catálogo real de 21 farmacias con código, nombre visible y zona; las
  direcciones y coordenadas que aún no han sido confirmadas permanecen
  pendientes y no se inventan.
- Todas las zonas operativas se mantienen activas.
- Gestión persistida de zonas de cobertura y turnos reales desde el panel
  administrativo.
- Horarios configurados: 07:00 – 15:00 y 14:00 – 23:00.
- Doble turno con segundo bloque automático 17:00 – 23:00.
- Conteo separado de personas y bloques de turno, para reflejar que una persona puede doblarse.
- Estado automático del turno: programado, en curso o finalizado según el día y el horario.
- Estados operativos visibles: publicado, aceptado, en recorrido, entregado y no entregado.
- Oferta de domicilio con ventana operativa de 5 minutos y registro de solicitudes pendientes.
- Solicitud adicional de aprobación de la farmacia cuando el domiciliario ya tiene domicilios activos.
- Registro de “cliente no recibió” y obligación operativa de cobro de $5.000 a la farmacia.
- La APK no expone un panel de farmacia: el acceso de vendedores se trasladará a
  una página web independiente por farmacia, con publicación y seguimiento de
  domicilios.
- La estructura del formulario web contempla nombre, teléfono, barrio,
  dirección flexible, referencia, descripción/productos, forma de pago, valor
  con el que paga el cliente, tipo de servicio y observaciones; el navegador
  permitirá copiar y pegar estos datos.
- Tipos de servicio disponibles: domicilio normal, compra externa, cruce,
  domicilio con compra, domicilio con cruce y domicilio con compra y cruce.
- Chat Realtime por domicilio, llamada telefónica y equivalentes digitales;
  no se incluyen videos.
- Registro adicional de entrega: fecha/hora de cierre, persona que recibe,
  valor recibido, observación, ubicación aproximada y foto opcional.
- Catálogo de las 21 farmacias reportadas, con nombre visible `FN <código>` y
  las zonas Margen izquierda, Zona norte, Cantaclaro, Pradera, Zona 41,
  Granja, Curva del Diablo y Nirvana.
- Usuarios reales de domiciliario, farmacia y administrador; el panel
  administrativo incluye una sección de usuarios.
- Creación real de usuarios desde el panel con `nombre.apellido`, contraseña
  inicial, rol, edición y desactivación conservando historial.
- Restablecimiento administrativo de contraseña sin borrar perfiles ni perder
  historial.
- Sesión de Supabase persistente con restauración automática al abrir la APK.
- Calendario semanal real de turnos, de lunes a domingo.
- Publicación semanal por defecto del lunes siguiente cuando el administrador
  programa un sábado.
- Vista administrativa agrupada por domiciliario, con calendario individual y
  borrado confirmado de una semana sin borrar perfiles ni historial.
- Calendario semanal del domiciliario con opción de guardar/compartir PDF.
- Nombre real del domiciliario tomado de `profiles.full_name`.
- Autoaceptado real limitado al punto base del turno cuando está conectado.
- Autocompletado de usuario y contraseña compatible con Google Password Manager.
- Cobertura de toda la zona sin farmacia puntual en Zona 41, Cantaclaro,
  Pradera, Margen izquierda y Granja.
- Directorio global opcional de clientes: nombre, teléfono colombiano de 10
  dígitos y varias direcciones. El documento de identidad no es obligatorio y
  no se usa para publicar un domicilio.
- Selector de clientes y direcciones cuando el teléfono ya tiene registros.
- Validación de teléfono: exactamente 10 dígitos y comienza por 3.
- Equivalente pendiente hasta firma manuscrita; la firma escrita como nombre
  ya no reemplaza la firma dibujada.
- Cuotas semanales con cuota diaria, doble turno, abonos registrados y saldo
  pendiente por domiciliario.
- Aprobación segura de un segundo domicilio, reasignación a apoyo y
  transiciones de estado mediante RPC, no mediante actualizaciones libres.
- Auditoría de creación de usuarios, restablecimientos de contraseña y
  actualización de perfiles de farmacia.

La autenticación real y el panel administrativo real ya están conectados a
Supabase. El modo local se conserva únicamente para pruebas visuales de la APK;
no se usa para declarar la operación real lista. La página web de farmacia está
en `pharmacy_web/` y la publicación real exige un perfil de farmacia, una
farmacia activa y una zona configurada.

## Backend real y panel administrativo

La guía de configuración del esquema y las variables de compilación está en
[docs/ETAPA-1-SUPABASE.md](docs/ETAPA-1-SUPABASE.md). El panel administrativo
real está documentado en [docs/ETAPA-2-ADMIN-REAL.md](docs/ETAPA-2-ADMIN-REAL.md).
La página web y su auditoría están documentadas en
[docs/ETAPA-3-PAGINA-FARMACIA.md](docs/ETAPA-3-PAGINA-FARMACIA.md) y
[docs/AUDITORIA-ETAPA-3.md](docs/AUDITORIA-ETAPA-3.md).
La auditoría actual de las siete fases, con el porcentaje de código y los
bloqueadores externos de producción, está en
`design-plans/AUDITORIA-FINAL-2026-10-12.md`.
La migración de usuarios y clientes está en
`supabase/migrations/004_usernames_customers.sql`; los permisos internos para
la función administrativa están en
`supabase/migrations/005_service_role_profiles_grants.sql`. La creación segura
de usuarios se publica como `admin-create-user` y nunca expone una clave
secreta en la APK o en la página.
La programación de turnos usa domiciliarios activos reales, permite guardar un
día o una semana completa, sugerir distribución automática, asignar punto base
y marcar doble turno. La protección contra turnos duplicados está en
`supabase/migrations/006_unique_courier_shift_schedule.sql` y
`supabase/migrations/008_idempotent_flexible_shifts.sql`. La función
`admin-reset-user-password` permite recuperar una cuenta sin eliminar su
historial. La sesión persistente se configura desde Supabase Auth.
La semilla de piloto no se ejecuta hasta terminar y auditar la aplicación y la
página web.

Las migraciones se ejecutan en orden desde
`supabase/migrations/001_initial_schema.sql` hasta la última disponible.
Las migraciones 021–026 agregan transición segura, contraseñas temporales,
directorio global de clientes, auditoría, liquidación de cuotas y las políticas
que permiten compartir clientes globales entre farmacias. La migración 026
bloquea la firma escrita y endurece la presencia en tiempo real del
domiciliario. La semilla
de piloto no se ejecuta automáticamente.

## Ejecutar el proyecto

Desde la carpeta del proyecto:

```text
flutter pub get
flutter run
```

## Generar APK

```text
# QA local (firma debug, no distribuir)
flutter build apk --release -PallowDebugSigning=true

# Producción: configura android/key.properties o el workflow de GitHub Actions
flutter build apk --release
```

El APK generado queda en `build/app/outputs/flutter-apk/app-release.apk`.

## Página web de farmacia

Desde `pharmacy_web/`:

```powershell
npm install
npm run build
```

El contenido de `pharmacy_web/dist/` se publica con GitHub Actions en GitHub
Pages. La página usa `VITE_SUPABASE_URL`,
`VITE_SUPABASE_PUBLISHABLE_KEY` y, si se desean avisos web en segundo plano,
`VITE_WEB_PUSH_PUBLIC_KEY`; nunca debe recibir una clave `service_role`.

Para visualizarla con doble clic en Windows, ejecuta
`ABRIR-PAGINA-FARMACIA.bat` en la carpeta principal. El script abre
`http://127.0.0.1:5173`; sin `.env.local` se muestra la interfaz sin datos
ficticios y se bloquea el acceso operativo, y con las variables públicas se
conecta al proyecto real.

## Pruebas locales

Las pantallas de revisión local solo se habilitan explícitamente dentro de las
pruebas automatizadas. Una APK o ejecución normal sin las variables reales no
entra al modo local y no muestra domicilios, usuarios ni turnos de ejemplo.

Las pruebas automatizadas usan credenciales aisladas mediante variables de
entorno. No se publican correos ni contraseñas en este repositorio.

En producción, el usuario real se autentica contra Supabase y su rol se valida
en `public.profiles`.

La APK no ofrece panel de vendedores de farmacia: ese acceso está en la página
web independiente. Una compilación sin variables `SUPABASE_URL` y
`SUPABASE_PUBLISHABLE_KEY` muestra una pantalla de configuración requerida;
no entra en modo operativo real.

La autenticación contra Supabase ya está activa en modo real.

## Alertas en segundo plano

La APK incluye la recepción preparada de Firebase Cloud Messaging, el permiso de
notificaciones de Android 13, el canal de alta importancia
`farmanorte_operations_v2`, el registro de
tokens en `public.push_tokens` y la navegación al domicilio o al chat cuando el
usuario toca una alerta. La página de farmacia llama a la función Edge
`send-push-notification` al publicar un domicilio o enviar un mensaje.

Para activar las alertas reales hay que completar la configuración de Firebase
fuera del repositorio:

1. Crear o seleccionar el proyecto Firebase, registrar la aplicación Android
   con el paquete `com.farmanorte.farmanorte_domiciliarios` y activar Cloud
   Messaging.
2. Compilar la APK pasando `FIREBASE_API_KEY`, `FIREBASE_APP_ID`,
   `FIREBASE_MESSAGING_SENDER_ID` y `FIREBASE_PROJECT_ID` mediante
   `--dart-define`. Si también se usa Realtime Database, agregar
   `FIREBASE_DATABASE_URL`.
3. En Supabase, desplegar `supabase/functions/send-push-notification` y guardar
   la cuenta de servicio de Firebase como secreto
   `FIREBASE_SERVICE_ACCOUNT_JSON`. Para la página web, guardar además
   `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` y
   `WEB_PUSH_VAPID_SUBJECT`. Las claves privadas nunca deben entrar en GitHub ni
   en la APK.

La página web registra su Service Worker en la versión publicada, permite
activar las alertas desde `Ajustes` y desactiva el token al cerrar sesión. La
notificación web lleva el domicilio o el chat y, al tocarla, abre directamente
el registro correspondiente. Para que funcione fuera de la pestaña abierta,
además de desplegar la función Edge y los secretos VAPID, cada navegador debe
conceder permiso; en iPhone se debe añadir la web a la pantalla de inicio.

Ejemplo de compilación con las variables públicas (los valores de Firebase se
deben completar localmente):

```powershell
flutter build apk --release `
  --dart-define=SUPABASE_URL=https://tu-proyecto.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_... `
  --dart-define=FIREBASE_API_KEY=... `
  --dart-define=FIREBASE_APP_ID=... `
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... `
  --dart-define=FIREBASE_PROJECT_ID=...
```

Android mostrará una notificación cuando la aplicación esté minimizada o haya
sido cerrada normalmente; al tocarla se abre el domicilio o el chat. Una
detención forzada desde Ajustes puede impedir que Android entregue mensajes
hasta que el usuario vuelva a abrir la aplicación.

## Google Maps

La navegación directa a la tienda y al domicilio ya está implementada mediante enlaces de Google Maps, por lo que funciona sin una clave dentro de la aplicación.

Para activar el mapa interactivo embebido, se debe crear una clave restringida en Google Cloud con Maps SDK for Android y Maps SDK for iOS, y reemplazar `REPLACE_WITH_GOOGLE_MAPS_API_KEY` en:

- `android/app/src/main/AndroidManifest.xml`
- `ios/Runner/AppDelegate.swift`

La clave debe restringirse por el identificador de la aplicación y no debe compartirse públicamente.

## APK de QA local

El archivo generado localmente para QA es:

```text
build/app/outputs/flutter-apk/app-release.apk
```

La compilación local usa firma debug únicamente si se ejecuta con
`-PallowDebugSigning=true`. Para entregar a domiciliarios se debe usar la
keystore privada configurada por `android/key.properties` o por el workflow de
GitHub Actions; no se debe distribuir una APK firmada con debug.
