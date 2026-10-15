-- 038: registro seguro del token push del dispositivo.
--
-- ESTADO: preparada, NO aplicada en producción. Revisar y aprobar antes de
-- ejecutarla. Es aditiva: agrega una columna opcional y una función; no
-- modifica ni borra filas existentes.
--
-- Problema que corrige:
-- 1. push_tokens.token es UNIQUE y la política RLS solo permite tocar filas
--    propias. Si un teléfono cambia de usuario (otro domiciliario inicia
--    sesión en el mismo equipo), el upsert del cliente choca con la fila del
--    usuario anterior y falla en silencio: el nuevo usuario no recibe push.
-- 2. El servidor no sabía qué sonido eligió el domiciliario, por lo que no
--    podía enviar el push al canal Android de ese sonido.

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
