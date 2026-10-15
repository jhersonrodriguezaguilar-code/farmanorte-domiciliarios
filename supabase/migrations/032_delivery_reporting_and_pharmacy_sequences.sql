-- FarmaNorte: reportes de servicios entregados y consecutivos por farmacia.
-- Las ganancias solo se liberan cuando el equivalente ya fue firmado.
-- El código público queda compacto: FN167001.

create table if not exists public.pharmacy_delivery_counters (
  pharmacy_code text primary key references public.pharmacies(code) on delete cascade,
  last_number bigint not null default 0 check (last_number >= 0),
  updated_at timestamptz not null default now()
);

alter table public.pharmacy_delivery_counters enable row level security;
revoke all on table public.pharmacy_delivery_counters from public, anon, authenticated;

-- Inicializa el contador sin cambiar domicilios existentes. Reconoce el formato
-- compacto nuevo y el formato espaciado anterior para no perder consecutivos.
insert into public.pharmacy_delivery_counters (pharmacy_code, last_number)
select
  p.code,
  coalesce(max(
    case
      when left(d.public_code, length('FN' || p.code)) = 'FN' || p.code
        and substring(d.public_code from length('FN' || p.code) + 1) ~ '^[0-9]+$'
      then substring(d.public_code from length('FN' || p.code) + 1)::bigint
      when left(d.public_code, length('FN ' || p.code || ' ')) = 'FN ' || p.code || ' '
        and substring(d.public_code from length('FN ' || p.code || ' ') + 1) ~ '^[0-9]+$'
      then substring(d.public_code from length('FN ' || p.code || ' ') + 1)::bigint
    end
  ), 0)
from public.pharmacies p
left join public.deliveries d on d.pharmacy_code = p.code
group by p.code
on conflict (pharmacy_code) do update
set last_number = excluded.last_number,
    updated_at = now();

create or replace function public.assign_delivery_public_code()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  next_number bigint;
begin
  if tg_op <> 'INSERT' then
    return new;
  end if;

  if nullif(btrim(new.pharmacy_code), '') is null then
    raise exception 'El domicilio debe tener una farmacia asignada.';
  end if;

  insert into public.pharmacy_delivery_counters (pharmacy_code, last_number)
  select
    new.pharmacy_code,
    coalesce(
      max(
        case
          when left(d.public_code, length('FN' || new.pharmacy_code)) = 'FN' || new.pharmacy_code
            and substring(d.public_code from length('FN' || new.pharmacy_code) + 1) ~ '^[0-9]+$'
          then substring(d.public_code from length('FN' || new.pharmacy_code) + 1)::bigint
          when left(d.public_code, length('FN ' || new.pharmacy_code || ' ')) = 'FN ' || new.pharmacy_code || ' '
            and substring(d.public_code from length('FN ' || new.pharmacy_code || ' ') + 1) ~ '^[0-9]+$'
          then substring(d.public_code from length('FN ' || new.pharmacy_code || ' ') + 1)::bigint
        end
      ),
      0
    ) + 1
  from public.deliveries d
  where d.pharmacy_code = new.pharmacy_code
  on conflict (pharmacy_code) do update
    set last_number = public.pharmacy_delivery_counters.last_number + 1,
        updated_at = now()
  returning last_number into next_number;

  new.public_code := 'FN' || btrim(new.pharmacy_code) ||
    lpad(next_number::text, 3, '0');
  return new;
end;
$fn$;

revoke all on function public.assign_delivery_public_code() from public, anon, authenticated;
drop trigger if exists deliveries_assign_public_code on public.deliveries;
create trigger deliveries_assign_public_code
before insert on public.deliveries
for each row execute function public.assign_delivery_public_code();

create index if not exists deliveries_pharmacy_completed_courier_idx
  on public.deliveries (pharmacy_code, status, accepted_courier_id, delivered_at desc);
create index if not exists delivery_equivalents_delivery_status_idx
  on public.delivery_equivalents (delivery_id, status);

-- El total de servicios representa entregas completadas; el total económico
-- suma únicamente los servicios cuyo equivalente ya se firmó.
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
  order by total_earnings desc, courier_name;
end;
$fn$;

revoke all on function public.get_pharmacy_courier_breakdown(text) from public, anon;
grant execute on function public.get_pharmacy_courier_breakdown(text) to authenticated;

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
  order by total_earnings desc, pharmacy_name;
end;
$fn$;

revoke all on function public.get_courier_pharmacy_breakdown() from public, anon;
grant execute on function public.get_courier_pharmacy_breakdown() to authenticated;

-- Detalle que permite a la farmacia conciliar por repartidor, número de
-- domicilio, equivalente, fecha y ganancia liberada.
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
  order by coalesce(d.delivered_at, e.created_at, d.updated_at) desc, d.public_code;
end;
$fn$;

revoke all on function public.get_pharmacy_courier_deliveries(text) from public, anon;
grant execute on function public.get_pharmacy_courier_deliveries(text) to authenticated;

notify pgrst, 'reload schema';
