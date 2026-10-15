# Auditoría integral de FarmaNorte · APK, PWA, web de farmacias y Supabase

Fecha: 2026-10-13  
Alcance: aplicación Flutter de domiciliarios y administradores, PWA de
domiciliarios, web de farmacias, funciones Edge, esquema/RLS/reportes de
Supabase y preparación de entrega real.

## Veredicto

La base de código queda en aproximadamente **96%** y la preparación para una
operación real en **76%**. No es correcto declarar el proyecto al 100% todavía:
la lógica principal y la base de datos están mucho más cerca, pero las
notificaciones en segundo plano, la firma final del APK, el despliegue de la
versión exacta y la prueba física siguen sin estar verificadas.

No se crearon domicilios, usuarios, turnos ni datos ficticios durante esta
auditoría. Las comprobaciones automáticas fueron sobre el código y los datos
de producción se consultaron sin modificar filas operativas.

## Estado por las siete etapas

| Etapa | Código | Producción | Estado actual |
|---|---:|---:|---|
| 1. Reglas, clientes y seguridad | 100% | 96% | Cumple en código y RLS. Se corrigieron los privilegios directos excesivos de las tablas. Falta una prueba real de roles con usuarios separados. |
| 2. Supabase, administración, usuarios y turnos | 98% | 90% | Tablas, RPC, roles, perfiles, turnos, apoyo y cuotas están presentes. Faltan comprobaciones E2E con una cuenta real de cada rol. |
| 3. Web de farmacias | 98% | 84% | Build, login, selector de perfil, pedidos, turnos, ajustes, chat, equivalentes y reportes están implementados. Falta confirmar que el último artefacto esté publicado con las variables reales de GitHub. |
| 4. Operación del domiciliario | 98% | 83% | Aceptación, asignación, apoyo general, cruces, navegación, presencia, historial, firma manual y desglose por farmacia están cubiertos. Falta una ejecución real completa desde un teléfono. |
| 5. Chat, tiempo real y avisos | 93% | 45% | Realtime, Service Worker, sonidos, navegación desde aviso y función Edge están preparados. **No cumple aún en segundo plano** porque Supabase no tiene secretos personalizados de Firebase/VAPID configurados y no existe una notificación real verificada. |
| 6. Equivalentes, pagos, cuotas y reportes | 99% | 92% | Equivalente pendiente hasta firma, fecha del servicio, pagos, saldo, consecutivo FN y reportes por farmacia/domiciliario están implementados y las RPC de producción existen. Falta conciliarlos con una operación real firmada. |
| 7. Compilación, publicación y entrega | 82% | 42% | Compila APK/PWA/web y los workflows existen. Falta keystore release, remoto/secrets de GitHub y confirmar publicación final. |

## Correcciones aplicadas

### Base de datos de producción

- Se aplicó la reparación de deriva de cuotas y auditoría de
  `034_repair_production_fee_and_audit_drift.sql`.
- Ahora existen en producción `admin_audit_log`, `courier_fee_payments` y
  `record_courier_fee_payment`.
- `get_courier_fee_summary` y `get_admin_courier_fee_summary` incluyen pagos,
  saldo y validación de rol administrador.
- Se verificó que los reportes de domicilios por farmacia, por domiciliario y
  el detalle conciliable con número de domicilio/equivalente existen en
  producción.
- Se verificó el consecutivo `FN <farmacia> 001` y el trigger que lo asigna.
- Se aplicó `035_harden_authenticated_table_privileges.sql`. Los usuarios
  autenticados ya no tienen privilegios directos de `TRUNCATE`, `TRIGGER` o
  `REFERENCES` sobre las tablas operativas; el chequeo de privilegios peligrosos
  quedó en **0**. Los cambios de estado sensibles siguen pasando por RPC con
  validación de rol.
- No se borró ni reescribió ningún domicilio existente.

### APK y PWA de domiciliarios

- Se movió el aviso de “estás desconectado” para que aparezca inmediatamente en
  la pantalla principal y no quede oculto debajo de la lista.
- Se confirmó que la APK rechaza cuentas de farmacia y solo permite los roles
  operativos autorizados.
- Se sincronizaron los archivos compilados de Flutter con
  `pharmacy_web/public/courier`; antes `main.dart.js` y el bootstrap publicados
  no coincidían con la compilación actual.
- Se corrigió un paréntesis faltante en la selección de domiciliarios de zona o
  de apoyo dentro de `send-push-notification/index.ts`.

### Web de farmacias

- Se volvió a construir la web después de sincronizar la PWA.
- El bundle de documentos se mantiene separado para no bloquear el inicio de
  sesión.
