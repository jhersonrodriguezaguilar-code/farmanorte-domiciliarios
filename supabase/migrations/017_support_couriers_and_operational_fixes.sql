-- FarmaNorte · Etapa operativa · apoyos globales y reasignación controlada.
-- Un turno puede cubrir una zona concreta o actuar como apoyo general para
-- todas las farmacias y zonas durante ese día.

alter table public.shifts
  add column if not exists assignment_type text not null default 'zone';

alter table public.shifts
  alter column zone_id drop not null;

do $$
begin
  alter table public.shifts
    add constraint shifts_assignment_type_check
    check (assignment_type in ('zone', 'support'));
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter table public.shifts
    add constraint shifts_assignment_scope_check
    check (assignment_type = 'support' or zone_id is not null);
exception
  when duplicate_object then null;
end;
$$;

create index if not exists shifts_assignment_type_date_idx
  on public.shifts(assignment_type, scheduled_for, status);

-- Un apoyo activo en su turno puede consultar y aceptar ofertas de cualquier
-- zona. Los demás domiciliarios conservan la restricción de su zona.
create or replace function public.courier_has_zone(requested_zone_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.shifts
    where courier_id = auth.uid()
      and scheduled_for = current_date
      and status in ('scheduled', 'active')
      and (
        assignment_type = 'support'
        or zone_id = requested_zone_id
      )
  ) or exists (
    select 1
    from public.courier_presence
    where courier_id = auth.uid()
      and zone_id = requested_zone_id
      and connected = true
  );
$$;

-- La farmacia ve los domiciliarios de su zona y también todos los apoyos
-- generales programados para la fecha consultada.
drop function if exists public.get_pharmacy_zone_couriers(uuid, date);

create function public.get_pharmacy_zone_couriers(
  requested_zone_id uuid,
  requested_date date default current_date
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
  is_support boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.courier_id,
    p.full_name,
    p.phone,
    coalesce(cp.connected, false) as connected,
    s.scheduled_for,
    s.starts_at,
    s.ends_at,
    s.status,
    s.is_double,
    case when s.assignment_type = 'support' then null else s.pharmacy_code end,
    coalesce(s.assignment_type, 'zone'),
    s.assignment_type = 'support'
  from public.shifts s
  join public.profiles p on p.id = s.courier_id
  left join public.courier_presence cp on cp.courier_id = s.courier_id
  where s.scheduled_for = coalesce(requested_date, current_date)
    and s.status in ('scheduled', 'active')
    and p.role = 'courier'
    and p.active = true
    and (
      s.zone_id = requested_zone_id
      or s.assignment_type = 'support'
    )
    and (
      public.is_admin()
      or (
        public.is_pharmacy_user()
        and exists (
          select 1
          from public.zone_pharmacies zp
          where zp.zone_id = requested_zone_id
            and zp.pharmacy_code = public.my_pharmacy_code()
        )
      )
    )
  order by s.assignment_type = 'support', coalesce(cp.connected, false) desc,
           s.starts_at, p.full_name;
$$;

grant execute on function public.get_pharmacy_zone_couriers(uuid, date)
  to authenticated;

-- Permite que una farmacia o el administrador reasigne un domicilio a un
-- domiciliario elegible de su zona o a un apoyo general. La operación queda
-- auditada y evita que la farmacia tenga que modificar IDs sensibles a mano.
create or replace function public.assign_delivery_to_courier(
  requested_delivery_id uuid,
  requested_courier_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  delivery_row public.deliveries%rowtype;
  courier_row public.profiles%rowtype;
  previous_courier_id uuid;
begin
  select *
    into delivery_row
    from public.deliveries
   where id = requested_delivery_id
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
      and (
        s.assignment_type = 'support'
        or s.zone_id = delivery_row.zone_id
      )
  ) then
    raise exception 'El domiciliario no cubre la zona de este domicilio hoy.';
  end if;

  previous_courier_id := delivery_row.accepted_courier_id;

  update public.deliveries
     set status = 'accepted',
         accepted_courier_id = requested_courier_id,
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
      'assigned_courier_name', courier_row.full_name
    )
  );

  return true;
end;
$$;

grant execute on function public.assign_delivery_to_courier(uuid, uuid)
  to authenticated;

-- La firma visible del equivalente es únicamente la firma dibujada; se
-- conserva el argumento antiguo para no romper APKs anteriores, pero ya no se
-- acepta ni se guarda un nombre escrito por el domiciliario.
create or replace function public.sign_delivery_equivalent_with_image(
  requested_equivalent_id uuid,
  requested_signature_name text,
  requested_signature_image text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(length(btrim(requested_signature_image)), 0) < 100
     or left(btrim(requested_signature_image), 22) <> 'data:image/png;base64,' then
    raise exception 'La firma manuscrita no es válida.';
  end if;

  if length(requested_signature_image) > 1500000 then
    raise exception 'La imagen de la firma es demasiado grande.';
  end if;

  update public.delivery_equivalents
  set courier_signature_name = 'Firma manuscrita',
      courier_signature_image = btrim(requested_signature_image),
      courier_signed_at = now(),
      status = 'signed',
      updated_at = now()
  where id = requested_equivalent_id
    and courier_id = auth.uid()
    and status = 'draft';

  if not found then
    raise exception 'El equivalente no existe, ya fue firmado o no pertenece al domiciliario.';
  end if;
  return true;
end;
$$;

grant execute on function public.sign_delivery_equivalent_with_image(uuid, text, text)
  to authenticated;
