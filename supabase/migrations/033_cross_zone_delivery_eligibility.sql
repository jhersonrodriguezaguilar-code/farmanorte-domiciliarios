-- Permite que un domicilio con cruces se ofrezca y asigne a los turnos de
-- cualquiera de las zonas de las farmacias que forman parte de su recorrido.
-- La fecha operativa se calcula en Colombia; no depende de la zona horaria
-- interna de PostgreSQL. No modifica domicilios ni turnos existentes.

-- Esta columna pertenece al modelo de asignación base/apoyo. Se declara aquí
-- también para instalaciones de producción que no hayan aplicado la migración
-- histórica 020; el valor inicial no altera el estado de ningún domicilio.
alter table public.deliveries
  add column if not exists assigned_as_support boolean not null default false;

create index if not exists deliveries_courier_breakdown_idx
  on public.deliveries (pharmacy_code, accepted_courier_id, status, assigned_as_support);

create or replace function public.delivery_covers_zone(
  requested_delivery_id uuid,
  requested_zone_id uuid
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
    where d.id = requested_delivery_id
      and (
        d.zone_id = requested_zone_id
        or exists (
          select 1
          from (
            select nullif(btrim(d.pharmacy_code), '') as pharmacy_code
            union
            select nullif(btrim(stop_code.value), '')
            from jsonb_array_elements(
              case
                when jsonb_typeof(d.pickup_stops) = 'array' then d.pickup_stops
                else '[]'::jsonb
              end
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
              case
                when jsonb_typeof(d.destination_options) = 'array' then d.destination_options
                else '[]'::jsonb
              end
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
          join public.zone_pharmacies zp
            on zp.pharmacy_code = route_pharmacies.pharmacy_code
          where route_pharmacies.pharmacy_code is not null
            and zp.zone_id = requested_zone_id
        )
      )
  );
$function$;

revoke execute on function public.delivery_covers_zone(uuid, uuid)
  from public, anon, authenticated;

-- La presencia solo informa si el domiciliario está conectado. La cobertura
-- operativa se determina siempre con el turno programado para la fecha de
-- Colombia. Así una sesión conectada no puede sustituir un turno.
create or replace function public.courier_has_zone(requested_zone_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select auth.uid() is not null
    and exists (
      select 1
      from public.shifts s
      where s.courier_id = auth.uid()
        and s.scheduled_for = (now() at time zone 'America/Bogota')::date
        and s.status in ('scheduled', 'active')
        and (
          s.assignment_type = 'support'
          or (
            coalesce(s.assignment_type, 'zone') = 'zone'
            and s.zone_id = requested_zone_id
          )
        )
    );
$function$;

revoke execute on function public.courier_has_zone(uuid)
  from public, anon;
grant execute on function public.courier_has_zone(uuid)
  to authenticated;

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
          or exists (
            select 1
            from public.shifts s
            where s.courier_id = auth.uid()
              and s.scheduled_for = (now() at time zone 'America/Bogota')::date
              and s.status in ('scheduled', 'active')
              and (
                s.assignment_type = 'support'
                or (
                  coalesce(s.assignment_type, 'zone') = 'zone'
                  and public.delivery_covers_zone(d.id, s.zone_id)
                )
              )
          )
        )
    );
$function$;

revoke execute on function public.courier_can_access_delivery(uuid)
  from public, anon;
grant execute on function public.courier_can_access_delivery(uuid)
  to authenticated;

drop policy if exists deliveries_read_relevant on public.deliveries;
create policy deliveries_read_relevant
  on public.deliveries for select to authenticated
  using (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
    or accepted_courier_id = auth.uid()
    or approval_courier_id = auth.uid()
    or public.courier_can_access_delivery(id)
  );

create or replace function public.get_pharmacy_delivery_couriers(
  requested_delivery_id uuid,
  requested_date date default null
)
returns table (
  courier_id uuid,
  full_name text,
  phone text,
  connected boolean,
  scheduled_for date,
  starts_at time,
  ends_at time,
  status text,
  is_double boolean,
  pharmacy_code text,
  assignment_type text,
  is_support boolean,
  zone_id uuid,
  zone_name text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if not (
    public.is_admin()
    or delivery_row.pharmacy_code = public.my_pharmacy_code()
  ) then
    raise exception 'No tienes permiso para consultar los domiciliarios de este domicilio.';
  end if;

  if delivery_row.status not in ('offered', 'accepted') then
    return;
  end if;

  return query
  select eligible.courier_id,
         eligible.full_name,
         eligible.phone,
         eligible.connected,
         eligible.scheduled_for,
         eligible.starts_at,
         eligible.ends_at,
         eligible.status,
         eligible.is_double,
         eligible.pharmacy_code,
         eligible.assignment_type,
         eligible.is_support,
         eligible.zone_id,
         eligible.zone_name
  from (
    select distinct on (s.courier_id)
           s.courier_id,
           p.full_name,
           p.phone,
           coalesce(cp.connected, false) as connected,
           s.scheduled_for,
           s.starts_at,
           s.ends_at,
           s.status,
           s.is_double,
           case when s.assignment_type = 'support' then null else s.pharmacy_code end as pharmacy_code,
           coalesce(s.assignment_type, 'zone') as assignment_type,
           s.assignment_type = 'support' as is_support,
           s.zone_id,
           z.name as zone_name
    from public.shifts s
    join public.profiles p on p.id = s.courier_id
    left join public.courier_presence cp on cp.courier_id = s.courier_id
    left join public.zones z on z.id = s.zone_id
    where s.scheduled_for = coalesce(
      requested_date,
      (now() at time zone 'America/Bogota')::date
    )
      and s.status in ('scheduled', 'active')
      and p.role = 'courier'
      and p.active = true
      and (
        s.assignment_type = 'support'
        or (
          coalesce(s.assignment_type, 'zone') = 'zone'
          and public.delivery_covers_zone(delivery_row.id, s.zone_id)
        )
      )
    order by s.courier_id,
             (s.assignment_type = 'support'),
             coalesce(cp.connected, false) desc,
             s.starts_at
  ) eligible
  order by eligible.is_support,
           eligible.connected desc,
           eligible.starts_at,
           eligible.full_name;
end;
$function$;

revoke execute on function public.get_pharmacy_delivery_couriers(uuid, date)
  from public, anon;
grant execute on function public.get_pharmacy_delivery_couriers(uuid, date)
  to authenticated;

create or replace function public.assign_delivery_to_courier(
  requested_delivery_id uuid,
  requested_courier_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
  courier_row public.profiles%rowtype;
  previous_courier_id uuid;
  has_zone_shift boolean;
  has_support_shift boolean;
  support_assignment boolean;
begin
  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id
  for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if not (
    public.is_admin()
    or delivery_row.pharmacy_code = public.my_pharmacy_code()
  ) then
    raise exception 'No tienes permiso para reasignar este domicilio.';
  end if;

  if delivery_row.status not in ('offered', 'accepted') then
    raise exception 'Solo se puede reasignar un domicilio publicado o aceptado.';
  end if;

  select * into courier_row
  from public.profiles p
  where p.id = requested_courier_id
    and p.role = 'courier'
    and p.active = true;

  if not found then
    raise exception 'El domiciliario seleccionado no está activo.';
  end if;

  select exists (
    select 1 from public.shifts s
    where s.courier_id = requested_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and public.delivery_covers_zone(delivery_row.id, s.zone_id)
  ), exists (
    select 1 from public.shifts s
    where s.courier_id = requested_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and s.assignment_type = 'support'
  )
  into has_zone_shift, has_support_shift;

  if not has_zone_shift and not has_support_shift then
    raise exception 'El domiciliario no cubre ninguna zona del recorrido hoy.';
  end if;

  support_assignment := has_support_shift and not has_zone_shift;
  previous_courier_id := delivery_row.accepted_courier_id;

  update public.deliveries
  set status = 'accepted',
      accepted_courier_id = requested_courier_id,
      assigned_as_support = support_assignment,
      accepted_at = coalesce(accepted_at, now()),
      approval_pending = false,
      approval_courier_id = null,
      approval_courier_name = null,
      updated_at = now()
  where id = requested_delivery_id;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id,
    auth.uid(),
    'courier_assigned_by_pharmacy',
    delivery_row.status,
    'accepted',
    jsonb_build_object(
      'previous_courier_id', previous_courier_id,
      'assigned_courier_id', requested_courier_id,
      'assigned_courier_name', courier_row.full_name,
      'assigned_as_support', support_assignment
    )
  );

  return true;
end;
$function$;

revoke execute on function public.assign_delivery_to_courier(uuid, uuid)
  from public, anon;
grant execute on function public.assign_delivery_to_courier(uuid, uuid)
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

  select exists (
    select 1
    from public.shifts s
    where s.courier_id = auth.uid()
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and public.delivery_covers_zone(delivery_row.id, s.zone_id)
  ), exists (
    select 1
    from public.shifts s
    where s.courier_id = auth.uid()
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and s.assignment_type = 'support'
  ) into has_zone_shift, has_support_shift;

  if requested_as_support and not has_support_shift then
    raise exception 'No tienes un turno de apoyo vigente hoy.';
  end if;
  if not requested_as_support and not has_zone_shift then
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
      'cross_zone_route', delivery_row.cross_count > 0
    )
  );

  return true;
