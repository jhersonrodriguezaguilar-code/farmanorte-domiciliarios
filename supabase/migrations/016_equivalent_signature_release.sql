-- FarmaNorte · liberación controlada del equivalente.
-- Un equivalente draft pertenece únicamente al domiciliario y al administrador.
-- La farmacia solo lo puede leer después de la firma manuscrita.

alter table public.delivery_equivalents
  add column if not exists payment_status text not null default 'pending'
    check (payment_status in ('pending', 'paid'));

alter table public.delivery_equivalents
  add column if not exists paid_at timestamptz;

alter table public.delivery_equivalents
  add column if not exists paid_by uuid references public.profiles(id);

alter table public.delivery_equivalents
  add column if not exists paid_amount numeric(12, 2);

create index if not exists delivery_equivalents_payment_status_idx
  on public.delivery_equivalents(payment_status, created_at desc);

-- No se filtran equivalentes pendientes a una cuenta de farmacia.
drop policy if exists delivery_equivalents_read_relevant
  on public.delivery_equivalents;
create policy delivery_equivalents_read_relevant
  on public.delivery_equivalents for select to authenticated
  using (
    public.is_admin()
    or courier_id = auth.uid()
    or (
      status in ('signed', 'acknowledged')
      and pharmacy_code = public.my_pharmacy_code()
    )
  );

-- La farmacia solo puede confirmar un equivalente que ya fue firmado.
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
    and equivalent.status = 'signed'
    and (
      public.is_admin()
      or equivalent.pharmacy_code = public.my_pharmacy_code()
    );

  if not found then
    raise exception 'El equivalente no existe, no está firmado o no pertenece a esta farmacia.';
  end if;
  return true;
end;
$fn$;

grant execute on function public.acknowledge_delivery_equivalent(uuid)
  to authenticated;

-- La confirmación de pago queda separada de la firma y de la recepción.
create or replace function public.mark_delivery_equivalent_paid(
  requested_equivalent_id uuid,
  requested_paid_amount numeric default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.delivery_equivalents as equivalent
  set payment_status = 'paid',
      paid_at = now(),
      paid_by = auth.uid(),
      paid_amount = coalesce(requested_paid_amount, equivalent.amount),
      updated_at = now()
  where equivalent.id = requested_equivalent_id
    and equivalent.status in ('signed', 'acknowledged')
    and (
      public.is_admin()
      or equivalent.pharmacy_code = public.my_pharmacy_code()
    );

  if not found then
    raise exception 'El equivalente debe estar firmado y pertenecer a esta operación.';
  end if;
  return true;
end;
$fn$;

grant execute on function public.mark_delivery_equivalent_paid(uuid, numeric)
  to authenticated;

-- Configuración global para dejar documentado cuándo se liquida el soporte.
alter table public.courier_fee_settings
  add column if not exists equivalent_payment_timing text not null default 'end_of_shift'
    check (equivalent_payment_timing in ('immediate', 'end_of_shift'));

create or replace function public.get_equivalent_payment_timing()
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select equivalent_payment_timing
    from public.courier_fee_settings
   where id = true;
$fn$;

create or replace function public.update_equivalent_payment_timing(
  requested_timing text
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  normalized_timing text := lower(btrim(coalesce(requested_timing, '')));
  saved_timing text;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede modificar la liquidación.';
  end if;

  if normalized_timing not in ('immediate', 'end_of_shift') then
    raise exception 'La liquidación debe ser inmediata o al cierre del turno.';
  end if;

  update public.courier_fee_settings
     set equivalent_payment_timing = normalized_timing,
         updated_at = now()
   where id = true
   returning equivalent_payment_timing into saved_timing;

  return saved_timing;
end;
$fn$;

grant execute on function public.get_equivalent_payment_timing()
  to authenticated;
grant execute on function public.update_equivalent_payment_timing(text)
  to authenticated;
