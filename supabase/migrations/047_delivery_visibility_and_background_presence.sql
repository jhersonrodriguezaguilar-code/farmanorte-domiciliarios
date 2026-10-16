-- FarmaNorte · aceptación única y presencia en segundo plano.
--
-- 1. Un domicilio aceptado solo debe seguir siendo visible para el
--    domiciliario que lo ganó (o para quien tenga una aprobación pendiente).
-- 2. La presencia distingue primer plano, segundo plano y desconectado. Un
--    cliente que pasa a segundo plano no se marca como desconectado de forma
--    inmediata; la fecha de último latido sigue siendo la fuente de verdad.
-- 3. No modifica ni borra domicilios existentes.

begin;

alter table public.courier_presence
  add column if not exists presence_state text not null default 'offline';

do $constraint$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.courier_presence'::regclass
      and conname = 'courier_presence_state_check'
  ) then
    alter table public.courier_presence
      add constraint courier_presence_state_check
      check (presence_state in ('foreground', 'background', 'offline'));
  end if;
end
$constraint$;

create index if not exists courier_presence_state_seen_idx
  on public.courier_presence (presence_state, last_seen_at desc);

create or replace function public.courier_presence_is_fresh(
  requested_courier_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.courier_presence cp
    where cp.courier_id = requested_courier_id
      and cp.connected = true
      and cp.last_seen_at is not null
      and cp.last_seen_at >= now() - case
        when cp.presence_state = 'background' then interval '15 minutes'
        else interval '2 minutes'
      end
  );
$function$;

revoke all on function public.courier_presence_is_fresh(uuid)
  from public, anon;
grant execute on function public.courier_presence_is_fresh(uuid)
  to authenticated;

-- Un domicilio aceptado ya no es una oferta de zona para los demás
-- domiciliarios. El primer RPC que bloquea la fila sigue siendo el ganador.
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
    and not exists (
      select 1
      from public.delivery_offer_declines od
      where od.delivery_id = requested_delivery_id
        and od.courier_id = auth.uid()
    )
    and exists (
      select 1
      from public.deliveries d
      where d.id = requested_delivery_id
        and (
          d.accepted_courier_id = auth.uid()
          or d.approval_courier_id = auth.uid()
          or (
            d.status = 'offered'
            and (
              public.home_shift_covers_delivery(auth.uid(), d.id)
              or (
                (d.priority_until is null or d.priority_until <= now())
                and (
                  public.zone_shift_covers_delivery(auth.uid(), d.id)
                  or public.support_shift_covers_delivery(auth.uid(), d.id)
                )
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

-- Recalcula la presencia con la misma ventana de frescura que la vista de
-- cobertura. Así también se corrige el listado usado al asignar manualmente.
create or replace function public.get_pharmacy_zone_couriers(
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
set search_path = pg_catalog, public
as $function$
  select
    s.courier_id,
    p.full_name,
    p.phone,
    public.courier_presence_is_fresh(s.courier_id) as connected,
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
  order by s.assignment_type = 'support',
           public.courier_presence_is_fresh(s.courier_id) desc,
           s.starts_at,
           p.full_name;
$function$;

grant execute on function public.get_pharmacy_zone_couriers(uuid, date)
  to authenticated;

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
           public.courier_presence_is_fresh(s.courier_id) as connected,
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
             public.courier_presence_is_fresh(s.courier_id) desc,
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

commit;

notify pgrst, 'reload schema';
