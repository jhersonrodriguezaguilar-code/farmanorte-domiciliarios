# Auditoría de etapa 2 · Panel administrativo real

Fecha: 2026-10-10

## Resultado

**APROBADA como base administrativa ampliada para continuar con la página de
farmacias.**

No se declara todavía versión operativa final: no hay datos de piloto y no se
han ejecutado domicilios reales.

## Evidencia

- [x] Migración `002_admin_foundation.sql` ejecutada en Supabase real sin
  errores.
- [x] Login real probado contra Supabase Auth con el usuario administrador.
- [x] Consulta autenticada real a `profiles`, `zones`, `pharmacies` y `shifts`.
- [x] El usuario fue reconocido como `admin` y `active = true`.
- [x] El estado vacío inicial del backend se manejó sin insertar datos de
  demostración; después se cargó únicamente el catálogo confirmado.
- [x] Panel real conectado a lecturas de Supabase.
- [x] Altas/ediciones de zonas y farmacias conectadas a Supabase.
- [x] Edge Function `admin-create-user` publicada en Supabase.
- [x] La función rechaza solicitudes sin sesión con HTTP 401.
- [x] Se corrigió el `42501 permission denied for table profiles`: el rol
  `service_role` tenía `bypassrls`, pero no privilegios explícitos sobre la
  tabla. La migración `005_service_role_profiles_grants.sql` dejó
  `SELECT/INSERT/UPDATE/DELETE` aplicados en Supabase real.
- [x] La función usa `SUPABASE_SECRET_KEYS['default']` para operaciones
  administrativas y no expone la clave privada.
- [x] Prueba autenticada real con el administrador: la función alcanzó la
  validación del formulario y respondió HTTP 400 por datos inválidos; no se
  creó ningún usuario de prueba.
- [x] La programación de turnos muestra domiciliarios activos reales con su
  nombre y usuario.
- [x] Consulta REST autenticada real confirmó 1 domiciliario activo creado en
  Supabase; no se cargaron domiciliarios simulados.
- [x] La interfaz permite programar un día o una semana completa, sugerir la
  distribución diaria, seleccionar punto base y marcar doble turno.
- [x] La sugerencia semanal rota zonas por día para cada domiciliario y limita
  a dos las repeticiones por zona/farmacia cuando existen alternativas.
- [x] Índice único de turnos aplicado en Supabase real; antes de aplicarlo la
  consulta de duplicados devolvió cero filas.
- [x] El administrador puede crear perfiles con usuario visible sin correo
  personal; Auth usa un correo técnico interno que no se muestra al operador.
- [x] La desactivación conserva el perfil y el historial.
- [x] El panel muestra calendario semanal de turnos y permite seleccionar fecha
  dentro de los próximos 90 días.
- [x] Renombrar una zona actualiza también el `zone_name` de sus farmacias.
- [x] `flutter analyze --no-pub`: sin problemas después del calendario y la
  gestión de usuarios.
- [x] `flutter test --no-pub`: 12 pruebas aprobadas.
- [x] `flutter build apk --debug --no-pub`: APK generada correctamente.
- [x] `flutter build apk --release --no-pub` con URL y clave pública reales:
  APK generada correctamente después del módulo de turnos.
- [x] Catálogo real cargado en Supabase: 8 zonas, 21 farmacias y 21 relaciones
  zona-farmacia.
- [x] Auditoría del catálogo: 21 códigos únicos y 0 inconsistencias entre la
  zona principal de cada farmacia y su relación operativa.
- [x] Nombre corregido en código y Supabase: `Curva del Diablo`.
- [x] Excepciones de asignación implementadas: Zona 41, Cantaclaro, Pradera,
  Margen izquierda y Granja pueden cubrir toda la zona sin punto específico;
  Zona norte y las demás exigen farmacia cuando el turno es por punto.
- [x] `pharmacy_code` de `shifts` permite `NULL` para cobertura zonal.
- [x] Índice real `shifts_courier_schedule_key_unique` aplicado y verificado;
  evita duplicar turnos de cobertura zonal aunque `pharmacy_code` sea `NULL`.
- [x] Sesión persistente real activada con restauración automática al abrir la
  APK; no se cierra por reiniciar la aplicación.
- [x] Login preparado para Google Password Manager mediante `AutofillHints`;
  Android controla el icono de llave y el guardado seguro de la credencial.
- [x] Edge Function `admin-reset-user-password` publicada y protegida para
  cambiar la contraseña sin borrar el perfil ni su historial.
- [x] No existe borrado operativo de usuarios: editar, desactivar y
  restablecer la contraseña conservan el perfil, turnos y registros.
- [x] Se agregaron pruebas unitarias para las excepciones de zonas y etiquetas
  de cobertura.
- [x] Se agregó una prueba unitaria de rotación semanal y límite de repetición.
- [x] La programación semanal inicia por defecto, al publicar un sábado, en el
  lunes siguiente y muestra los siete días de lunes a domingo.
- [x] Administración agrupada por domiciliario: cada persona aparece una sola
  vez y al abrirla se muestra su calendario semanal completo.
- [x] Borrado de turnos por semana con confirmación; no elimina usuarios ni
  historial.
- [x] El domiciliario ve su nombre real desde `profiles.full_name`, no un nombre
  de demostración.
- [x] El menú del domiciliario incluye calendario semanal y generación de PDF
  mediante el selector nativo de guardar/compartir de Android.
- [x] Autoaceptado real restringido al punto base del turno y disponible solo
  cuando el domiciliario está conectado; los demás domicilios siguen manuales.
- [x] Página operativa de farmacia lista para abrir con doble clic mediante
  `ABRIR-PAGINA-FARMACIA.bat`; `npm run build` y Playwright pasan.
- [x] No se inventaron direcciones ni coordenadas; esos datos quedan pendientes
  de confirmación por farmacia.

## Limitación de prueba física

No había teléfono Android conectado durante esta revisión. La APK se deja
generada para instalación y prueba física; no se afirma que esa prueba haya
ocurrido.

## APK de revisión

- Ruta release: `build/app/outputs/flutter-apk/app-release.apk`
- Tamaño: 57.949.585 bytes
- SHA-256: `E6D068B01EF4FFEB8FDEFFDD25087157705F488855D2EE1ED0CF8954B2A67C9E`
- La prueba física queda pendiente porque no había teléfono Android conectado.

## Pendiente antes de declarar el producto listo

1. Guardar una semana real con el domiciliario creado y verificarla desde el
   calendario y desde Supabase.
2. Crear mediante este panel un usuario de farmacia y asignarlo a una farmacia
   y zona reales, sin escoger todavía la farmacia piloto.
3. Probar publicación y recuperación de clientes/direcciones desde la página
   web con ese usuario real.
4. Exigir el cambio de contraseña temporal en el primer ingreso del
   domiciliario.
5. Conectar notificaciones, chat, llamadas, ubicación y cierre de entrega.
6. Implementar cuota semanal, equivalentes virtuales y reporte de ganancias.
7. Hacer prueba física en Android, desplegar la página en Hostinger y realizar
   la auditoría integral.
8. Solo después de lo anterior elegir la farmacia piloto.
