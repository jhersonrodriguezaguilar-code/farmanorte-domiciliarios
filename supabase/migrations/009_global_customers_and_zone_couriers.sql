-- Registro global de clientes y consulta segura de domiciliarios por zona.
-- Se conserva la columna pharmacy_code como dato histórico opcional, pero ya
-- no se utiliza para separar clientes entre farmacias.

alter table public.customers
  add column if not exists document_number_normalized text generated always as (
    regexp_replace(lower(trim(document_number)), '[^a-z0-9]', '', 'g')
  ) stored;

-- Si una instalación ya contiene el mismo documento en varias farmacias,
-- conserva el registro más antiguo y mueve sus direcciones y domicilios al
-- cliente canónico antes de crear la unicidad global.
do $$
declare
  duplicate_row record;
  canonical_id uuid;
begin
  for duplicate_row in
    select document_number_normalized
    from public.customers
    where document_number_normalized <> ''
    group by document_number_normalized
    having count(*) > 1
  loop
    select c.id
      into canonical_id
    from public.customers c
    where c.document_number_normalized = duplicate_row.document_number_normalized
    order by c.created_at, c.id
    limit 1;

    update public.customer_addresses
      set customer_id = canonical_id
    where customer_id in (
      select c.id
      from public.customers c
      where c.document_number_normalized = duplicate_row.document_number_normalized
        and c.id <> canonical_id
    );

    update public.deliveries
      set customer_id = canonical_id
    where customer_id in (
      select c.id
      from public.customers c
      where c.document_number_normalized = duplicate_row.document_number_normalized
        and c.id <> canonical_id
    );

    delete from public.customers
    where document_number_normalized = duplicate_row.document_number_normalized
      and id <> canonical_id;
  end loop;
end;
$$;

alter table public.customers
  alter column pharmacy_code drop not null;

alter table public.customers
  drop constraint if exists customers_pharmacy_code_document_number_key;

create unique index if not exists customers_document_number_global_unique
  on public.customers (document_number_normalized)
  where document_number_normalized <> '';

create index if not exists customers_document_number_normalized_idx
  on public.customers (document_number_normalized);

create or replace function public.is_pharmacy_user()
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
      and role = 'pharmacy'
      and active = true
      and pharmacy_code is not null
  );
$$;

drop policy if exists customers_read_relevant on public.customers;
create policy customers_read_relevant
  on public.customers for select to authenticated
  using (public.is_admin() or public.is_pharmacy_user());

drop policy if exists customers_write_relevant on public.customers;
create policy customers_write_relevant
  on public.customers for all to authenticated
  using (public.is_admin() or public.is_pharmacy_user())
  with check (public.is_admin() or public.is_pharmacy_user());

drop policy if exists customer_addresses_read_relevant on public.customer_addresses;
create policy customer_addresses_read_relevant
  on public.customer_addresses for select to authenticated
  using (public.is_admin() or public.is_pharmacy_user());

drop policy if exists customer_addresses_write_relevant on public.customer_addresses;
create policy customer_addresses_write_relevant
  on public.customer_addresses for all to authenticated
  using (public.is_admin() or public.is_pharmacy_user())
  with check (public.is_admin() or public.is_pharmacy_user());

-- La identidad del cliente es global; el domicilio sigue restringido a la
-- farmacia que lo publica y la dirección debe pertenecer a ese cliente.
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
          and c.active = true
      )
    )
    and (
      requested_address_id is null
      or exists (
        select 1
        from public.customer_addresses a
        where a.id = requested_address_id
          and a.customer_id = requested_customer_id
          and a.active = true
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

-- Una farmacia puede consultar los turnos de toda su zona, incluidos los
-- turnos sin punto base específico (margen izquierda, Granja, etc.).
drop policy if exists shifts_read_relevant on public.shifts;
create policy shifts_read_relevant
  on public.shifts for select to authenticated
  using (
    public.is_admin()
    or courier_id = auth.uid()
    or pharmacy_code = public.my_pharmacy_code()
    or exists (
      select 1
      from public.zone_pharmacies zp
      where zp.zone_id = shifts.zone_id
        and zp.pharmacy_code = public.my_pharmacy_code()
    )
  );

-- La farmacia solo recibe la presencia de domiciliarios que cubren su zona.
drop policy if exists courier_presence_read_own_or_admin on public.courier_presence;
create policy courier_presence_read_own_or_admin
  on public.courier_presence for select to authenticated
  using (
    courier_id = auth.uid()
    or public.is_admin()
    or exists (
      select 1
      from public.zone_pharmacies zp
      where zp.zone_id = courier_presence.zone_id
        and zp.pharmacy_code = public.my_pharmacy_code()
    )
  );

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
  pharmacy_code text
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
    s.pharmacy_code
  from public.shifts s
  join public.profiles p on p.id = s.courier_id
  left join public.courier_presence cp on cp.courier_id = s.courier_id
  where s.zone_id = requested_zone_id
    and s.scheduled_for = coalesce(requested_date, current_date)
    and s.status in ('scheduled', 'active')
    and p.role = 'courier'
    and p.active = true
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
  order by coalesce(cp.connected, false) desc, s.starts_at, p.full_name;
$$;

grant execute on function public.get_pharmacy_zone_couriers(uuid, date)
  to authenticated;

-- Permite refrescar el panel de farmacia cuando se modifica un turno o una
-- conexión, siempre sujeto a las políticas RLS anteriores.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'shifts'
  ) then
    alter publication supabase_realtime add table public.shifts;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'courier_presence'
  ) then
    alter publication supabase_realtime add table public.courier_presence;
  end if;
end;
$$;
