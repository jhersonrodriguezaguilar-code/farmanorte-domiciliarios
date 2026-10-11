-- Identificador visible para los usuarios creados por el administrador.
-- Supabase Auth sigue usando un correo técnico interno; el usuario opera con
-- este nombre sin necesidad de tener correo personal.
alter table public.profiles
  add column if not exists username text;

create unique index if not exists profiles_username_unique
  on public.profiles (lower(username))
  where username is not null;

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  pharmacy_code text not null references public.pharmacies(code) on delete cascade,
  document_number text not null,
  first_name text not null,
  last_name text not null default '',
  phone text not null,
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pharmacy_code, document_number)
);

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  label text not null default 'Principal',
  neighborhood text not null,
  address text not null,
  address_reference text not null default '',
  latitude double precision,
  longitude double precision,
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.deliveries
  add column if not exists customer_id uuid references public.customers(id),
  add column if not exists customer_address_id uuid references public.customer_addresses(id);

create index if not exists customers_pharmacy_document_idx
  on public.customers(pharmacy_code, document_number);
create index if not exists customer_addresses_customer_idx
  on public.customer_addresses(customer_id, active);

drop trigger if exists customers_touch_updated_at on public.customers;
create trigger customers_touch_updated_at
before update on public.customers
for each row execute function public.touch_updated_at();

drop trigger if exists customer_addresses_touch_updated_at on public.customer_addresses;
create trigger customer_addresses_touch_updated_at
before update on public.customer_addresses
for each row execute function public.touch_updated_at();

alter table public.customers enable row level security;
alter table public.customer_addresses enable row level security;

revoke all on public.customers from anon, authenticated;
revoke all on public.customer_addresses from anon, authenticated;
grant select, insert, update on public.customers to authenticated;
grant select, insert, update on public.customer_addresses to authenticated;

drop policy if exists customers_read_relevant on public.customers;
create policy customers_read_relevant
  on public.customers for select to authenticated
  using (public.is_admin() or pharmacy_code = public.my_pharmacy_code());
drop policy if exists customers_write_relevant on public.customers;
create policy customers_write_relevant
  on public.customers for all to authenticated
  using (public.is_admin() or pharmacy_code = public.my_pharmacy_code())
  with check (public.is_admin() or pharmacy_code = public.my_pharmacy_code());

drop policy if exists customer_addresses_read_relevant on public.customer_addresses;
create policy customer_addresses_read_relevant
  on public.customer_addresses for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.customers c
      where c.id = customer_id
        and c.pharmacy_code = public.my_pharmacy_code()
    )
  );
drop policy if exists customer_addresses_write_relevant on public.customer_addresses;
create policy customer_addresses_write_relevant
  on public.customer_addresses for all to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.customers c
      where c.id = customer_id
        and c.pharmacy_code = public.my_pharmacy_code()
    )
  )
  with check (
    public.is_admin()
    or exists (
      select 1
      from public.customers c
      where c.id = customer_id
        and c.pharmacy_code = public.my_pharmacy_code()
    )
  );

-- Evita que un cliente o dirección de otra farmacia se inyecte en un domicilio.
create or replace function public.delivery_customer_matches(
  requested_pharmacy_code text,
  requested_customer_id uuid,
  requested_address_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    (
      requested_customer_id is null
      or exists (
        select 1
        from public.customers c
        where c.id = requested_customer_id
          and c.pharmacy_code = requested_pharmacy_code
          and c.active = true
      )
    )
    and (
      requested_address_id is null
      or exists (
        select 1
        from public.customer_addresses a
        join public.customers c on c.id = a.customer_id
        where a.id = requested_address_id
          and a.customer_id = requested_customer_id
          and a.active = true
          and c.pharmacy_code = requested_pharmacy_code
          and c.active = true
      )
    );
$$;

drop policy if exists deliveries_create_pharmacy_or_admin on public.deliveries;
create policy deliveries_create_pharmacy_or_admin
  on public.deliveries for insert to authenticated
  with check (
    (
      public.is_admin()
      or pharmacy_code = public.my_pharmacy_code()
    )
    and public.delivery_customer_matches(
      pharmacy_code,
      customer_id,
      customer_address_id
    )
  );

drop policy if exists deliveries_update_relevant on public.deliveries;
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
    (
      public.is_admin()
      or pharmacy_code = public.my_pharmacy_code()
      or accepted_courier_id = auth.uid()
      or approval_courier_id = auth.uid()
      or public.courier_has_zone(zone_id)
    )
    and public.delivery_customer_matches(
      pharmacy_code,
      customer_id,
      customer_address_id
    )
  );
