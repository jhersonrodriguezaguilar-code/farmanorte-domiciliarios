# Notificaciones push de la APK: diagnóstico y corrección (2026-10-15)

## Causa raíz confirmada en la APK 0.20.6+28

1. El reductor de recursos de la compilación release eliminó
   `drawable/ic_notification` y todos los sonidos `res/raw`. Sin el ícono,
   `flutter_local_notifications.initialize()` falla (`invalid_icon`), el error
   quedaba oculto y por eso:
   - no se creaban los canales,
   - no se registraban `onMessage`, `onMessageOpenedApp` ni `getInitialMessage`,
   - el manejador en segundo plano no mostraba nada.
2. La Edge Function envía `click_action: FLUTTER_NOTIFICATION_CLICK`, pero
   `MainActivity` no declaraba ese filtro: tocar la notificación no abría la app.
3. Los canales `farmanorte_operations_v2` / `farmanorte_messages_v2` ya creados
   en los teléfonos quedaron con un sonido inexistente y Android no permite
   corregir un canal.
4. En segundo plano se habrían mostrado dos notificaciones (la del sistema y
   una local duplicada).
5. En Android se pedía el permiso dos veces seguidas; si el usuario lo negaba,
   no había forma de volver a activarlo desde la app.

## Cambios en la APK 0.20.7+29 (código local, sin publicar)

- `android/app/src/main/res/raw/keep.xml`: conserva el ícono, el color y los
  sonidos.
- Sonidos nuevos en `res/raw`: `delivery_alert`, `koiroylers_shop_notification`,
  `akshai_orders_notification`.
- `AndroidManifest.xml`: filtro `FLUTTER_NOTIFICATION_CLICK`, ícono/color por
  defecto y canal por defecto `fn_new_delivery_fast_ping_v3`.
- Canales v3: `fn_new_delivery_<sonido>_v3`, `fn_assigned_<sonido>_v3`,
  `fn_chat_v3` y `fn_silent_v3`. Se eliminan los v2.
- Escuchas FCM registradas antes e independientes de las notificaciones locales.
- Sin duplicado en segundo plano; en primer plano suena una sola vez por
  domicilio (push o tiempo real, el que llegue primero).
- Permiso: una sola solicitud en Android, se vuelve a comprobar al volver a la
  app y, si está negado, se muestra un aviso con el botón **Activar** que abre
  los ajustes de notificaciones. También aparece en Menú → Configuración →
  Alertas y sonido.
- El token FCM se registra aunque el permiso esté pendiente.
- Si el domicilio de la notificación ya no está disponible, se avisa en lugar
  de quedar esperando.

## Cambios de backend preparados (NO aplicados)

- `supabase/migrations/038_push_token_registration.sql`: columna opcional
  `push_tokens.alert_sound` y RPC `register_push_token` que reasigna el token
  cuando el teléfono cambia de usuario. La APK usa la RPC si existe y, si no,
  el upsert anterior.
- `supabase/functions/send-push-notification/index.ts`: canal v3 por tipo y
  por sonido elegido, sin `click_action`, cuerpo con código compacto y
  farmacia, `message_id` y `pharmacy_code` en los datos, TTL de 10 minutos.

Mientras no se despliegue la función, los push en segundo plano usan el canal
por defecto (sonido fast ping) para los tres tipos. La APK nueva ya distingue el
tipo al mostrar la alerta en primer plano y al abrir la notificación.

## Validación pendiente

Compilar y probar en un teléfono Android real:

```
dart format lib/main.dart
flutter analyze
flutter test
flutter build apk --release -PallowDebugSigning=true ^
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
```

Comprobar dentro del APK: `res/raw` con los 5 sonidos, `ic_notification`,
versión 0.20.7 (29) y el filtro `FLUTTER_NOTIFICATION_CLICK`.

En el teléfono:
1. Instalar sobre la versión anterior, abrir la app: aparece el diálogo de
   permiso (Android 13+).
2. Iniciar sesión: el token aparece/actualiza en `push_tokens`.
3. Con turno del día y la app en segundo plano, publicar un domicilio real
   desde la web: llega la notificación con sonido.
4. Tocarla: abre el detalle del domicilio.
5. Asignar un domicilio directamente: llega "Nuevo domicilio asignado".
6. Mensaje de chat desde la farmacia: llega la notificación y abre el chat.
7. Cambiar el sonido en Configuración y repetir con la app abierta.

Nota: la función solo notifica a domiciliarios con turno programado para el
día (o de apoyo). Sin turnos del día, `send-push-notification` responde
`no_recipients` y no se envía ningún push.
