# Auditoría · Etapa 3

Fecha: 2026-10-10  
Estado: **APROBADA COMO BASE WEB REAL; SIN LIBERAR A OPERACIÓN PRODUCTIVA**

## Evidencia ejecutada

- `npm install`: correcto; 79 paquetes auditados, 0 vulnerabilidades reportadas.
- `npm run build`: correcto; Vite generó `dist/`.
- `npm test`: 1 prueba Playwright correcta y 1 prueba condicionada omitida sin configuración real; la pantalla muestra configuración requerida y no datos demo.
- Prueba Playwright con URL y clave pública reales: correcta; llega a la pantalla de acceso de farmacia y no produce errores de página.
- `npm run build`: correcto después de agregar búsqueda por documento y
  direcciones múltiples.
- Prueba Playwright real: correcta; la página configurada llega al login y
  muestra el acceso por usuario o correo.
- Migración `004_usernames_customers.sql` ejecutada en Supabase real sin
  errores; `information_schema` confirmó las columnas esperadas entre
  `customers`, `customer_addresses`, `profiles` y `deliveries`.
- REST sin sesión para `customers`: respondió HTTP 401/permiso denegado; las
  tablas no quedaron expuestas al rol anónimo.
- Verificación de privilegios: `authenticated` tiene `SELECT`, `INSERT` y
  `UPDATE` en `customers` y `customer_addresses`; no tiene `DELETE`,
  `TRUNCATE` ni permisos estructurales, y `anon` no tiene esos privilegios.
- Edge Function de creación de usuarios publicada y protegida; sin sesión
  respondió HTTP 401.
- SQL real de auditoría aplicado en Supabase: correcto.
- Consulta real a `information_schema.triggers`: confirma `deliveries_record_event` para `INSERT` y `UPDATE` sobre `public.deliveries`.
- No se insertaron farmacias, usuarios de farmacia, domicilios ni datos de piloto.

## Revisión funcional

| Área | Resultado |
|---|---|
| Variables públicas y configuración | Correcto |
| Login de farmacia | Correcto en pantalla y conexión real |
| Bloqueo de roles no farmacia | Implementado |
| Validación de farmacia/zona | Implementado |
| Publicación de domicilio | Implementada; requiere perfil farmacia real |
| Clientes por documento y direcciones | Implementado; requiere perfil farmacia real |
| Historial y Realtime | Implementados; requieren perfil/farmacia real |
| Registro de cambios | Verificado en Supabase con trigger real |
| Datos ficticios | No utilizados |
| Despliegue Hostinger | Pendiente |

## No se declara todavía

No se declara el flujo completo de publicación ni el guardado de clientes como probado de extremo a extremo porque todavía no existe una farmacia operativa asignada y el piloto fue aplazado hasta terminar app y página. Crear datos temporales para simularlo contradice el requisito del proyecto.

## Puerta para cerrar la etapa

Antes de marcar la etapa como operación lista se debe crear, mediante el flujo seguro de administración, un usuario de farmacia y asignarlo a una farmacia/zona autorizada. Después se probará una publicación real controlada, la recuperación de un cliente por documento, la selección de una segunda dirección, su aparición Realtime y su evento en `delivery_events`, sin escoger todavía la farmacia piloto si el usuario no la ha definido.
