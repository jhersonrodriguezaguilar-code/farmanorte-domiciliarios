-- 039: prioridad de la zona antes que el apoyo.
--
-- Regla acordada con la operación (2026-10-15):
-- 1. Al publicarse, la oferta queda 3 minutos reservada para los domiciliarios
--    con turno de zona en cualquiera de las zonas del recorrido (en un cruce,
--    la zona de la farmacia que pide y la de la farmacia de origen).
-- 2. Si nadie la acepta, pasa a los apoyos: los de esas zonas y el apoyo
--    general, con 5 minutos más (8 minutos en total).
-- 3. Si ese día no hay ningún domiciliario de zona con turno en el recorrido,
--    va directo a los apoyos con 5 minutos.
--
-- Es aditiva: agrega una columna y reemplaza funciones. No modifica filas
-- existentes (los domicilios ya publicados quedan con priority_until vacío,
-- que se interpreta como "sin reserva").

alter table public.deliveries
  add column if not exists priority_until timestamptz;

-- Marca el aviso push a los apoyos para enviarlo una sola vez aunque varias
-- pestañas de la farmacia lo pidan al mismo tiempo.
alter table public.deliveries
  add column if not exists support_notified_at timestamptz;

comment on column public.deliveries.priority_until is
  'Hasta esta hora la oferta solo es visible y aceptable para domiciliarios con turno de zona del recorrido. Después pasa a los apoyos.';

-- Zonas del recorrido calculadas desde los valores de la fila. Sirve también
-- dentro de un trigger BEFORE INSERT, cuando la fila todavía no existe.
create or replace function public.route_zone_ids(
  p_pharmacy_code text,
  p_zone_id uuid,
  p_pickup_stops jsonb,
  p_destination_options jsonb
)
returns uuid[]
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select coalesce(array_agg(distinct zone_id), '{}'::uuid[])
  from (
    select p_zone_id as zone_id
    where p_zone_id is not null
    union
    select zp.zone_id
    from (
      select nullif(btrim(p_pharmacy_code), '') as pharmacy_code
      union
      select nullif(btrim(stop_code.value), '')
      from jsonb_array_elements(
        case when jsonb_typeof(p_pickup_stops) = 'array' then p_pickup_stops else '[]'::jsonb end
      ) as pickup_stop(stop)
      cross join lateral unnest(array[
        pickup_stop.stop->>'pharmacy_code',
        pickup_stop.stop->>'pickup_code',
        pickup_stop.stop->>'origin_pharmacy_code',
        pickup_stop.stop->>'originPharmacyCode',
        pickup_stop.stop->>'destination_pharmacy_code',
        pickup_stop.stop->>'destinationPharmacyCode',
        pickup_stop.stop->>'destination_code'
      ]) as stop_code(value)
      union
      select nullif(btrim(option_code.value), '')
      from jsonb_array_elements(
        case when jsonb_typeof(p_destination_options) = 'array' then p_destination_options else '[]'::jsonb end
      ) as destination_option(option)
      cross join lateral unnest(array[
        destination_option.option->>'pharmacy_code',
        destination_option.option->>'origin_pharmacy_code',
        destination_option.option->>'originPharmacyCode',
        destination_option.option->>'destination_pharmacy_code',
        destination_option.option->>'destinationPharmacyCode',
        destination_option.option->>'destination_code'
      ]) as option_code(value)
    ) route_pharmacies
    join public.zone_pharmacies zp on zp.pharmacy_code = route_pharmacies.pharmacy_code
    where route_pharmacies.pharmacy_code is not null
  ) zones;
$function$;

revoke execute on function public.route_zone_ids(text, uuid, jsonb, jsonb)
  from public, anon, authenticated;

-- Fija la ventana de la oferta al publicar. Ignora el vencimiento que envíe la
-- web: la regla vive en el servidor.
create or replace function public.set_delivery_offer_window()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  zones uuid[];
  has_zone_courier boolean;
begin
  if new.status <> 'offered' or new.accepted_courier_id is not null then
    return new;
  end if;

  zones := public.route_zone_ids(
    new.pharmacy_code, new.zone_id, new.pickup_stops, new.destination_options
  );

  select exists (
    select 1
    from public.shifts s
    join public.profiles p on p.id = s.courier_id
    where s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and s.zone_id = any(zones)
      and p.role = 'courier'
      and p.active = true
  ) into has_zone_courier;

  if has_zone_courier then
    new.priority_until := now() + interval '3 minutes';
    new.expires_at := now() + interval '8 minutes';
  else
    new.priority_until := now();
    new.expires_at := now() + interval '5 minutes';
  end if;
  return new;