- Las pantallas de pedidos, turnos, ajustes, perfiles y equivalentes quedaron
  cubiertas por el build y las pruebas de interacción disponibles.

## Evidencia ejecutada

- `flutter analyze --no-fatal-infos`: **sin problemas**.
- `flutter test`: **16 pruebas aprobadas**.
- `flutter build apk --release -PallowDebugSigning=true`: **aprobado**.
- APK generada: [app-release.apk](C:/Users/jhers/Documents/Codex/2026-09-15/ne/work/farmanorte_domiciliarios/build/app/outputs/flutter-apk/app-release.apk).
- SHA-256 de esa APK: `6083E77B60EBEA2CC441DF5DF3E0D2520EB84819457F6CD489D8B6851CE9B79E`.
- `flutter build web --release --base-href=/farmanorte-pharmacy-web/courier/`:
  **aprobado**.
- Los seis archivos principales de `build/web` y
  `pharmacy_web/public/courier` quedaron con hash idéntico.
- `npm run build` en `pharmacy_web`: **aprobado**.
- `npm test` en `pharmacy_web`: **6 aprobadas, 1 omitida** porque requiere
  credenciales reales del backend.
- `npm audit --omit=dev`: **0 vulnerabilidades**.
- `node --check pharmacy_web/public/sw.js`: **aprobado**.
- `npx deno check` sobre las cuatro funciones Edge: **aprobado** después de
  corregir `send-push-notification/index.ts`.
- Revisión automática de interfaz con Impeccable: **sin hallazgos**.
- En el proyecto Supabase se verificaron RPC críticas, `SECURITY DEFINER`,
  RLS, columna `assigned_as_support`, reportes y trigger de consecutivos.
- El proyecto Edge muestra las cuatro funciones desplegadas; la función de push
  figura actualizada hace aproximadamente seis horas, pero el panel registra
  cero invocaciones observables.

## Lo que todavía no cumple y por qué no lo marco como corregido

1. **Push en segundo plano:** Supabase muestra cero secretos personalizados.
   Faltan `FIREBASE_SERVICE_ACCOUNT_JSON`,
   `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` y
   `WEB_PUSH_VAPID_SUBJECT`. La sesión de Google/Firebase exige volver a
   autenticarse, por lo que no es seguro inventar ni sustituir esas claves.
2. **Paridad de la función Edge:** el código local ya pasa Deno, pero no puedo
   afirmar que la versión exacta corregida esté desplegada hasta hacer un
   despliegue autenticado y obtener una invocación real.
3. **APK final:** la APK comprobada está firmada con debug porque falta
   `android/key.properties` y una keystore privada de release. Sirve para QA,
   no para entregar como versión final.
4. **Publicación:** este checkout no tiene `git remote` configurado. Tampoco se
   puede comprobar desde aquí que GitHub Actions tenga sus secretos de Supabase,
   Firebase/VAPID y firma Android.
5. **Prueba real:** no hay un teléfono Android físico conectado ni una operación
   real completa que confirme publicar → avisar → aceptar/asignar → entregar →
   firmar → pagar → conciliar ambos reportes.

## Para cerrar el 24% restante

1. Volver a iniciar sesión en Firebase/Google y obtener las claves del proyecto
   `farmanorte-notificaciones`.
2. Guardar las claves privadas solamente en los secretos de Supabase y la VAPID
   pública en la configuración de GitHub Pages.
3. Desplegar de nuevo `send-push-notification` y ejecutar una notificación real
   desde la web de una farmacia hacia un domiciliario.
4. Configurar la keystore privada y generar el APK sin
   `-PallowDebugSigning=true`.
5. Conectar el remoto de GitHub, configurar los secretos de Actions y publicar
   la web/PWA desde el workflow.
6. Hacer una sola prueba de operación con la farmacia real, sin sembrar datos de
   prueba, y revisar que los importes de la farmacia y del domiciliario
   coincidan.

Archivos de corrección relevantes:

- [034_repair_production_fee_and_audit_drift.sql](C:/Users/jhers/Documents/Codex/2026-09-15/ne/work/farmanorte_domiciliarios/supabase/migrations/034_repair_production_fee_and_audit_drift.sql)
- [035_harden_authenticated_table_privileges.sql](C:/Users/jhers/Documents/Codex/2026-09-15/ne/work/farmanorte_domiciliarios/supabase/migrations/035_harden_authenticated_table_privileges.sql)
- [send-push-notification/index.ts](C:/Users/jhers/Documents/Codex/2026-09-15/ne/work/farmanorte_domiciliarios/supabase/functions/send-push-notification/index.ts)
- [main.dart](C:/Users/jhers/Documents/Codex/2026-09-15/ne/work/farmanorte_domiciliarios/lib/main.dart)
