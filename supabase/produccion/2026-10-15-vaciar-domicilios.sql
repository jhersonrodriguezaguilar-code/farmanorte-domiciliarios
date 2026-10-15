-- VACIAR DOMICILIOS EN PRODUCCIÓN (farmanorte-produccion) — 2026-10-15
-- Pedido por la operación: dejar en cero todos los domicilios y sus registros,
-- como si el sistema empezara de nuevo. ES IRREVERSIBLE.
--
-- Qué borra (en cascada desde public.deliveries):
--   deliveries, delivery_events, delivery_tasks (compras y cruces),
--   delivery_chat_messages y delivery_equivalents (incluye las firmas).
-- Qué reinicia: pharmacy_delivery_counters en 0 (el próximo será FN<farmacia>001).
-- Qué NO toca: usuarios, perfiles, farmacias, zonas, turnos, clientes,
--   tokens push, tarifas ni pagos a domiciliarios (ver paso opcional abajo).
--
-- Cómo usarlo: Supabase > SQL Editor > pegar todo > Run. Revisa los conteos
-- del final: todo debe quedar en 0.

-- 1. Conteo antes de borrar (para dejar constancia).
select 'antes' as momento,
  (select count(*) from public.deliveries) as domicilios,
  (select count(*) from public.delivery_tasks) as tareas_y_cruces,
  (select count(*) from public.delivery_events) as eventos,
  (select count(*) from public.delivery_chat_messages) as mensajes,
  (select count(*) from public.delivery_equivalents) as equivalentes;

begin;

-- 2. Borrar domicilios: las tablas hijas se borran en cascada.
delete from public.deliveries;

-- 3. Reiniciar el consecutivo de todas las farmacias.
update public.pharmacy_delivery_counters
set last_number = 0,
    updated_at = now();

-- 4. OPCIONAL: pagos registrados a domiciliarios. Quita los dos guiones de la
--    línea siguiente solo si también quieres borrar esos pagos.
-- delete from public.courier_fee_payments;

commit;

-- 5. Verificación: todo debe dar 0.
select 'despues' as momento,
  (select count(*) from public.deliveries) as domicilios,
  (select count(*) from public.delivery_tasks) as tareas_y_cruces,
  (select count(*) from public.delivery_events) as eventos,
  (select count(*) from public.delivery_chat_messages) as mensajes,
  (select count(*) from public.delivery_equivalents) as equivalentes,
  (select coalesce(max(last_number), 0) from public.pharmacy_delivery_counters) as contador_mayor;
