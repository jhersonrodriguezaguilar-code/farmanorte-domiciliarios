# Etapa 3 · Página web de farmacia

## Objetivo

Entregar una página web estática, preparada para Hostinger, desde la que un usuario autenticado de farmacia publique domicilios reales en Supabase.

## Incluido

- Inicio de sesión real con Supabase Auth.
- Validación de perfil activo con rol `pharmacy` y farmacia asignada.
- Validación de farmacia activa y zona configurada.
- Formulario con cliente, teléfono, barrio, dirección, referencia, pedido, servicio, pago y observaciones.
- Búsqueda de cliente por número de documento dentro de la farmacia.
- Guardado real del cliente y sus múltiples direcciones en Supabase; permite
  seleccionar una dirección existente o registrar otra.
- Oferta con vencimiento de cinco minutos (`expires_at`). La ventana limita la aceptación automática; la farmacia conserva la opción de asignar manualmente después.
- Historial real de la farmacia.
- Actualización Realtime de domicilios de la farmacia.
- Auditoría automática de `INSERT` y `UPDATE` en `delivery_events` mediante trigger de base de datos.
- Bloqueo explícito si faltan variables de entorno o asignación operativa.

## No incluido todavía

- Creación de usuarios desde el navegador.
- Datos de farmacia piloto o domicilios de prueba.
- Chat, llamadas, fotos, GPS y aceptación del domiciliario.
- Despliegue en Hostinger.

La página acepta un nombre de usuario operativo (`nombre.apellido`) o un
correo. Para usuarios creados por el administrador, el backend normaliza el
usuario a un correo técnico interno para Supabase Auth; la página nunca pide un
correo personal.

## Configuración de despliegue

Usar solamente:

```text
VITE_SUPABASE_URL
VITE_SUPABASE_PUBLISHABLE_KEY
```

La clave `service_role` nunca se incluye en la página. Para Hostinger se sube el contenido compilado de `dist/`.
