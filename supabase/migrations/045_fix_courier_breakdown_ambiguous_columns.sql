-- 045: corrige los reportes de ganancias por domiciliario.
--
-- La consulta ordenaba por courier_name/pharmacy_name sin calificarlo. Como
-- esas funciones también devuelven columnas OUT con esos nombres, PostgreSQL
-- podía resolver la referencia contra dos columnas y devolver:
-- "column reference courier_name is ambiguous".
--
-- Se conservan las reglas del reporte:
-- * service_count cuenta domicilios entregados.
-- * total_earnings solo suma domicilios cuyo equivalente está firmado o
--   reconocido por la farmacia.
-- No modifica domicilios ni equivalentes existentes.

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
  group by d.accepted_courier_id, p.full_name
  order by 4 desc, 2;
end;
$fn$;

revoke all on function public.get_pharmacy_courier_breakdown(text)
  from public, anon;
grant execute on function public.get_pharmacy_courier_breakdown(text)
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
