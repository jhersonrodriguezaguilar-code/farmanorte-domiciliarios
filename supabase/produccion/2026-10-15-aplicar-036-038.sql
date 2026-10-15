-- APLICAR EN PRODUCCIÓN (farmanorte-produccion) — 2026-10-15
-- Pegar completo en Supabase > SQL Editor > Run. Es idempotente y no borra ni modifica filas.
-- Incluye: 036 (función + trigger del consecutivo FN167001) y 038 (registro de token push).

begin;

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


alter table public.push_tokens
  add column if not exists alert_sound text;

alter table public.push_tokens
  drop constraint if exists push_tokens_alert_sound_check;
alter table public.push_tokens
  add constraint push_tokens_alert_sound_check
  check (
    alert_sound is null
    or alert_sound in (
      'fast_ping',
      'delivery_alert',
      'message_alert',
      'koiroylers_shop',
      'akshai_orders'
    )
  );

create or replace function public.register_push_token(
  p_token text,
  p_platform text,
  p_alert_sound text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_user uuid := auth.uid();
  v_token text := nullif(btrim(p_token), '');
  v_platform text := case
    when p_platform in ('android', 'ios', 'web') then p_platform
    else null
  end;
  v_sound text := case
    when p_alert_sound in (
      'fast_ping',
      'delivery_alert',
      'message_alert',
      'koiroylers_shop',
      'akshai_orders'
    ) then p_alert_sound
    else null
  end;
begin
  if v_user is null then
    raise exception 'Sesión no válida.' using errcode = '28000';
  end if;
  if v_token is null or length(v_token) > 4096 then
    raise exception 'Token de dispositivo inválido.' using errcode = '22023';
  end if;
  if v_platform is null then
    raise exception 'Plataforma inválida.' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = v_user and active = true
  ) then
    raise exception 'El perfil operativo no está activo.' using errcode = '42501';
  end if;

  -- El token identifica un dispositivo físico: queda asociado al último
  -- usuario que inició sesión en él.
  insert into public.push_tokens (user_id, token, platform, active, alert_sound, updated_at)
  values (v_user, v_token, v_platform, true, v_sound, now())
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        active = true,
        alert_sound = coalesce(excluded.alert_sound, public.push_tokens.alert_sound),
        updated_at = now();
end;
$fn$;

revoke all on function public.register_push_token(text, text, text) from public;
revoke all on function public.register_push_token(text, text, text) from anon;
grant execute on function public.register_push_token(text, text, text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- Verificación: las tres columnas deben dar 1, 1, 1.
select
  (select count(*) from pg_trigger where tgname = 'deliveries_assign_public_code' and tgrelid = 'public.deliveries'::regclass) as trigger_036,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'push_tokens' and column_name = 'alert_sound') as columna_038,
  (select count(*) from pg_proc where proname = 'register_push_token' and pronamespace = 'public'::regnamespace) as funcion_038;
