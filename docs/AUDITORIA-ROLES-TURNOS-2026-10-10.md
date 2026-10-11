# Auditoría de roles y turnos · 2026-10-10

## Resultado

La corrección del borrado de semanas quedó aplicada y verificada en código.
Además, se ejecutó la migración real de Supabase y se eliminaron los turnos
existentes por solicitud del administrador. Los usuarios y el historial no se
eliminaron.

## Pruebas ejecutadas

- `flutter analyze --no-pub`: aprobado.
- `flutter test --no-pub`: 12 pruebas aprobadas.
- `flutter build apk --release --no-pub` con la URL y la clave pública reales:
  aprobado.
- `pharmacy_web`: `npm run build`: aprobado.
- `PLAYWRIGHT_REAL_BACKEND=1 npm test`: 2 pruebas aprobadas.
- Supabase real, consulta de solo lectura: política
  `shifts_admin_write` presente con `ALL` para `{authenticated}` y condición
  `is_admin()`.
- Supabase real, antes de la limpieza: 22 turnos registrados y 0 sin
  domiciliario asociado.
- Supabase real, después de la limpieza: 0 turnos registrados.
- Supabase real: 0 clientes existentes, índice global por documento creado y
  función segura `get_pharmacy_zone_couriers` creada.

## Corrección aplicada al borrado de turnos

1. El identificador vacío del domiciliario ya no se convierte en un valor
   válido para agrupar o borrar.
2. Los turnos reales se agrupan por el UUID del perfil.
3. Antes de borrar se valida que exista el UUID real del domiciliario.
4. Supabase devuelve cuántas filas se eliminaron.
5. Si no había filas, la interfaz lo informa sin presentar un falso error.
6. Si Supabase no confirma el borrado completo, la interfaz muestra que debe
   revisarse RLS en vez de declarar éxito.

## Roles

### Correcto

- Los roles de backend son `admin`, `pharmacy` y `courier`.
- `is_admin()` exige perfil activo y rol `admin`.
- El administrador tiene permisos RLS para gestionar zonas, farmacias,
  perfiles, turnos, presencia, domicilios, eventos y tokens.
- La creación y el restablecimiento de contraseñas pasan por Edge Functions
  que vuelven a validar que el actor sea un administrador activo.
- Los perfiles no tienen una operación de borrado en el panel; se conservan
  para no perder historial.

### Pendiente funcional

- El backend reconoce al administrador con permisos amplios, pero la página
  web de farmacia solo acepta el rol `pharmacy`. Si el administrador debe usar
  también esa página o trabajar como domiciliario, se necesita un selector de
  contexto/rol, no duplicar usuarios.
- La página web busca clientes con la combinación
  `pharmacy_code + document_number`. Por tanto, todavía no comparte el mismo
  cliente entre FN 145 y FN 357 como se definió en los requisitos. Debe
  cambiarse a un registro global por documento, con RLS y auditoría.
- Las Edge Functions administrativas responden CORS con `*`. La autenticación
  JWT está activa, pero antes de producción conviene restringir los orígenes a
  los dominios oficiales y dejar los dispositivos móviles sin dependencia de
  CORS.

## Estado del producto después de esta revisión

| Área | Estado |
|---|---:|
| Base Supabase/Auth/RLS | 95% |
| Panel administrativo | 95% |
| Borrado de semanas de turnos | 100%: corregido y verificado contra la base real |
| Clientes globales entre farmacias | 100%: esquema, unicidad y RLS aplicados |
| Página de farmacias | 70% |
| Operación real de domicilios | 40% |
| Tiempo real, notificaciones y comunicación | 35% |
| Cuotas, equivalentes y ganancias | 20% |
| Despliegue y piloto | 10% |
| Plan completo | 62/100 |

## APK de revisión

- Archivo: `build/app/outputs/flutter-apk/app-release.apk`
- Archivo: `build/app/outputs/flutter-apk/app-release.apk`
- Tamaño: 57.949.585 bytes
- SHA-256: `E45FD9BBDEB03C6E9553A0F6A503A33D816F08FE65527004FD6E05BA1FD0A603`

## Próximo orden de trabajo

1. Compilar y revisar la APK actualizada.
2. Validar en la página de farmacia que un cliente guardado en una farmacia se
   pueda recuperar desde otra usando el mismo documento.
3. Permitir contexto administrativo completo en la web, si se confirma que el
   administrador debe publicar domicilios como una farmacia.
4. Continuar con la página web y sus pruebas reales.
5. Después: notificaciones, aceptación, chat, llamadas, GPS, equivalentes,
   cuotas y PWA para iPhone.

