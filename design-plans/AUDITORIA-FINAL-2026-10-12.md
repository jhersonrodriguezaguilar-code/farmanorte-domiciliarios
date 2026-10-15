# Auditoría final de FarmaNorte · siete fases

Fecha: 2026-10-12  
Alcance: aplicación Flutter de domiciliarios, panel administrativo, página de
farmacias, Supabase, chat, notificaciones, equivalentes, cuotas y despliegue.

## Resultado corto

La implementación del alcance acordado quedó cubierta en el código fuente al
95/100. La preparación para una operación real queda en 66/100 porque hay
pasos externos que no se pueden verificar desde este checkout sin una sesión
de despliegue autenticada para Supabase/GitHub, los secretos de Firebase/VAPID,
una keystore de producción y un teléfono físico para la prueba final.

No declaro el producto “100% listo” mientras esas dependencias no estén
verificadas. Marcarlo así sin probarlas ocultaría riesgos reales.

## Estado por fase

| Fase | Código | Producción | Estado | Ya quedó implementado |
|---|---:|---:|---|---|
| 1. Reglas, clientes y seguridad | 100% | 82% | Lista en código | Cliente global opcional, teléfono colombiano de 10 dígitos, documento no obligatorio, RLS compartida entre farmacias, perfiles, contraseñas temporales y bitácora administrativa. |
| 2. Supabase y panel administrativo | 95% | 70% | Lista en código | Roles administrador/domiciliario/farmacia, cuentas de farmacia con perfiles vendedores, desactivación sin borrar historial, restablecimiento de contraseña, turnos, apoyo y cuotas. |
| 3. Página de farmacias | 100% | 74% | Lista en código | Login real, selector de perfil, formulario por operación, clientes y direcciones, pedidos, chat emergente, equivalente, PDF/imagen, turnos semanales por zona y pantalla de ajustes. |
| 4. Operación del domiciliario | 96% | 70% | Lista en código | Aceptación atómica, segundo domicilio con aprobación, apoyo general, reasignación por farmacia, navegación externa a Google Maps, historial, firma manual, desglose por farmacia y presencia con latido de 45 segundos. |
| 5. Chat, tiempo real y avisos | 96% | 55% | Código preparado | Chat Realtime, alerta dentro de la app, Service Worker registrado explícitamente, botón de activación Web Push, renovación y desactivación segura del token, navegación al domicilio/chat desde la notificación, función Edge para FCM/Web Push y sonidos separados. |
| 6. Equivalentes, pagos y cuotas | 98% | 76% | Lista en código | Equivalente pequeño tipo recibo, JR Mensajería Express, FN en mayúscula, fecha/valor/recibo/por concepto/firma/total, firma dibujada, RPC de firma escrita bloqueado, pendiente hasta firmar, pago, cuota diaria, doble turno, abonos y saldo. |
| 7. Compilación, publicación y piloto | 78% | 32% | Pendiente externo | APK compilable, workflow de GitHub Pages, workflow de APK y PWA; faltan remoto GitHub, secretos, firma de producción, migración comprobada y prueba física. |

La media del código de las siete fases es aproximadamente 95%. La media de
entrega real es aproximadamente 66%, porque una funcionalidad no se considera
lista solo por existir en el código: debe estar desplegada, configurada y
probada con un usuario real.

## Verificaciones ejecutadas

- `flutter analyze --no-fatal-infos`: sin problemas.
- `flutter test`: 15 pruebas aprobadas.
- `flutter build apk --release -PallowDebugSigning=true`: aprobado con
  Supabase configurado mediante la URL y la clave pública del proyecto. La APK
  está en `build/app/outputs/flutter-apk/app-release.apk`.
- APK actual de QA (arquitecturas Android incluidas): 64.179.502 bytes.
- SHA-256 actual: `690BDCDC93E9D5C2E4B20744B46311239478330C33B35323BFB9EC45381F8E04`.
- `npm test` en `pharmacy_web`: 6 pruebas aprobadas y 1 omitida porque requiere
  credenciales reales de backend.
- `npm run build`: aprobado. El bundle de documentos quedó separado del
  inicio para que PDF/imagen no bloquee el login.
- `npm audit --omit=dev`: 0 vulnerabilidades.
- `node --check pharmacy_web/public/sw.js`: aprobado.
- Playwright contra `vite preview`: el Service Worker quedó registrado con
  estado `activated` y controlando el origen de la PWA.
