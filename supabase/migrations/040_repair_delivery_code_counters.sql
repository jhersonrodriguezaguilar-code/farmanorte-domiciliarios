-- 040: el consecutivo sigue después del último número usado.
--
-- Causa (revisada en producción el 2026-10-15): pharmacy_delivery_counters se
-- creó con last_number = 0 para cada farmacia. La función de la 036 solo usa el
-- máximo de los códigos existentes cuando la farmacia NO tiene fila de
-- contador; si la fila existe, suma 1 al contador e ignora los códigos ya
-- emitidos. Por eso la 167, con FN 167 01..08, emitió FN167001.
--
-- Qué cambia:
-- 1. Cada contador queda en el mayor número ya usado por su farmacia, en
--    formato viejo (FN 167 08) o compacto (FN167001). Nunca baja.
-- 2. La función toma siempre el mayor entre contador + 1 y código más alto + 1,
--    así un contador atrasado no puede volver a repetir números.
-- No modifica ningún domicilio: solo la tabla de contadores y la función.

begin;

-- Número usado en un código de esa farmacia, en cualquiera de los dos formatos.
create or replace function public.delivery_code_number(
  p_public_code text,
  p_pharmacy_code text
)
returns bigint
language sql
immutable
set search_path = pg_catalog, public
as $function$
  select case
    when left(p_public_code, length('FN' || btrim(p_pharmacy_code))) = 'FN' || btrim(p_pharmacy_code)
      and substring(p_public_code from length('FN' || btrim(p_pharmacy_code)) + 1) ~ '^[0-9]+$'
    then substring(p_public_code from length('FN' || btrim(p_pharmacy_code)) + 1)::bigint
    when left(p_public_code, length('FN ' || btrim(p_pharmacy_code) || ' ')) = 'FN ' || btrim(p_pharmacy_code) || ' '
      and substring(p_public_code from length('FN ' || btrim(p_pharmacy_code) || ' ') + 1) ~ '^[0-9]+$'
    then substring(p_public_code from length('FN ' || btrim(p_pharmacy_code) || ' ') + 1)::bigint
  end;
$function$;

revoke all on function public.delivery_code_number(text, text) from public, anon, authenticated;

-- 1. Reparar contadores con el mayor número ya emitido (sin bajar ninguno).
update public.pharmacy_delivery_counters c
set last_number = used.max_number,
    updated_at = now()
from (
  select btrim(d.pharmacy_code) as pharmacy_code,
         max(public.delivery_code_number(d.public_code, d.pharmacy_code)) as max_number
  from public.deliveries d
  group by btrim(d.pharmacy_code)
) used
where c.pharmacy_code = used.pharmacy_code
  and used.max_number is not null
  and used.max_number > c.last_number;

-- 2. La función nunca queda por debajo del código más alto ya emitido.
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
    coalesce(max(public.delivery_code_number(d.public_code, new.pharmacy_code)), 0) + 1
  from public.deliveries d
  where btrim(d.pharmacy_code) = btrim(new.pharmacy_code)
  on conflict (pharmacy_code) do update
    set last_number = greatest(
          public.pharmacy_delivery_counters.last_number + 1,
          excluded.last_number
        ),
        updated_at = now()
  returning last_number into next_number;

  new.public_code := 'FN' || btrim(new.pharmacy_code) ||
    lpad(next_number::text, 3, '0');
  return new;
end;
$fn$;

revoke all on function public.assign_delivery_public_code() from public, anon, authenticated;

commit;

-- Verificación: el próximo código de la 167 debe ser FN167009.
select pharmacy_code,
       last_number,
       'FN' || pharmacy_code || lpad((last_number + 1)::text, 3, '0') as proximo_codigo
from public.pharmacy_delivery_counters
where last_number > 0
order by pharmacy_code;
