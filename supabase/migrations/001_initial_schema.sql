-- FarmaNorte · Etapa 1 · esquema inicial del piloto FN 155
-- Ejecutar en el SQL Editor del proyecto Supabase.

create extension if not exists pgcrypto;

create type public.app_role as enum ('admin', 'pharmacy', 'courier');

create table public.pharmacies (
  code text primary key,
  name text not null,
  zone_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.app_role not null,
  pharmacy_code text references public.pharmacies(code),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.zone_pharmacies (
  zone_id uuid not null references public.zones(id) on delete cascade,
  pharmacy_code text not null references public.pharmacies(code) on delete cascade,
  primary key (zone_id, pharmacy_code)
);

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  courier_id uuid not null references public.profiles(id) on delete cascade,
  pharmacy_code text not null references public.pharmacies(code),
  zone_id uuid not null references public.zones(id),
  scheduled_for date not null,
  starts_at time not null,
  ends_at time not null,
  is_double boolean not null default false,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'active', 'completed', 'absent', 'cancelled')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.courier_presence (
  courier_id uuid primary key references public.profiles(id) on delete cascade,
  connected boolean not null default false,
  base_pharmacy_code text references public.pharmacies(code),
  zone_id uuid references public.zones(id),
  latitude double precision,
  longitude double precision,
  accuracy double precision,
  heading double precision,
  speed double precision,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  public_code text unique,
  pharmacy_code text not null references public.pharmacies(code),
  zone_id uuid references public.zones(id),
  kind text not null default 'pharmacyToHome',
  service_type text not null default 'Domicilio normal',
  status text not null default 'offered'
    check (status in ('offered', 'accepted', 'pickedUp', 'delivered', 'notDelivered', 'cancelled', 'expired')),
  client_name text not null,
  client_phone text not null,
  neighborhood text not null,
  address text not null,
  address_reference text not null,
  notes text,
  product_summary text not null,
  payment_method text not null check (payment_method in ('cash', 'card', 'qr')),
  payment_amount numeric(12, 2) not null default 0,
  cash_expected numeric(12, 2),
  cash_received numeric(12, 2),
  total_to_collect numeric(12, 2),
  courier_earnings numeric(12, 2),
  distance_km numeric(8, 2),
  estimated_minutes integer,
  cross_count integer not null default 0,
  purchase_count integer not null default 0,
  change_of_money boolean not null default false,
  has_dataphone boolean not null default false,
  origin_latitude double precision,
  origin_longitude double precision,
  destination_latitude double precision,
  destination_longitude double precision,
  pickup_stops jsonb not null default '[]'::jsonb,
  destination_options jsonb not null default '[]'::jsonb,
  approval_pending boolean not null default false,
  approval_courier_id uuid references public.profiles(id),
  approval_courier_name text,
  accepted_courier_id uuid references public.profiles(id),
  accepted_at timestamptz,
  expires_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  delivery_outcome text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.delivery_events (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  event_type text not null,
  from_status text,
  to_status text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('android', 'ios', 'web')),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create index deliveries_status_zone_expiry_idx
  on public.deliveries(status, zone_id, expires_at);
create index delivery_events_delivery_created_idx
  on public.delivery_events(delivery_id, created_at);
create index shifts_courier_date_idx
  on public.shifts(courier_id, scheduled_for);
create index courier_presence_connected_zone_idx
  on public.courier_presence(connected, zone_id);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
before update on public.profiles
for each row execute function public.touch_updated_at();

create trigger shifts_touch_updated_at
before update on public.shifts
for each row execute function public.touch_updated_at();

create trigger courier_presence_touch_updated_at
before update on public.courier_presence
for each row execute function public.touch_updated_at();

create trigger deliveries_touch_updated_at
before update on public.deliveries
for each row execute function public.touch_updated_at();

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and active = true
  );
$$;

create or replace function public.my_pharmacy_code()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select pharmacy_code
  from public.profiles
  where id = auth.uid()
    and active = true
  limit 1;
$$;

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
      and zone_id = requested_zone_id
      and scheduled_for = current_date
      and status in ('scheduled', 'active')
  ) or exists (
    select 1
    from public.courier_presence
    where courier_id = auth.uid()
      and zone_id = requested_zone_id
      and connected = true
  );
$$;

alter table public.pharmacies enable row level security;
alter table public.zones enable row level security;
alter table public.profiles enable row level security;
alter table public.zone_pharmacies enable row level security;
alter table public.shifts enable row level security;
alter table public.courier_presence enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_events enable row level security;
alter table public.push_tokens enable row level security;

create policy pharmacies_read_authenticated
  on public.pharmacies for select to authenticated using (true);
create policy pharmacies_admin_write
  on public.pharmacies for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy zones_read_authenticated
  on public.zones for select to authenticated using (true);
create policy zones_admin_write
  on public.zones for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy profiles_read_own_or_admin
  on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
-- Los perfiles no se pueden autoelevar. El primer administrador se crea
-- mediante SQL seguro después de crear su usuario en Auth; los demás perfiles
-- los crea un administrador o el flujo administrativo del backend.
create policy profiles_admin_insert
  on public.profiles for insert to authenticated
  with check (public.is_admin());
create policy profiles_admin_update
  on public.profiles for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy zone_pharmacies_read_authenticated
  on public.zone_pharmacies for select to authenticated using (true);
create policy zone_pharmacies_admin_write
  on public.zone_pharmacies for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy shifts_read_relevant
  on public.shifts for select to authenticated
  using (
    public.is_admin()
    or courier_id = auth.uid()
    or pharmacy_code = public.my_pharmacy_code()
  );
create policy shifts_admin_write
  on public.shifts for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy courier_presence_read_own_or_admin
  on public.courier_presence for select to authenticated
  using (courier_id = auth.uid() or public.is_admin());
create policy courier_presence_write_own_or_admin
  on public.courier_presence for all to authenticated
  using (courier_id = auth.uid() or public.is_admin())
  with check (courier_id = auth.uid() or public.is_admin());

create policy deliveries_read_relevant
  on public.deliveries for select to authenticated
  using (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
    or accepted_courier_id = auth.uid()
    or approval_courier_id = auth.uid()
    or public.courier_has_zone(zone_id)
  );
create policy deliveries_create_pharmacy_or_admin
  on public.deliveries for insert to authenticated
  with check (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
  );
create policy deliveries_update_relevant
  on public.deliveries for update to authenticated
  using (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
    or accepted_courier_id = auth.uid()
    or approval_courier_id = auth.uid()
    or public.courier_has_zone(zone_id)
  )
  with check (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
    or accepted_courier_id = auth.uid()
    or approval_courier_id = auth.uid()
    or public.courier_has_zone(zone_id)
  );

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
          or public.courier_has_zone(d.zone_id)
        )
    )
  );
create policy delivery_events_insert_relevant
  on public.delivery_events for insert to authenticated
  with check (
    actor_id = auth.uid()
    and (
      public.is_admin()
      or exists (
        select 1
        from public.deliveries d
        where d.id = delivery_id
          and (
            d.pharmacy_code = public.my_pharmacy_code()
            or d.accepted_courier_id = auth.uid()
            or public.courier_has_zone(d.zone_id)
          )
      )
    )
  );

create policy push_tokens_read_own_or_admin
  on public.push_tokens for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy push_tokens_write_own_or_admin
  on public.push_tokens for all to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

-- Habilita la suscripción .stream() de la aplicación para los domicilios.
alter publication supabase_realtime add table public.deliveries;
