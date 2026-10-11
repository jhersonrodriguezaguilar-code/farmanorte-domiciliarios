# FarmaNorte · Etapa 2 · Panel administrativo real

## Objetivo

Conectar el acceso administrativo autenticado al backend Supabase real y cargar
el catálogo operativo confirmado, sin elegir todavía la farmacia piloto.

## Incluido

- Panel administrativo real después de validar el rol `admin`.
- Lectura real de zonas, farmacias, perfiles y turnos mediante RLS.
- Alta y edición real de zonas.
- Alta y edición real de farmacias, con dirección y estado.
- Edición de perfiles existentes desde el panel.
- Alta y edición real de turnos cuando exista un perfil activo de domiciliario.
- Creación segura de usuarios desde el panel mediante la Edge Function
  `admin-create-user`; el administrador entrega un usuario como
  `nombre.apellido` y una contraseña inicial.
- Edición y desactivación de perfiles sin borrar el historial operativo.
- Restablecimiento de contraseña sobre el mismo perfil; no se elimina el
  usuario ni sus turnos o registros.
- Calendario semanal de turnos de lunes a domingo, con selección de fecha y
  horarios reales de Supabase.
- Estado vacío honesto cuando aún no se han cargado zonas, farmacias o turnos.
- Migración `supabase/migrations/002_admin_foundation.sql` aplicada al proyecto
  real para dirección/coordenadas de farmacias y referencias de zonas.
- Migración `supabase/migrations/004_usernames_customers.sql` aplicada al
  proyecto real para nombres de usuario y relación segura de clientes con
  domicilios.
- Migración `supabase/migrations/005_service_role_profiles_grants.sql` aplicada
  al proyecto real para que la función administrativa pueda operar sobre
  `profiles` con el rol interno de servicio.
- Migración `supabase/migrations/006_unique_courier_shift_schedule.sql`
  aplicada al proyecto real para que la programación semanal no duplique un
  mismo turno al guardarse de nuevo.
- Migración `supabase/migrations/007_flexible_zone_shifts.sql` aplicada al
  proyecto real para permitir turnos que cubren una zona sin farmacia puntual.
- Migración `supabase/migrations/008_idempotent_flexible_shifts.sql` aplicada al
  proyecto real; agrega una clave generada para que esos turnos sigan siendo
  idempotentes.
- La Edge Function usa las claves actuales `SUPABASE_PUBLISHABLE_KEYS` y
  `SUPABASE_SECRET_KEYS`, con compatibilidad de respaldo para las claves
  antiguas.
- Catálogo operativo real cargado en Supabase: 8 zonas y las 21 farmacias
  confirmadas por el administrador, con sus 21 relaciones zona-farmacia.
- El catálogo se cargó sin inventar direcciones ni coordenadas; esos datos se
  completarán únicamente cuando sean confirmados para cada punto.
- El catálogo usa el nombre corregido `Curva del Diablo`.
- La sesión de la APK se restaura automáticamente con Supabase Auth.
- El administrador puede restablecer la contraseña de un perfil sin eliminarlo
  ni perder su historial, mediante `admin-reset-user-password`.
- El login usa `AutofillHints` para que Android/Google Password Manager pueda
  ofrecer guardar y completar usuario y contraseña; la APK no guarda la clave
  en texto plano.

## Turnos ampliados

- El administrador selecciona domiciliarios activos reales por nombre y usuario;
  ya no escribe el nombre manualmente.
- Se puede programar un día concreto o una semana completa de lunes a domingo.
- La semana permite sugerencia automática, horario de día/noche, punto base y
  doble turno con bloque adicional de `17:00 – 23:00`.
- La sugerencia rota zonas por día para cada domiciliario, limita a dos las
  repeticiones por zona/farmacia cuando existen alternativas y queda editable
  antes de guardar; genera turnos concretos en Supabase para cada fecha.
- En Zona 41, Cantaclaro, Pradera, Margen izquierda y Granja el punto de
  farmacia es opcional y el turno se guarda como cobertura de toda la zona.
- En Zona norte y en las zonas no excepcionales se exige seleccionar farmacia.
- La semana se inicializa por defecto en el lunes siguiente cuando se publica
  un sábado; el administrador puede cambiarla antes de guardar.
- La vista de turnos agrupa por domiciliario. Cada nombre aparece una sola vez
  y abre los siete días de esa semana en calendario.
- Existe borrado confirmado de una semana completa por domiciliario. El borrado
  no elimina el perfil ni los domicilios históricos.
- El domiciliario recibe su `full_name` real, consulta el mismo calendario
  semanal desde Supabase y puede abrir el selector nativo para guardar/compartir
  un PDF.
- El autoaceptado real solo acepta ofertas del punto base del turno mientras
  el domiciliario está conectado; las demás ofertas continúan manuales.

## No incluido todavía

- Publicación de domicilios desde la página de farmacias.
- Notificaciones, chat, llamadas, GPS y operación de domicilios.
- Semilla de piloto o asignación de una farmacia piloto.
- Confirmar la matriz definitiva de puntos fijos y apoyo general.
- Cuota semanal, equivalentes virtuales, ganancias y cambio obligatorio de
  contraseña temporal al primer ingreso.
- Prueba física en un teléfono Android; no había dispositivo conectado durante
  esta revisión.

## Criterio de avance

La etapa avanza como base de administración cuando el administrador real puede
entrar, consultar las tablas protegidas y el código de altas/ediciones queda
compilado y auditado. La prueba integral de escritura con datos operativos se
hará cuando se habilite la página y antes del piloto.