end;
$function$;

revoke execute on function public.accept_delivery(uuid, boolean)
  from public, anon;
grant execute on function public.accept_delivery(uuid, boolean)
  to authenticated;

create or replace function public.request_delivery_approval(
  requested_delivery_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  delivery_row public.deliveries%rowtype;
  courier_name text;
  has_eligible_shift boolean;
  has_active_delivery boolean;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'courier'
      and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede solicitar otro domicilio.';
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
  if delivery_row.approval_pending then
    return true;
  end if;

  select exists (
    select 1 from public.shifts s
    where s.courier_id = auth.uid()
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and (
        s.assignment_type = 'support'
        or (
          coalesce(s.assignment_type, 'zone') = 'zone'
          and public.delivery_covers_zone(delivery_row.id, s.zone_id)
        )
      )
  ) into has_eligible_shift;
  if not has_eligible_shift then
    raise exception 'No tienes un turno vigente en ninguna zona de este recorrido.';
  end if;

  select exists (
    select 1 from public.deliveries d
    where d.accepted_courier_id = auth.uid()
      and d.status in ('accepted', 'pickedUp')
  ) into has_active_delivery;
  if not has_active_delivery then
    raise exception 'Este domicilio se puede aceptar directamente porque no tienes otro activo.';
  end if;

  select p.full_name into courier_name
  from public.profiles p
  where p.id = auth.uid();

  update public.deliveries
  set approval_pending = true,
      approval_courier_id = auth.uid(),
      approval_courier_name = courier_name,
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
    'second_delivery_requested',
    'offered',
    'offered',
    jsonb_build_object('courier_name', courier_name)
  );
  return true;
