-- FarmaNorte · Equivalentes digitales de cada servicio terminado.
-- El equivalente se crea en el servidor al cerrar un domicilio; no es un dato de demostración.

create or replace function public.calculate_delivery_fee(
  requested_service_type text,
  requested_cross_count integer,
  requested_purchase_count integer,
  requested_has_dataphone boolean
)
returns numeric
language plpgsql
immutable
set search_path = public
as $fn$
declare
  has_domicilio boolean := coalesce(requested_service_type, '') like 'Domicilio%';
  cross_count integer := greatest(coalesce(requested_cross_count, 0), 0);
  purchase_count integer := greatest(coalesce(requested_purchase_count, 0), 0);
  dataphone_fee numeric := case when coalesce(requested_has_dataphone, false) then 1000 else 0 end;
begin
  if not has_domicilio then
    return case
      when purchase_count = 1 and cross_count = 0 then 4000 + dataphone_fee
      when cross_count = 1 and purchase_count = 0 then 3000 + dataphone_fee
      else purchase_count * 4000 + cross_count * 3000 + dataphone_fee
    end;
  end if;

  if purchase_count = 0 then
    if cross_count = 0 then return 5000 + dataphone_fee; end if;
    if cross_count = 1 then return 7000 + dataphone_fee; end if;
    if cross_count = 2 then return 9000 + dataphone_fee; end if;
  end if;

  if purchase_count = 1 and cross_count = 0 then return 7000 + dataphone_fee; end if;
  if purchase_count = 1 and cross_count = 1 then return 9000 + dataphone_fee; end if;
  return 5000 + cross_count * 2000 + purchase_count * 2000 + dataphone_fee;
end;
$fn$;

create or replace function public.set_delivery_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if new.courier_earnings is null or new.courier_earnings <= 0 then
    new.courier_earnings := public.calculate_delivery_fee(
      new.service_type,
      new.cross_count,
      new.purchase_count,
      new.has_dataphone
    );
  end if;
  return new;
end;
$fn$;

drop trigger if exists deliveries_set_fee on public.deliveries;
create trigger deliveries_set_fee
before insert or update on public.deliveries
for each row execute function public.set_delivery_fee();

