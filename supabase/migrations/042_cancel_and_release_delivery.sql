-- 042: cancelar domicilio (farmacia) y liberar domicilio (domiciliario).
--
-- Pedido por la operación el 2026-10-15:
-- 1. La farmacia puede cancelar un domicilio cuando el cliente ya no lo
--    necesita: publicado, aceptado o en recorrido, con un motivo. Antes solo
--    podía cancelar publicados o aceptados (transition_delivery_status).
-- 2. El domiciliario puede liberar un domicilio que aceptó o le asignaron,
--    si todavía no lo recogió (por ejemplo, tiene muchos pedidos). El pedido
--    del cliente no se cancela: vuelve a publicarse con la regla de
--    prioridad de la 041 (3 min para la zona que pide, luego el resto).
--
-- Es aditiva: agrega columnas y funciones. No modifica filas existentes.

begin;

alter table public.deliveries add column if not exists cancelled_at timestamptz;
alter table public.deliveries add column if not exists cancelled_by uuid references public.profiles(id);
alter table public.deliveries add column if not exists cancellation_reason text;
alter table public.deliveries add column if not exists released_count integer not null default 0;

-- Ventana de una oferta según la regla de la 041: reserva de 3 min para la
-- zona de la farmacia que pide si tiene domiciliario con turno hoy.
create or replace function public.offer_window_for(
  p_pharmacy_code text,
  p_zone_id uuid,
  out priority_until timestamptz,
  out expires_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $function$
declare
  has_home_courier boolean;
begin
  select exists (
    select 1
    from public.shifts s
    join public.profiles p on p.id = s.courier_id
    where s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and s.zone_id = any(public.home_zone_ids(p_pharmacy_code, p_zone_id))
      and p.role = 'courier'
      and p.active = true
  ) into has_home_courier;

  if has_home_courier then
    priority_until := now() + interval '3 minutes';
    expires_at := now() + interval '8 minutes';
  else
    priority_until := now();
    expires_at := now() + interval '5 minutes';
  end if;
end;
$function$;

revoke execute on function public.offer_window_for(text, uuid)
  from public, anon, authenticated;

-- 1. Cancelar (farmacia dueña del domicilio o administrador).
create or replace function public.cancel_delivery(
  requested_delivery_id uuid,
  requested_reason text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
  actor_role text;
  clean_reason text := nullif(btrim(coalesce(requested_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  select p.role::text into actor_role
  from public.profiles p
  where p.id = auth.uid() and p.active = true;
  if actor_role is null then
    raise exception 'El perfil operativo no está activo.';
  end if;

  if clean_reason is null or length(clean_reason) < 3 then
    raise exception 'Escribe el motivo de la cancelación.';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id
  for update;
  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if actor_role = 'pharmacy' then
    if delivery_row.pharmacy_code is distinct from public.my_pharmacy_code() then
      raise exception 'Solo puedes cancelar los domicilios de tu farmacia.';
    end if;
  elsif actor_role <> 'admin' then
    raise exception 'Solo la farmacia o el administrador pueden cancelar un domicilio.';
  end if;

  if delivery_row.status not in ('offered', 'accepted', 'pickedUp') then
    raise exception 'Este domicilio ya terminó y no se puede cancelar.';
  end if;

  update public.deliveries
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = left(clean_reason, 300),
      updated_at = now()
  where id = requested_delivery_id;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'cancelled',
    delivery_row.status, 'cancelled',
    jsonb_build_object(
      'source', 'cancel_delivery_rpc',
      'reason', left(clean_reason, 300),
      'courier_id', delivery_row.accepted_courier_id
    )
  );
  return true;
end;
$function$;

revoke all on function public.cancel_delivery(uuid, text) from public, anon;
grant execute on function public.cancel_delivery(uuid, text) to authenticated;

-- 2. Liberar (el domiciliario asignado, antes de recoger).
create or replace function public.release_delivery(
  requested_delivery_id uuid,
  requested_reason text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
  clean_reason text := nullif(btrim(coalesce(requested_reason, '')), '');
  window_priority timestamptz;
  window_expires timestamptz;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'courier' and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede liberar domicilios.';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id
  for update;
  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if delivery_row.accepted_courier_id is distinct from auth.uid() then
    raise exception 'Este domicilio no está asignado a ti.';
  end if;
  if delivery_row.status <> 'accepted' then
    raise exception 'Solo puedes liberar un domicilio antes de recogerlo.';
  end if;

  select w.priority_until, w.expires_at
  into window_priority, window_expires
  from public.offer_window_for(delivery_row.pharmacy_code, delivery_row.zone_id) w;

  update public.deliveries
  set status = 'offered',
      accepted_courier_id = null,
      accepted_at = null,
      assigned_as_support = false,
      priority_until = window_priority,
      expires_at = window_expires,
      support_notified_at = null,
      released_count = released_count + 1,
      updated_at = now()
  where id = requested_delivery_id;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'released',
    'accepted', 'offered',
    jsonb_build_object(
      'source', 'release_delivery_rpc',
      'reason', left(coalesce(clean_reason, 'Sin motivo'), 300)
    )
  );
  return true;
end;
$function$;

revoke all on function public.release_delivery(uuid, text) from public, anon;
grant execute on function public.release_delivery(uuid, text) to authenticated;

commit;

notify pgrst, 'reload schema';