end;
$function$;

revoke execute on function public.request_delivery_approval(uuid)
  from public, anon;
grant execute on function public.request_delivery_approval(uuid)
  to authenticated;

create or replace function public.approve_delivery_request(
  requested_delivery_id uuid
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

  select * into delivery_row
  from public.deliveries d
  where d.id = requested_delivery_id
  for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;
  if not (
    public.is_admin()
    or delivery_row.pharmacy_code = public.my_pharmacy_code()
  ) then
    raise exception 'No tienes permiso para aprobar este domicilio.';
  end if;
  if not delivery_row.approval_pending
     or delivery_row.approval_courier_id is null
     or delivery_row.status <> 'offered' then
    raise exception 'Este domicilio no tiene una solicitud pendiente.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = delivery_row.approval_courier_id
      and p.role = 'courier'
      and p.active = true
  ) then
    raise exception 'El domiciliario solicitante ya no está activo.';
  end if;

  select exists (
    select 1 from public.shifts s
    where s.courier_id = delivery_row.approval_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and coalesce(s.assignment_type, 'zone') = 'zone'
      and public.delivery_covers_zone(delivery_row.id, s.zone_id)
  ), exists (
    select 1 from public.shifts s
    where s.courier_id = delivery_row.approval_courier_id
      and s.scheduled_for = (now() at time zone 'America/Bogota')::date
      and s.status in ('scheduled', 'active')
      and s.assignment_type = 'support'
  ) into has_zone_shift, has_support_shift;

  if not has_zone_shift and not has_support_shift then
    raise exception 'El domiciliario ya no tiene un turno vigente para este recorrido.';
  end if;
  support_assignment := has_support_shift and not has_zone_shift;

  update public.deliveries
  set status = 'accepted',
      accepted_courier_id = approval_courier_id,
      accepted_at = now(),
      assigned_as_support = support_assignment,
      approval_pending = false,
      approval_courier_id = null,
      approval_courier_name = null,
      updated_at = now()
  where id = requested_delivery_id
    and status = 'offered'
    and approval_pending = true;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id,
    auth.uid(),
    'second_delivery_approved',
    'offered',
    'accepted',
    jsonb_build_object(
      'assigned_courier_id', delivery_row.approval_courier_id,
      'assignment_type', case when support_assignment then 'support' else 'zone' end
    )
  );
  return true;
end;
$function$;

revoke execute on function public.approve_delivery_request(uuid)
  from public, anon;
grant execute on function public.approve_delivery_request(uuid)
  to authenticated;

-- El detalle de un cruce debe poder cargar sus pasos y su auditoría para todo
-- domiciliario elegible de la ruta, no solo para la zona de la farmacia que
-- publicó el domicilio.
drop policy if exists delivery_tasks_read_relevant on public.delivery_tasks;
create policy delivery_tasks_read_relevant
  on public.delivery_tasks for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.deliveries d
      where d.id = delivery_id
        and (
          d.pharmacy_code = public.my_pharmacy_code()
          or d.accepted_courier_id = auth.uid()
          or d.approval_courier_id = auth.uid()
          or public.courier_can_access_delivery(d.id)
        )
    )
  );

drop policy if exists delivery_events_read_relevant on public.delivery_events;
create policy delivery_events_read_relevant
  on public.delivery_events for select to authenticated
  using (
    public.is_admin()
    or actor_id = auth.uid()
    or exists (
      select 1
      from public.deliveries d
      where d.id = delivery_id
        and (
          d.pharmacy_code = public.my_pharmacy_code()
          or d.accepted_courier_id = auth.uid()
          or d.approval_courier_id = auth.uid()
          or public.courier_can_access_delivery(d.id)
        )
    )
  );
