-- FarmaNorte: consecutivo público compacto, sin espacios.
-- Ejemplo: FN167001.
-- Mantiene compatibilidad con domicilios antiguos que usaran FN 167 001.

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
    btrim(new.pharmacy_code),
    coalesce(
      max(
        case
          when left(d.public_code, length('FN' || btrim(new.pharmacy_code))) =
              'FN' || btrim(new.pharmacy_code)
            and substring(d.public_code from length('FN' || btrim(new.pharmacy_code)) + 1) ~ '^[0-9]+$'
          then substring(d.public_code from length('FN' || btrim(new.pharmacy_code)) + 1)::bigint
          when left(d.public_code, length('FN ' || btrim(new.pharmacy_code) || ' ')) =
              'FN ' || btrim(new.pharmacy_code) || ' '
            and substring(d.public_code from length('FN ' || btrim(new.pharmacy_code) || ' ') + 1) ~ '^[0-9]+$'
          then substring(d.public_code from length('FN ' || btrim(new.pharmacy_code) || ' ') + 1)::bigint
        end
      ),
      0
    ) + 1
  from public.deliveries d
  where btrim(d.pharmacy_code) = btrim(new.pharmacy_code)
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

notify pgrst, 'reload schema';
