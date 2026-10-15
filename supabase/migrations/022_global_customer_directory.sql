-- FarmaNorte · Etapa 1/3 · director global de clientes.
-- El documento queda opcional. La operación actual identifica por teléfono,
-- nombre y dirección; el documento podrá añadirse después sin bloquear el flujo.

alter table public.customers
  alter column document_number drop not null;

create index if not exists customers_phone_global_idx
  on public.customers(phone, active, created_at);

create or replace function public.upsert_customer_contact(
  requested_name text,
  requested_phone text,
  requested_address text
)
returns table (
  customer_id uuid,
  customer_address_id uuid,
  matched_existing boolean
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  normalized_name text := btrim(coalesce(requested_name, ''));
  normalized_phone text := regexp_replace(coalesce(requested_phone, ''), '[^0-9]', '', 'g');
  normalized_address text := btrim(coalesce(requested_address, ''));
  found_customer public.customers%rowtype;
  found_address public.customer_addresses%rowtype;
  matched boolean := false;
begin
  if not (public.is_admin() or public.is_pharmacy_user()) then
    raise exception 'Solo una farmacia o un administrador puede guardar clientes.';
  end if;
  if length(normalized_name) < 2 then
    raise exception 'El nombre del cliente es obligatorio.';
  end if;
  if normalized_phone !~ '^3[0-9]{9}$' then
    raise exception 'El teléfono debe empezar por 3 y tener 10 números.';
  end if;
  if length(normalized_address) < 8 then
    raise exception 'La dirección completa es obligatoria.';
  end if;

  select c.*
    into found_customer
    from public.customers c
   where c.active = true
     and c.phone = normalized_phone
     and lower(btrim(concat_ws(' ', c.first_name, c.last_name))) = lower(normalized_name)
   order by c.created_at, c.id
   limit 1;

  if found_customer.id is null then
    insert into public.customers (
      pharmacy_code,
      document_number,
      first_name,
      last_name,
      phone,
      active,
      created_by
    ) values (
      null,
      null,
      normalized_name,
      '',
      normalized_phone,
      true,
      auth.uid()
    ) returning * into found_customer;
  else
    matched := true;
  end if;

  select a.*
    into found_address
    from public.customer_addresses a
   where a.customer_id = found_customer.id
     and a.active = true
     and lower(btrim(a.address)) = lower(normalized_address)
   order by a.is_default desc, a.created_at
   limit 1;

  if found_address.id is null then
    insert into public.customer_addresses (
      customer_id,
      label,
      neighborhood,
      address,
      address_reference,
      is_default,
      active
    ) values (
      found_customer.id,
      'Dirección registrada',
      normalized_address,
      normalized_address,
      '',
      not exists (
        select 1 from public.customer_addresses a
         where a.customer_id = found_customer.id
           and a.active = true
      ),
      true
    ) returning * into found_address;
  end if;

  return query select found_customer.id, found_address.id, matched;
end;
$fn$;

grant execute on function public.upsert_customer_contact(text, text, text)
  to authenticated;

