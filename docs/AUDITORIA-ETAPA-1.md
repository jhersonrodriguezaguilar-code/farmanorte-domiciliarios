# Auditoría de etapa 1 · Base técnica y backend

Fecha: 2026-10-10

## Resultado

**APROBADA como base técnica para continuar el desarrollo.**

La base fue comprobada contra el proyecto Supabase real con Auth, RLS,
Realtime, esquema y perfil administrativo. La prueba integral de publicación
de domicilios, presencia y eventos se realizará con los módulos reales de las
siguientes etapas, antes del piloto final.

Corrección aplicada en esta segunda revisión: se eliminó la posibilidad de que
un usuario modifique su propio rol o se autoeleve a administrador. Los perfiles
ahora se crean o modifican desde el flujo administrativo.

Corrección aplicada en esta revisión real: se ejecutó la migración en el
proyecto Supabase de producción y se verificaron las tablas, RLS y Realtime.
La semilla de FN 155 no se ejecutó porque la farmacia piloto todavía no está
decidida.

Corrección aplicada en esta revisión de la APK: cuando se compila con las
variables reales, el acceso exige Supabase Auth y un perfil con rol válido; no
se muestran domicilios locales como respaldo. El punto base queda sin asignar
hasta definir el piloto y las funciones aún no conectadas muestran su estado
pendiente en vez de ejecutar una operación local.

Corrección aplicada en esta revisión de cuenta real: se creó el usuario de
Supabase Auth `jhersonrodriguezaguilar@gmail.com` y se verificó su perfil
`jherson.aguilar` con rol `admin`, activo y sin farmacia asignada. La farmacia
piloto sigue pendiente de definición.

## Comprobaciones realizadas

- [x] Dependencia `supabase_flutter` instalada.
- [x] Variables de entorno configurables; no hay credenciales reales en el
  código.
- [x] Adaptador Supabase integrado con respaldo local.
- [x] Tablas preparadas: farmacias, zonas, perfiles, relaciones de zona,
  turnos, presencia, domicilios, eventos y tokens.
- [x] RLS preparado en todas las tablas.
- [x] Políticas iniciales de lectura y escritura preparadas.
- [x] La política de perfiles impide la autoelevación a administrador.
- [x] Triggers de actualización preparados.
- [x] Publicación Realtime de `deliveries` preparada.
- [x] Semilla del piloto `FN 155` preparada.
- [x] Migración ejecutada en Supabase real sin errores.
- [x] Verificación real: 9 tablas con RLS habilitado.
- [x] Verificación real: `deliveries` publicado en Realtime.
- [x] Verificación real: endpoint sin sesión rechazó acceso con HTTP 401.
- [x] Inicio de sesión real implementado en la APK; exige Auth y perfil con rol.
- [x] Usuario real de Auth y perfil `admin` creados y verificados en Supabase.
- [x] La APK real no usa datos locales si Supabase está configurado.
- [x] `flutter analyze --no-pub`: sin problemas en código local.
- [x] `flutter test --no-pub`: 11 pruebas locales aprobadas en la auditoría
  actual.
- [x] `flutter build apk --release` con URL y clave pública reales.
- [x] Formato Dart verificado.

APK de esta revisión:

- Ruta: `build/app/outputs/flutter-apk/app-release.apk`
- Tamaño: 54.752.989 bytes
- SHA-256: `303D1CD527285CDFBBBAD0C1C9D7368387D66F9B4AE037E9EC91730C999637DE`

## Pendiente para la auditoría integral antes del piloto

La etapa 1 ya puede avanzar. Antes de autorizar el piloto todavía se debe:

1. Confirmar desde la APK el inicio de sesión autenticado con el perfil creado.
2. Confirmar que un domicilio publicado desde la página aparece por Realtime.
3. Cambiar su estado y confirmar el registro en `delivery_events`.
4. Confirmar presencia/ubicación en `courier_presence`.
5. Definir la farmacia y zona del piloto y ejecutar la semilla correcta solo al
   final del desarrollo.

La etapa 1 no depende de escoger ahora la farmacia piloto. La APK todavía no
se entrega como versión operativa final hasta completar la auditoría integral
de las etapas de aplicación y página web.
