# FarmaNorte Domicilios

Aplicación móvil para domiciliarios de FarmaNorte.

## Compilación de revisión: etapa 2 + base de etapa 3 · 2026-10-10

Esta versión mantiene el modo local únicamente para las pruebas visuales ya
existentes, pero el panel administrativo y la autenticación real usan
Supabase. La página de farmacia usa el mismo backend y no muestra datos de
demostración cuando está configurada con credenciales reales.

## Incluido en la etapa 0

- Acceso de domiciliario en modo demostración.
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
- Preparación para mapa embebido con `google_maps_flutter`.
- Perfil administrativo responsive en el mismo proyecto.
- Resumen operativo con zonas, farmacias y turnos.
- Catálogo real de 21 farmacias con código, nombre visible y zona; las
  direcciones y coordenadas que aún no han sido confirmadas permanecen
  pendientes y no se inventan.
- Todas las zonas operativas se mantienen activas.
- Alta y edición local de zonas de cobertura.
- Alta y edición local de turnos por domiciliario y farmacia.
- Horarios configurados: 07:00 – 15:00 y 14:00 – 23:00.
- Doble turno con segundo bloque automático 17:00 – 23:00.
- Conteo separado de personas y bloques de turno, para reflejar que una persona puede doblarse.
- Estado automático del turno: programado, en curso o finalizado según el día y el horario.
- Estados operativos visibles: publicado, aceptado, en recorrido, entregado y no entregado.
- Oferta de domicilio con ventana operativa de 3 minutos y registro de solicitudes pendientes.
- Solicitud adicional de aprobación de la farmacia cuando el domiciliario ya tiene domicilios activos.
- Registro de “cliente no recibió” y obligación operativa de cobro de $5.000 a la farmacia.
- La APK no expone un panel de farmacia: el acceso de vendedores se trasladará a
  una página web independiente por farmacia, con publicación y seguimiento de
  domicilios.
- La estructura del formulario web contempla nombre, teléfono, barrio,
  dirección flexible, referencia, descripción/productos, forma de pago, valor
  con el que paga el cliente, tipo de servicio y observaciones; el navegador
  permitirá copiar y pegar estos datos.
- Tipos de servicio disponibles en la revisión: domicilio normal, compra
  externa, cruce con domicilio, cambio de menudo y desborde.
- Chat local del domicilio, llamada telefónica del sistema y fotos opcionales;
  no se incluyen videos.
- Registro adicional de entrega: fecha/hora de cierre, persona que recibe,
  valor recibido, observación, ubicación aproximada y foto opcional.
- Catálogo de las 21 farmacias reportadas, con nombre visible `FN <código>` y
  las zonas Margen izquierda, Zona norte, Cantaclaro, Pradera, Zona 41,
  Granja, Curva del Diablo y Nirvana.
- Usuarios individuales de demostración para domiciliario, vendedor y
  administrador; el panel administrativo incluye una sección de usuarios.
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
- Clientes reales por número de documento en la página de farmacia, con varias
  direcciones seleccionables.

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

La migración se encuentra en `supabase/migrations/001_initial_schema.sql` y
los datos iniciales del piloto en `supabase/seed/001_pilot_fn155.sql`.

## Ejecutar el proyecto

Desde la carpeta del proyecto:

```text
flutter pub get
flutter run
```

## Generar APK

```text
flutter build apk --release
```

El APK generado queda en `build/app/outputs/flutter-apk/app-release.apk`.

## Página web de farmacia

Desde `pharmacy_web/`:

```powershell
npm install
npm run build
```

El contenido de `pharmacy_web/dist/` es el que se subiría a Hostinger. La
página usa `VITE_SUPABASE_URL` y `VITE_SUPABASE_PUBLISHABLE_KEY`; nunca debe
recibir una clave `service_role`.

Para visualizarla con doble clic en Windows, ejecuta
`ABRIR-PAGINA-FARMACIA.bat` en la carpeta principal. El script abre
`http://127.0.0.1:5173`; sin `.env.local` se muestra la interfaz sin datos
ficticios, y con las variables públicas se conecta al proyecto real.

## Datos de demostración

El formulario de acceso viene precargado con:

- Correo: `domiciliario@farmanorte.co`
- Contraseña: `123456`

Para probar el perfil administrativo local, selecciona `Administrador` en el
selector de perfil. Con Supabase configurado se usa el usuario real y se
valida el rol en `public.profiles`.

La APK no ofrece panel de vendedores de farmacia: ese acceso se implementará
como una página web independiente alojada en Hostinger u otro hosting
equivalente. Una compilación sin variables `SUPABASE_URL` y
`SUPABASE_PUBLISHABLE_KEY` conserva el modo local solo para pruebas visuales;
la APK release de esta revisión fue compilada con el backend real.

En modo real, la autenticación contra Supabase ya está activa. El modo local
se conserva únicamente para las pruebas de interfaz sin backend.

## Google Maps

La navegación directa a la tienda y al domicilio ya está implementada mediante enlaces de Google Maps, por lo que funciona sin una clave dentro de la aplicación.

Para activar el mapa interactivo embebido, se debe crear una clave restringida en Google Cloud con Maps SDK for Android y Maps SDK for iOS, y reemplazar `REPLACE_WITH_GOOGLE_MAPS_API_KEY` en:

- `android/app/src/main/AndroidManifest.xml`
- `ios/Runner/AppDelegate.swift`

La clave debe restringirse por el identificador de la aplicación y no debe compartirse públicamente.

## APK de esta revisión

El archivo generado para la revisión de las etapas 2 y 3 es:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Tamaño de la compilación release actual: 57.949.585 bytes (55,2 MB).
SHA-256: `931DAF3FF05C899C66F8116DE2A837ACFA113CA9A18143A3251578946495959A`.
