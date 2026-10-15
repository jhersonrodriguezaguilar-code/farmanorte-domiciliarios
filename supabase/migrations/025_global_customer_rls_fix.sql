-- FarmaNorte · Etapa 1 · hacer operativo el directorio global de clientes.
-- 022 dejó el contrato del directorio, pero la tabla histórica conservaba
-- pharmacy_code NOT NULL y sus políticas solo veían clientes de una farmacia.
-- Esta migración corrige ambos puntos sin abrir escrituras libres al público.

alter table public.customers
  alter column pharmacy_code drop not null;

drop policy if exists customers_read_relevant on public.customers;
create policy customers_read_relevant
  on public.customers for select to authenticated
  using (
    public.is_admin()
    or pharmacy_code is null
    or pharmacy_code = public.my_pharmacy_code()
  );

drop policy if exists customers_write_relevant on public.customers;
create policy customers_write_relevant
  on public.customers for all to authenticated
  using (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
  )
  with check (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
  );

drop policy if exists customer_addresses_read_relevant
  on public.customer_addresses;
create policy customer_addresses_read_relevant
  on public.customer_addresses for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
        from public.customers c
       where c.id = customer_id
         and (
           c.pharmacy_code is null
           or c.pharmacy_code = public.my_pharmacy_code()
         )
    )
  );

drop policy if exists customer_addresses_write_relevant
  on public.customer_addresses;
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
as $fn$
  select
    (
      requested_customer_id is null
      or exists (
        select 1
          from public.customers c
         where c.id = requested_customer_id
           and c.active = true
           and (
             c.pharmacy_code is null
             or c.pharmacy_code = requested_pharmacy_code
           )
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
           and c.active = true
           and (
             c.pharmacy_code is null
             or c.pharmacy_code = requested_pharmacy_code
           )
      )
    );
$fn$;

grant execute on function public.delivery_customer_matches(text, uuid, uuid)
  to authenticated;
