-- FarmaNorte · Desglose por domiciliario y farmacia.
-- Cada entrega conserva quién la realizó y si fue atendida como base o apoyo.
-- Los resúmenes solo cuentan servicios entregados cuyo equivalente ya fue
-- firmado; así la farmacia y la aplicación usan exactamente la misma cifra.

alter table public.deliveries
  add column if not exists assigned_as_support boolean not null default false;

create index if not exists deliveries_courier_breakdown_idx
  on public.deliveries (pharmacy_code, accepted_courier_id, status, assigned_as_support);

-- Aceptación atómica desde la aplicación. La marca base/apoyo se guarda en la
-- entrega y no se vuelve a inferir después, aunque cambien los turnos.
create or replace function public.accept_delivery(
  requested_delivery_id uuid,
  requested_as_support boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  has_eligible_shift boolean;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'courier'
      and active = true
  ) then
    raise exception 'Solo un domiciliario activo puede aceptar domicilios.';
  end if;

  select *
    into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if delivery_row.status <> 'offered'
     or delivery_row.accepted_courier_id is not null then
    return false;
  end if;

  select exists (
    select 1
    from public.shifts s
    where s.courier_id = auth.uid()
      and s.scheduled_for = current_date
      and s.status in ('scheduled', 'active')
      and (
        (requested_as_support and s.assignment_type = 'support')
        or (
          not requested_as_support
          and s.assignment_type = 'zone'
          and s.zone_id = delivery_row.zone_id
        )
      )
  ) into has_eligible_shift;

  if not has_eligible_shift then
    raise exception 'No tienes un turno válido para esta zona hoy.';
  end if;

  update public.deliveries
     set status = 'accepted',
         accepted_courier_id = auth.uid(),
         assigned_as_support = requested_as_support,
         accepted_at = now(),
         updated_at = now()
   where id = requested_delivery_id
     and status = 'offered'
     and accepted_courier_id is null;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    metadata
  ) values (
    requested_delivery_id,
    auth.uid(),
    'status_changed',
    'offered',
    'accepted',
    jsonb_build_object(
      'source', 'courier_app',
      'assignment_type', case when requested_as_support then 'support' else 'zone' end
    )
  );

  return true;
end;
$fn$;

grant execute on function public.accept_delivery(uuid, boolean) to authenticated;

-- Reasignación desde la página de farmacia. Si el domiciliario no tiene un
-- turno propio para la zona y sí tiene un turno de apoyo, se conserva como
-- apoyo; de lo contrario queda como domiciliario base de esa zona.
create or replace function public.assign_delivery_to_courier(
  requested_delivery_id uuid,
  requested_courier_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  courier_row public.profiles%rowtype;
  previous_courier_id uuid;
  support_assignment boolean;
begin
  select *
    into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if not (public.is_admin() or delivery_row.pharmacy_code = public.my_pharmacy_code()) then
    raise exception 'No tienes permiso para reasignar este domicilio.';
  end if;

  if delivery_row.status not in ('offered', 'accepted') then
    raise exception 'Solo se puede reasignar un domicilio publicado o aceptado.';
  end if;

  select *
    into courier_row
    from public.profiles
   where id = requested_courier_id
     and role = 'courier'
     and active = true;

  if not found then
    raise exception 'El domiciliario seleccionado no está activo.';
  end if;

  if not exists (
    select 1
    from public.shifts s
    where s.courier_id = requested_courier_id
      and s.scheduled_for = current_date
      and s.status in ('scheduled', 'active')
      and (s.assignment_type = 'support' or s.zone_id = delivery_row.zone_id)
  ) then
    raise exception 'El domiciliario no cubre la zona de este domicilio hoy.';
  end if;

  select
    exists (
      select 1
      from public.shifts s
      where s.courier_id = requested_courier_id
        and s.scheduled_for = current_date
        and s.status in ('scheduled', 'active')
        and s.assignment_type = 'support'
    )
    and not exists (
      select 1
      from public.shifts s
      where s.courier_id = requested_courier_id
        and s.scheduled_for = current_date
        and s.status in ('scheduled', 'active')
        and s.assignment_type = 'zone'
        and s.zone_id = delivery_row.zone_id
    )
  into support_assignment;

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
    delivery_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    metadata
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
      'assignment_type', case when support_assignment then 'support' else 'zone' end
    )
  );

  return true;
end;
$fn$;

grant execute on function public.assign_delivery_to_courier(uuid, uuid) to authenticated;

create or replace function public.get_pharmacy_courier_breakdown(
  requested_pharmacy_code text
)
returns table (
  courier_id uuid,
  courier_name text,
  service_count bigint,
  total_earnings numeric,
  base_count bigint,
  support_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not (
    public.is_admin()
    or btrim(coalesce(requested_pharmacy_code, '')) = public.my_pharmacy_code()
  ) then
    raise exception 'No tienes permiso para consultar esta farmacia.';
  end if;

  return query
  select
    d.accepted_courier_id,
    coalesce(p.full_name, 'Domiciliario'),
    count(*)::bigint,
    coalesce(sum(coalesce(d.courier_earnings, 0)), 0)::numeric,
    count(*) filter (where not coalesce(d.assigned_as_support, false))::bigint,
    count(*) filter (where coalesce(d.assigned_as_support, false))::bigint
  from public.deliveries d
  left join public.profiles p on p.id = d.accepted_courier_id
  join public.delivery_equivalents e
    on e.delivery_id = d.id
   and e.status in ('signed', 'acknowledged')
  where d.pharmacy_code = btrim(requested_pharmacy_code)
    and d.status = 'delivered'
    and d.accepted_courier_id is not null
  group by d.accepted_courier_id, p.full_name
  order by total_earnings desc, courier_name;
end;
$fn$;

grant execute on function public.get_pharmacy_courier_breakdown(text) to authenticated;

create or replace function public.get_courier_pharmacy_breakdown()
returns table (
  pharmacy_code text,
  pharmacy_name text,
  service_count bigint,
  total_earnings numeric,
  base_count bigint,
  support_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'courier'
      and active = true
  ) then
    raise exception 'Solo un domiciliario activo puede consultar este resumen.';
  end if;

  return query
  select
    d.pharmacy_code,
    coalesce(ph.name, 'farmanorte ' || d.pharmacy_code),
    count(*)::bigint,
    coalesce(sum(coalesce(d.courier_earnings, 0)), 0)::numeric,
    count(*) filter (where not coalesce(d.assigned_as_support, false))::bigint,
    count(*) filter (where coalesce(d.assigned_as_support, false))::bigint
  from public.deliveries d
  left join public.pharmacies ph on ph.code = d.pharmacy_code
  join public.delivery_equivalents e
    on e.delivery_id = d.id
   and e.status in ('signed', 'acknowledged')
  where d.accepted_courier_id = auth.uid()
    and d.status = 'delivered'
  group by d.pharmacy_code, ph.name
  order by total_earnings desc, pharmacy_name;
end;
$fn$;

grant execute on function public.get_courier_pharmacy_breakdown() to authenticated;
