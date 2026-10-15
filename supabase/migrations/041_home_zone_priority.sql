-- 041: la reserva de 3 minutos es para la zona de la farmacia que pide.
--
-- Corrige la regla de la 039 (aclarada por la operación el 2026-10-15):
-- Ejemplo: Nirvana (farmanorte 357) pide un cruce que se recoge en la 221, en
-- margen izquierda.
-- 1. Los primeros 3 minutos la oferta es solo para los domiciliarios con turno
--    de zona en la zona de la farmacia que pide (Nirvana).
-- 2. Si nadie la acepta, se habilita para los domiciliarios de las demás zonas
--    del recorrido (margen izquierda) y para los apoyos de esas zonas o
--    generales, con 5 minutos más (8 en total).
-- 3. Si la zona de la farmacia que pide no tiene domiciliario con turno hoy, se
--    habilita de una vez para todos los demás (5 minutos).
--
-- Solo reemplaza funciones. No modifica filas.

begin;

-- Zonas de la farmacia que pide: la zona guardada en el domicilio y las zonas
-- a las que pertenece esa farmacia.
create or replace function public.home_zone_ids(
  p_pharmacy_code text,
  p_zone_id uuid
)
returns uuid[]
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select coalesce(array_agg(distinct zone_id), '{}'::uuid[])
  from (
    select p_zone_id as zone_id where p_zone_id is not null
    union
    select zp.zone_id
    from public.zone_pharmacies zp
    where zp.pharmacy_code = nullif(btrim(p_pharmacy_code), '')
  ) zones;
$function$;

revoke execute on function public.home_zone_ids(text, uuid)
  from public, anon, authenticated;

-- Turno de zona en la zona de la farmacia que pide.
create or replace function public.home_shift_covers_delivery(
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
    from public.deliveries d
    join public.shifts s
      on s.courier_id = requested_courier_id
     and s.scheduled_for = (now() at time zone 'America/Bogota')::date
     and s.status in ('scheduled', 'active')
     and coalesce(s.assignment_type, 'zone') = 'zone'
    where d.id = requested_delivery_id
      and s.zone_id = any(public.home_zone_ids(d.pharmacy_code, d.zone_id))
  );
$function$;

revoke execute on function public.home_shift_covers_delivery(uuid, uuid)
  from public, anon, authenticated;

-- La reserva se fija según los domiciliarios de la zona de la farmacia que pide.
create or replace function public.set_delivery_offer_window()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  has_home_courier boolean;
begin
  if new.status <> 'offered' or new.accepted_courier_id is not null then
    return new;
  end if;

  select exists (
    select 1
    from public.shifts s
    join public.profiles p on p.id = s.courier_id
    where s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and s.zone_id = any(public.home_zone_ids(new.pharmacy_code, new.zone_id))
      and p.role = 'courier'
      and p.active = true
  ) into has_home_courier;

  if has_home_courier then
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

-- Visibilidad: la zona de la farmacia que pide siempre; las demás zonas del
-- recorrido y los apoyos cuando termina la reserva.
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
          or public.home_shift_covers_delivery(auth.uid(), d.id)
          or (
            (d.priority_until is null or d.priority_until <= now())
            and (
              public.zone_shift_covers_delivery(auth.uid(), d.id)
              or public.support_shift_covers_delivery(auth.uid(), d.id)
            )
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
  has_home_shift boolean;
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

  has_home_shift := public.home_shift_covers_delivery(auth.uid(), delivery_row.id);
  has_zone_shift := public.zone_shift_covers_delivery(auth.uid(), delivery_row.id);
  has_support_shift := public.support_shift_covers_delivery(auth.uid(), delivery_row.id);

  -- Durante la reserva solo acepta el domiciliario de la zona que pide.
  if not has_home_shift
     and delivery_row.priority_until is not null
     and delivery_row.priority_until > now() then
    raise exception 'Este domicilio está reservado unos minutos para el domiciliario de la farmacia que lo pide. Si no lo acepta, te llegará el aviso.';
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
      'home_zone', has_home_shift,
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

commit;

notify pgrst, 'reload schema';