- `npx deno check` sobre las cuatro funciones Edge actuales: aprobado.
- Revisión de interfaz con Impeccable: sin hallazgos automáticos.
- No había un teléfono Android físico conectado durante esta auditoría.
- La CLI de Supabase no está instalada en este equipo; las funciones Edge sí
  pasan comprobación estática, pero todavía deben desplegarse y probarse dentro
  del proyecto Supabase activo.

## Qué se corrigió para cerrar el alcance

1. Las transiciones del domicilio ya no se hacen con actualizaciones libres:
   la aceptación, la aprobación del segundo domicilio, la reasignación y los
   cambios de estado pasan por funciones SQL con validación de rol y estado.
2. El chat enviado desde la APK guarda primero el mensaje y luego dispara la
   función de notificación sin bloquear el chat si el proveedor está caído.
3. La página de farmacia muestra los domiciliarios de hoy y una agenda de toda
   la semana, incluyendo los apoyos generales, y tiene vistas separadas para
   publicar, pedidos, turnos y ajustes.
4. Los perfiles de farmacia se conservan como historial: se desactivan, no se
   borran físicamente.
5. La firma del equivalente es solamente manuscrita; escribir un nombre ya no
   sustituye la firma. El soporte no se libera a la farmacia ni suma a las
   ganancias hasta recibir esa firma.
6. La farmacia y el domiciliario consultan el mismo equivalente y el mismo
   desglose contable: base, apoyo, cantidad de domicilios y valor ganado.
7. La APK compilada contiene la configuración pública de Supabase, por lo que
   esta compilación no depende del almacén local de datos de demostración.
8. La presencia del domiciliario se actualiza al entrar, salir, pausar, volver
   y cada 45 segundos. Al pasar a segundo plano se marca como no disponible,
   mientras las alertas push quedan preparadas para seguir funcionando.
9. Los teléfonos de administradores y domiciliarios se validan en cliente y
   servidor: exactamente 10 dígitos y comienzo en 3.

## Lo que todavía impide declarar 100% de producción

Estos puntos no son una falta de código que pueda ocultarse con otra pantalla:

- Aplicar en el proyecto Supabase activo las migraciones 010–026 y comprobar
  que RLS, funciones y tablas coincidan con el código. Las migraciones están en
  `supabase/migrations/` pero no se ejecutaron desde este checkout.
- Desplegar las funciones Edge y configurar en Supabase los secretos de
  Firebase y VAPID. Sin eso, Realtime funciona con la app abierta, pero no se
  puede garantizar el aviso con la app en segundo plano. La web ya quedó
  preparada para pedir el permiso desde `Ajustes`, registrar el token y abrir
  el domicilio/chat; falta comprobar el envío real con los secretos activos.
- Crear una keystore privada de Android y compilar sin
  `-PallowDebugSigning=true`. La APK verificada es de QA con firma debug; no se
  debe distribuir como versión final.
- Conectar este checkout al repositorio GitHub existente y configurar los
  secretos de GitHub Actions para que la web publicada utilice
  `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` y, opcionalmente,
  `VITE_WEB_PUSH_PUBLIC_KEY`. El repositorio remoto existe, pero esta copia
  local no tiene remoto configurado ni una sesión de GitHub autenticada.
- Ejecutar una prueba controlada con una farmacia y un domiciliario reales:
  publicar, recibir aviso, aceptar, reasignar/aprobar segundo domicilio,
  entregar, firmar, recibir el equivalente, registrar pago y comprobar que la
  cifra de ambos perfiles coincide.
- Confirmar que la base real quede en cero de datos ficticios antes del piloto.
  El código no siembra datos falsos en una cuenta Supabase real, pero la
  limpieza de los registros existentes debe hacerse en el proyecto correcto.
- La versión nativa de iOS continúa dependiendo de Apple Developer/macOS. La
  PWA de GitHub Pages es la alternativa inmediata para iPhone.

## Orden exacto para cerrar el último 6% de código y el pendiente de producción

1. Ejecutar migraciones y funciones en Supabase.
2. Configurar Firebase/VAPID y probar notificaciones en Android y navegador.
3. Configurar keystore de producción y generar APK firmada.
4. Conectar el repositorio GitHub, guardar secretos y publicar la web.
5. Hacer la prueba E2E con una farmacia, revisar logs y limpiar la prueba.
6. Entregar solo después de comprobar el checklist anterior.