end;
$function$;

revoke all on function public.set_delivery_offer_window() from public, anon, authenticated;
drop trigger if exists deliveries_set_offer_window on public.deliveries;
create trigger deliveries_set_offer_window
before insert on public.deliveries
for each row execute function public.set_delivery_offer_window();

-- Turno de apoyo que puede atender el domicilio: apoyo general (sin zona) o
-- apoyo de una zona del recorrido.
create or replace function public.support_shift_covers_delivery(
  requested_courier_id uuid,
  requested_delivery_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.shifts s
    where s.courier_id = requested_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and s.assignment_type = 'support'
      and (
        s.zone_id is null
        or public.delivery_covers_zone(requested_delivery_id, s.zone_id)
      )
  );
$function$;

revoke execute on function public.support_shift_covers_delivery(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.zone_shift_covers_delivery(
  requested_courier_id uuid,
  requested_delivery_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.shifts s
    where s.courier_id = requested_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and public.delivery_covers_zone(requested_delivery_id, s.zone_id)
  );
$function$;

revoke execute on function public.zone_shift_covers_delivery(uuid, uuid)
  from public, anon, authenticated;

-- Visibilidad para el domiciliario: zona del recorrido siempre; apoyo solo
-- cuando terminó la reserva de la zona. Lo ya asignado sigue visible.
create or replace function public.courier_can_access_delivery(
  requested_delivery_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select auth.uid() is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.role = 'courier'
        and p.active = true
    )
    and exists (
      select 1
      from public.deliveries d
      where d.id = requested_delivery_id
        and (
          d.accepted_courier_id = auth.uid()
          or d.approval_courier_id = auth.uid()
          or public.zone_shift_covers_delivery(auth.uid(), d.id)
          or (
            (d.priority_until is null or d.priority_until <= now())
            and public.support_shift_covers_delivery(auth.uid(), d.id)
          )
        )
    );
$function$;

revoke execute on function public.courier_can_access_delivery(uuid)
  from public, anon;
grant execute on function public.courier_can_access_delivery(uuid)
  to authenticated;

create or replace function public.accept_delivery(
  requested_delivery_id uuid,
  requested_as_support boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
  has_zone_shift boolean;
  has_support_shift boolean;
  support_assignment boolean;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'courier'
      and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede aceptar domicilios.';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id
  for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if delivery_row.status <> 'offered'
     or delivery_row.accepted_courier_id is not null then
    return false;
  end if;

  if delivery_row.expires_at is not null
     and delivery_row.expires_at <= now() then
    raise exception 'La ventana de aceptación venció. La farmacia todavía puede asignar este domicilio.';
  end if;

  has_zone_shift := public.zone_shift_covers_delivery(auth.uid(), delivery_row.id);
  has_support_shift := public.support_shift_covers_delivery(auth.uid(), delivery_row.id);

  -- Durante la reserva solo acepta el domiciliario de zona del recorrido.
  if not has_zone_shift
     and delivery_row.priority_until is not null
     and delivery_row.priority_until > now() then
    raise exception 'Este domicilio está reservado unos minutos para el domiciliario de la zona. Si no lo acepta, te llegará el aviso.';
  end if;

  if requested_as_support and not has_support_shift then
    raise exception 'No tienes un turno de apoyo vigente para este recorrido.';
  end if;
  if not requested_as_support and not has_zone_shift and not has_support_shift then
    raise exception 'No tienes un turno vigente en ninguna zona de este recorrido.';
  end if;
  support_assignment := has_support_shift and not has_zone_shift;

  update public.deliveries
  set status = 'accepted',
      accepted_courier_id = auth.uid(),
      assigned_as_support = support_assignment,
      accepted_at = now(),
      updated_at = now()
  where id = requested_delivery_id
    and status = 'offered'
    and accepted_courier_id is null;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id,
    auth.uid(),
    'status_changed',
    'offered',
    'accepted',
    jsonb_build_object(
      'source', 'courier_app',
      'assignment_type', case when support_assignment then 'support' else 'zone' end,
      'cross_zone_route', delivery_row.cross_count > 0,
      'within_zone_priority', delivery_row.priority_until is not null and delivery_row.priority_until > now()
    )
  );

  return true;
end;
$function$;

revoke execute on function public.accept_delivery(uuid, boolean)
  from public, anon;
grant execute on function public.accept_delivery(uuid, boolean)
  to authenticated;

notify pgrst, 'reload schema';
