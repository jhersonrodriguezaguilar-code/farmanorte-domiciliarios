-- 046: limita los reportes de ganancias al día operativo actual.
--
-- La fecha se calcula en America/Bogota y se toma de delivered_at, no de
-- created_at. Así un domicilio entregado hoy aparece hoy, aunque haya sido
-- publicado ayer; los días anteriores no se mezclan en el panel diario.
-- La cantidad de entregas sigue contando servicios entregados y la ganancia
-- solo se libera cuando el equivalente está firmado o reconocido.

begin;

create or replace function public.get_pharmacy_courier_breakdown(
  requested_pharmacy_code text
)
returns table (
  courier_id uuid,
  courier_name text,
  service_count bigint,
  total_earnings numeric,
  base_count bigint,
  support_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  clean_pharmacy_code text := btrim(coalesce(requested_pharmacy_code, ''));
begin
  if auth.uid() is null or not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.active = true
      and (
        p.role = 'admin'
        or (p.role = 'pharmacy' and p.pharmacy_code = clean_pharmacy_code)
      )
  ) then
    raise exception 'No tienes permiso para consultar esta farmacia.';
  end if;

  return query
  select
    d.accepted_courier_id,
    coalesce(p.full_name, 'Domiciliario'),
    count(*)::bigint,
    coalesce(sum(
      case when e.status in ('signed', 'acknowledged')
        then coalesce(d.courier_earnings, e.amount, 0)
        else 0
      end
    ), 0)::numeric,
    count(*) filter (where not coalesce(d.assigned_as_support, false))::bigint,
    count(*) filter (where coalesce(d.assigned_as_support, false))::bigint
  from public.deliveries d
  left join public.profiles p on p.id = d.accepted_courier_id
  left join public.delivery_equivalents e on e.delivery_id = d.id
  where d.pharmacy_code = clean_pharmacy_code
    and d.status = 'delivered'
    and d.accepted_courier_id is not null
    and d.delivered_at is not null
    and (d.delivered_at at time zone 'America/Bogota')::date =
      (now() at time zone 'America/Bogota')::date
  group by d.accepted_courier_id, p.full_name
  order by 4 desc, 2;
end;
$fn$;

revoke all on function public.get_pharmacy_courier_breakdown(text)
  from public, anon;
grant execute on function public.get_pharmacy_courier_breakdown(text)
  to authenticated;

create or replace function public.get_pharmacy_courier_deliveries(
  requested_pharmacy_code text
)
returns table (
  delivery_id uuid,
  public_code text,
  client_name text,
  courier_id uuid,
  courier_name text,
  service_type text,
  delivered_at timestamptz,
  courier_earnings numeric,
  released_earnings numeric,
  equivalent_id uuid,
  equivalent_status text,
  equivalent_amount numeric,
  courier_signed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  clean_pharmacy_code text := btrim(coalesce(requested_pharmacy_code, ''));
begin
  if auth.uid() is null or not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.active = true
      and (
        p.role = 'admin'
        or (p.role = 'pharmacy' and p.pharmacy_code = clean_pharmacy_code)
      )
  ) then
    raise exception 'No tienes permiso para consultar estos domicilios.';
  end if;

  return query
  select
    d.id,
    d.public_code,
    d.client_name,
    d.accepted_courier_id,
    coalesce(p.full_name, 'Domiciliario'),
    d.service_type,
    coalesce(d.delivered_at, e.created_at, d.updated_at),
    coalesce(d.courier_earnings, e.amount, 0)::numeric,
    case when e.status in ('signed', 'acknowledged')
      then coalesce(d.courier_earnings, e.amount, 0)
      else 0
    end::numeric,
    e.id,
    e.status,
    e.amount,
    e.courier_signed_at
  from public.deliveries d
  left join public.profiles p on p.id = d.accepted_courier_id
  left join public.delivery_equivalents e on e.delivery_id = d.id
  where d.pharmacy_code = clean_pharmacy_code
    and d.status = 'delivered'
    and d.accepted_courier_id is not null
    and d.delivered_at is not null
    and (d.delivered_at at time zone 'America/Bogota')::date =
      (now() at time zone 'America/Bogota')::date
  order by coalesce(d.delivered_at, e.created_at, d.updated_at) desc,
           d.public_code;
end;
$fn$;

revoke all on function public.get_pharmacy_courier_deliveries(text)
  from public, anon;
grant execute on function public.get_pharmacy_courier_deliveries(text)
  to authenticated;

create or replace function public.get_courier_pharmacy_breakdown()
returns table (
  pharmacy_code text,
  pharmacy_name text,
  service_count bigint,
  total_earnings numeric,
  base_count bigint,
  support_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if auth.uid() is null or not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role = 'courier'
      and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede consultar este resumen.';
  end if;

  return query
  select
    d.pharmacy_code,
    coalesce(ph.name, 'farmanorte ' || d.pharmacy_code),
    count(*)::bigint,
    coalesce(sum(
      case when e.status in ('signed', 'acknowledged')
        then coalesce(d.courier_earnings, e.amount, 0)
        else 0
      end
    ), 0)::numeric,
    count(*) filter (where not coalesce(d.assigned_as_support, false))::bigint,
    count(*) filter (where coalesce(d.assigned_as_support, false))::bigint
  from public.deliveries d
  left join public.pharmacies ph on ph.code = d.pharmacy_code
  left join public.delivery_equivalents e on e.delivery_id = d.id
  where d.accepted_courier_id = auth.uid()
    and d.status = 'delivered'
    and d.delivered_at is not null
    and (d.delivered_at at time zone 'America/Bogota')::date =
      (now() at time zone 'America/Bogota')::date
  group by d.pharmacy_code, ph.name
  order by 4 desc, 2;
end;
$fn$;

revoke all on function public.get_courier_pharmacy_breakdown()
  from public, anon;
grant execute on function public.get_courier_pharmacy_breakdown()
  to authenticated;

commit;

notify pgrst, 'reload schema';
