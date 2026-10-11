# FarmaNorte · Etapa 1 · Supabase

Esta etapa prepara el backend real sin romper la compilación local de la APK.
La aplicación continúa mostrando la demostración local si no recibe las
variables de entorno de Supabase.

## 1. Crear el proyecto

1. Crear un proyecto en Supabase.
2. Abrir el **SQL Editor**.
3. Ejecutar `supabase/migrations/001_initial_schema.sql`.
4. **No ejecutar todavía** `supabase/seed/001_pilot_fn155.sql`: esa semilla
   queda como plantilla hasta que estén terminadas la aplicación, la página
   de farmacias y sus auditorías, y el administrador confirme el piloto.

El esquema deja preparado el registro de farmacias, zonas, usuarios, turnos,
presencia, domicilios, eventos de auditoría y tokens de notificación.

Para crear el primer administrador, primero crea su usuario en **Authentication
> Users**, copia su UUID y ejecuta en el SQL Editor, sustituyendo los valores:

```sql
insert into public.profiles (id, full_name, role, active)
values ('UUID_DEL_USUARIO_AUTH', 'Administrador FarmaNorte', 'admin', true);
```

Después de ese primer registro, solo un administrador puede crear o modificar
perfiles. Ningún usuario puede autoasignarse el rol de administrador.

## 2. Variables para la aplicación

Tomar del panel de Supabase la URL del proyecto y la clave pública
**publishable/anon**. No usar la `service_role` ni ninguna clave secreta dentro
de Flutter.

Para ejecutar en desarrollo con el backend real (sin asignar todavía un punto
base):

```powershell
flutter pub get
flutter run `
  --dart-define=SUPABASE_URL=https://TU_PROYECTO.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=TU_CLAVE_PUBLICA `
  --dart-define=FARMANORTE_BASE_PHARMACY_CODE=
```

Para crear la APK:

```powershell
flutter build apk --release `
  --dart-define=SUPABASE_URL=https://TU_PROYECTO.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=TU_CLAVE_PUBLICA `
  --dart-define=FARMANORTE_BASE_PHARMACY_CODE=
```

Sin esas variables, la APK usa los datos locales de revisión. Con URL y clave
reales, el inicio de sesión usa Supabase Auth, consulta el perfil y bloquea el
acceso si la sesión no tiene rol operativo. Las lecturas/escrituras requieren
una sesión autenticada porque las tablas tienen RLS habilitado.

## 3. Qué queda preparado y qué sigue

- `deliveries` tiene suscripciones en tiempo real.
- Cada cambio de estado intenta escribir un registro en `delivery_events`.
- La presencia y la ubicación se guardan en `courier_presence`.
- Se normaliza `transferencia` histórica a `QR`; los únicos medios nuevos son
  `cash`, `card` y `qr`.
- El código de inicio de sesión real ya valida Auth, perfil, rol y cierre de
  sesión. El administrador real ya está creado y verificado; la asignación de
  farmacias y zonas se hará desde las siguientes etapas.

## Punto de control de la etapa 1

La base técnica se considera lista para avanzar cuando:

1. El SQL se ejecuta sin errores.
2. La APK compila sin credenciales incluidas en el código.
3. El modo local sigue funcionando.
4. Una sesión Auth real puede ingresar y consultar las tablas protegidas.

La publicación de domicilios, cambios de estado, eventos y presencia se
auditará con los módulos reales de la aplicación y de la página web. No se
ejecuta el piloto ni se siembra `FN 155` para avanzar en el desarrollo.
