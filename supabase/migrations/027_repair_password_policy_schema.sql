-- FarmaNorte · reparación idempotente del esquema de contraseñas temporales.
--
-- La migración 021 ya contiene estas piezas. Este archivo existe para
-- instalaciones en las que las migraciones se aplicaron fuera de orden o la
-- 021 no llegó al proyecto remoto. Es seguro ejecutarlo más de una vez.

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

alter table public.profiles
  add column if not exists password_changed_at timestamptz;

create or replace function public.complete_password_change()
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  update public.profiles
     set must_change_password = false,
         password_changed_at = now(),
         updated_at = now()
   where id = auth.uid()
     and active = true;

  if not found then
    raise exception 'El perfil no existe o está inactivo.';
  end if;
  return true;
end;
$fn$;

grant execute on function public.complete_password_change() to authenticated;
