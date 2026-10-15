-- Recupera equivalentes que falten, conserva la fecha original del servicio y
-- permite firmarlos hasta seis días después de la entrega.

create or replace function public.set_delivery_equivalent_service_date()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  service_date timestamptz;
begin
  select coalesce(d.delivered_at, d.updated_at, d.created_at)
    into service_date
    from public.deliveries d
   where d.id = new.delivery_id;
  if service_date is not null then
    new.created_at := service_date;
  end if;
  return new;
end;
$fn$;

drop trigger if exists delivery_equivalents_set_service_date
  on public.delivery_equivalents;
create trigger delivery_equivalents_set_service_date
before insert on public.delivery_equivalents
for each row execute function public.set_delivery_equivalent_service_date();

-- Mantiene el cierre automático disponible incluso si una instalación tenía
-- el trigger anterior desactivado o faltante.
drop trigger if exists deliveries_create_equivalent on public.deliveries;
create trigger deliveries_create_equivalent
after insert or update on public.deliveries
for each row execute function public.create_delivery_equivalent_from_delivery();

-- Repara los soportes faltantes sin tocar domicilios ni pagos ya registrados.
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
  metadata,
  created_at,
  updated_at
)
select
  d.id,
  d.pharmacy_code,
  d.accepted_courier_id,
  p.full_name,
  d.service_type,
  case
    when d.status = 'notDelivered' then
      coalesce(nullif(d.delivery_outcome, ''), 'Servicio no entregado')
    else coalesce(nullif(d.product_summary, ''), d.service_type)
  end,
  coalesce(
    d.courier_earnings,
    public.calculate_delivery_fee(
      d.service_type,
      d.cross_count,
      d.purchase_count,
      d.has_dataphone
    )
  ),
  d.payment_method,
  d.status,
  jsonb_build_object(
    'public_code', d.public_code,
    'client_name', d.client_name,
    'client_phone', d.client_phone,
    'neighborhood', d.neighborhood,
    'address', d.address,
    'address_reference', d.address_reference,
    'notes', d.notes,
    'service_type', d.service_type,
    'product_summary', d.product_summary,
    'cross_count', d.cross_count,
    'purchase_count', d.purchase_count,
    'payment_amount', d.payment_amount,
    'cash_expected', d.cash_expected,
    'cash_received', d.cash_received,
    'cash_change', case
      when d.cash_received is null or d.payment_amount is null then null
      else d.cash_received - d.payment_amount
    end,
    'pickup_stops', d.pickup_stops,
    'delivery_outcome', d.delivery_outcome
  ),
  coalesce(d.delivered_at, d.updated_at, d.created_at),
  now()
from public.deliveries d
left join public.profiles p on p.id = d.accepted_courier_id
where d.status in ('delivered', 'notDelivered')
  and not exists (
    select 1
    from public.delivery_equivalents e
    where e.delivery_id = d.id
  );

