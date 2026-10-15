# Continuar el trabajo en una sesión local (Claude Code, pestaña Code)

Estado al 2026-10-15. Responder en español, corto: qué encontraste, qué corregiste,
qué comprobaste, qué falta probar.

## Hecho (sin publicar nada)

- Auditoría y corrección de push de la APK: ver `docs/PUSH-NOTIFICACIONES-2026-10-15.md`.
- `lib/main.dart`, `AndroidManifest.xml`, `res/raw/keep.xml`, sonidos en `res/raw`,
  `res/values/notification_colors.xml`, versión `0.20.7+29`.
- Preparado, NO aplicado/desplegado: `supabase/migrations/038_push_token_registration.sql`
  y `supabase/functions/send-push-notification/index.ts`.
- Respaldo de los originales: `_respaldo-push-2026-10-15/`.
- Script de compilación: `COMPILAR-APK.bat` → `tools/compilar-apk.ps1`
  (log en `_build_logs/build.log`, APK en `salidas-apk/`).

## Siguiente paso

1. Ejecutar `tools/compilar-apk.ps1` (o `flutter pub get`, `dart format lib/main.dart`,
   `flutter analyze`, `flutter build apk --release -PallowDebugSigning=true` con
   `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` de `pharmacy_web/.env.local`, sin imprimirlas).
2. Corregir errores de análisis/compilación (el código nuevo no se había compilado).
3. Verificar dentro del APK: `res/raw` con 5 sonidos, `ic_notification`, versión 0.20.7 (29),
   filtro `FLUTTER_NOTIFICATION_CLICK`.
4. Entregar la ruta de la APK al usuario para prueba en teléfono.

## Pendientes que requieren aprobación del usuario

- Aplicar migración 038 y desplegar `send-push-notification` en producción.
- Migración 036 (código compacto `FN167001`) no está aplicada en producción.
- No hay turnos programados para hoy en producción → push de domicilio nuevo sin destinatarios.
- Repositorio sin remoto y sin commits desde el 10-oct (riesgo de pérdida).
- Faltan secretos `WEB_PUSH_VAPID_*` (Supabase) y variable VAPID en GitHub Pages.
- PWA publicada es 0.20.4+26; web de farmacias publicada atrasada frente al código local.

## Reglas

- No crear datos de prueba, no borrar datos, no publicar sin confirmar.
- No imprimir claves ni el JSON de Firebase.
- No `git reset --hard` ni borrar cambios locales.