create table if not exists public.delivery_equivalents (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null unique references public.deliveries(id) on delete cascade,
  pharmacy_code text not null references public.pharmacies(code),
  courier_id uuid references public.profiles(id),
  courier_name text,
  service_label text not null,
  description text not null,
  amount numeric(12, 2) not null default 0,
  payment_method text not null default 'none'
    check (payment_method in ('cash', 'card', 'qr', 'none')),
  delivery_status text not null,
  metadata jsonb not null default '{}'::jsonb,
  status text not null default 'draft'
    check (status in ('draft', 'signed', 'acknowledged', 'void')),
  courier_signature_name text,
  courier_signed_at timestamptz,
  pharmacy_acknowledged_by uuid references public.profiles(id),
  pharmacy_acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists delivery_equivalents_pharmacy_created_idx
  on public.delivery_equivalents(pharmacy_code, created_at desc);
create index if not exists delivery_equivalents_courier_created_idx
  on public.delivery_equivalents(courier_id, created_at desc);

drop trigger if exists delivery_equivalents_touch_updated_at on public.delivery_equivalents;
create trigger delivery_equivalents_touch_updated_at
before update on public.delivery_equivalents
for each row execute function public.touch_updated_at();

create or replace function public.create_delivery_equivalent_from_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  courier_display_name text;
  equivalent_description text;
begin
  if new.status not in ('delivered', 'notDelivered') then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status is not distinct from new.status then
    return new;
  end if;

  select full_name
    into courier_display_name
  from public.profiles
  where id = new.accepted_courier_id;

  equivalent_description := case
    when new.status = 'notDelivered' then
      coalesce(nullif(new.delivery_outcome, ''), 'Servicio no entregado')
    else
      coalesce(nullif(new.product_summary, ''), new.service_type)
  end;

  insert into public.delivery_equivalents (
    delivery_id,
    pharmacy_code,
    courier_id,
    courier_name,
    service_label,
    description,
    amount,
    payment_method,
    delivery_status,
    metadata
  ) values (
    new.id,
    new.pharmacy_code,
    new.accepted_courier_id,
    courier_display_name,
    new.service_type,
    equivalent_description,
    coalesce(new.courier_earnings, public.calculate_delivery_fee(
      new.service_type,
      new.cross_count,
      new.purchase_count,
      new.has_dataphone
    )),
    new.payment_method,
    new.status,
    jsonb_build_object(
      'public_code', new.public_code,
      'client_name', new.client_name,
      'client_phone', new.client_phone,
      'neighborhood', new.neighborhood,
      'address', new.address,
      'address_reference', new.address_reference,
      'notes', new.notes,
      'service_type', new.service_type,
      'product_summary', new.product_summary,
      'cross_count', new.cross_count,
      'purchase_count', new.purchase_count,
      'payment_amount', new.payment_amount,
      'cash_expected', new.cash_expected,
      'cash_received', new.cash_received,
      'cash_change', case
        when new.cash_received is null or new.payment_amount is null then null
        else new.cash_received - new.payment_amount
      end,
      'pickup_stops', new.pickup_stops,
      'delivery_outcome', new.delivery_outcome
    )
  )
  on conflict (delivery_id) do update set
    pharmacy_code = excluded.pharmacy_code,
    courier_id = coalesce(public.delivery_equivalents.courier_id, excluded.courier_id),
    courier_name = coalesce(public.delivery_equivalents.courier_name, excluded.courier_name),
    service_label = excluded.service_label,
    description = excluded.description,
    amount = case
      when public.delivery_equivalents.status in ('draft', 'void') then excluded.amount
      else public.delivery_equivalents.amount
    end,
    payment_method = excluded.payment_method,
    delivery_status = excluded.delivery_status,
    metadata = excluded.metadata,
    updated_at = now();

  return new;
end;
$fn$;

drop trigger if exists deliveries_create_equivalent on public.deliveries;
create trigger deliveries_create_equivalent
after insert or update on public.deliveries
for each row execute function public.create_delivery_equivalent_from_delivery();

alter table public.delivery_equivalents enable row level security;
revoke all on public.delivery_equivalents from anon;
grant select on public.delivery_equivalents to authenticated;

drop policy if exists delivery_equivalents_read_relevant on public.delivery_equivalents;
create policy delivery_equivalents_read_relevant
  on public.delivery_equivalents for select to authenticated
  using (
    public.is_admin()
    or pharmacy_code = public.my_pharmacy_code()
    or courier_id = auth.uid()
  );

create or replace function public.sign_delivery_equivalent(
  requested_equivalent_id uuid,
  requested_signature_name text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if length(btrim(coalesce(requested_signature_name, ''))) < 3 then
    raise exception 'La firma debe tener al menos 3 caracteres.';
  end if;

  update public.delivery_equivalents
  set courier_signature_name = btrim(requested_signature_name),
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
$fn$;

create or replace function public.acknowledge_delivery_equivalent(
  requested_equivalent_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.delivery_equivalents as equivalent
  set status = 'acknowledged',
      pharmacy_acknowledged_by = auth.uid(),
      pharmacy_acknowledged_at = now(),
      updated_at = now()
  where equivalent.id = requested_equivalent_id
    and equivalent.status in ('signed', 'draft')
    and (
      public.is_admin()
      or equivalent.pharmacy_code = public.my_pharmacy_code()
    );

  if not found then
    raise exception 'El equivalente no existe o no pertenece a esta farmacia.';
  end if;
  return true;
end;
$fn$;

grant execute on function public.sign_delivery_equivalent(uuid, text) to authenticated;
grant execute on function public.acknowledge_delivery_equivalent(uuid) to authenticated;

do $do$
begin
  alter publication supabase_realtime add table public.delivery_equivalents;
exception
  when duplicate_object then null;
end;
$do$;