-- Si el cierre no alcanzó a generar el soporte, la app lo puede solicitar de
-- nuevo. El RPC verifica que sea el domicilio entregado del propio repartidor.
create or replace function public.ensure_delivery_equivalent(
  requested_delivery_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  courier_display_name text;
  equivalent_id uuid;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  select *
    into delivery_row
    from public.deliveries d
   where d.id = requested_delivery_id;
  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if not public.is_admin() then
    if not exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.role = 'courier'
        and p.active = true
    ) or delivery_row.accepted_courier_id is distinct from auth.uid() then
      raise exception 'El domicilio no pertenece a este domiciliario.';
    end if;
  end if;

  if delivery_row.status not in ('delivered', 'notDelivered') then
    raise exception 'El equivalente solo está disponible al cerrar el domicilio.';
  end if;

  select p.full_name
    into courier_display_name
    from public.profiles p
   where p.id = delivery_row.accepted_courier_id;

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
    metadata,
    created_at,
    updated_at
  ) values (
    delivery_row.id,
    delivery_row.pharmacy_code,
    delivery_row.accepted_courier_id,
    courier_display_name,
    delivery_row.service_type,
    case
      when delivery_row.status = 'notDelivered' then
        coalesce(nullif(delivery_row.delivery_outcome, ''), 'Servicio no entregado')
      else coalesce(nullif(delivery_row.product_summary, ''), delivery_row.service_type)
    end,
    coalesce(
      delivery_row.courier_earnings,
      public.calculate_delivery_fee(
        delivery_row.service_type,
        delivery_row.cross_count,
        delivery_row.purchase_count,
        delivery_row.has_dataphone
      )
    ),
    delivery_row.payment_method,
    delivery_row.status,
    jsonb_build_object(
      'public_code', delivery_row.public_code,
      'client_name', delivery_row.client_name,
      'client_phone', delivery_row.client_phone,
      'neighborhood', delivery_row.neighborhood,
      'address', delivery_row.address,
      'address_reference', delivery_row.address_reference,
      'notes', delivery_row.notes,
      'service_type', delivery_row.service_type,
      'product_summary', delivery_row.product_summary,
      'cross_count', delivery_row.cross_count,
      'purchase_count', delivery_row.purchase_count,
      'payment_amount', delivery_row.payment_amount,
      'cash_expected', delivery_row.cash_expected,
      'cash_received', delivery_row.cash_received,
      'cash_change', case
        when delivery_row.cash_received is null
          or delivery_row.payment_amount is null then null
        else delivery_row.cash_received - delivery_row.payment_amount
      end,
      'pickup_stops', delivery_row.pickup_stops,
      'delivery_outcome', delivery_row.delivery_outcome
    ),
    coalesce(
      delivery_row.delivered_at,
      delivery_row.updated_at,
      delivery_row.created_at
    ),
    now()
  )
  on conflict (delivery_id) do nothing;

  select e.id
    into equivalent_id
    from public.delivery_equivalents e
   where e.delivery_id = requested_delivery_id;
  return equivalent_id;
end;
$fn$;

revoke all on function public.ensure_delivery_equivalent(uuid)
  from public, anon;
grant execute on function public.ensure_delivery_equivalent(uuid)
  to authenticated;

-- La fecha del recibo corresponde al momento de entrega y no al momento en
-- que el domiciliario termina dibujando la firma.
create or replace function public.sign_delivery_equivalent_with_image(
  requested_equivalent_id uuid,
  requested_signature_name text,
  requested_signature_image text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  service_completed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;
  if coalesce(length(btrim(requested_signature_image)), 0) < 100
     or left(btrim(requested_signature_image), 22) <> 'data:image/png;base64,' then
    raise exception 'La firma manuscrita no es válida.';
  end if;
  if length(requested_signature_image) > 1500000 then
    raise exception 'La imagen de la firma es demasiado grande.';
  end if;

  select coalesce(d.delivered_at, e.created_at)
    into service_completed_at
    from public.delivery_equivalents e
    join public.deliveries d on d.id = e.delivery_id
   where e.id = requested_equivalent_id
     and e.courier_id = auth.uid()
     and e.status = 'draft'
     and e.delivery_status in ('delivered', 'notDelivered')
   for update of e;

  if not found then
    raise exception 'El equivalente no existe, ya fue firmado o no pertenece al domiciliario.';
  end if;
  if service_completed_at is null
     or now() > service_completed_at + interval '6 days' then
    raise exception 'El plazo para firmar este equivalente venció (6 días desde la entrega).';
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
    raise exception 'El equivalente ya fue actualizado.';
  end if;
  return true;
end;
$fn$;

revoke all on function public.sign_delivery_equivalent_with_image(uuid, text, text)
  from public, anon;
grant execute on function public.sign_delivery_equivalent_with_image(uuid, text, text)
  to authenticated;
