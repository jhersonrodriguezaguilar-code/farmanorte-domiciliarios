-- Una cuenta autenticada por farmacia y perfiles operativos internos.
-- Los perfiles se desactivan para conservar el historial; no se eliminan
-- físicamente como parte de la operación normal.

create table if not exists public.pharmacy_profiles (
  id uuid primary key default gen_random_uuid(),
  pharmacy_code text not null references public.pharmacies(code) on delete cascade,
  display_name text not null,
  username text not null,
  profile_role text not null default 'vendedor'
    check (profile_role in ('vendedor', 'cajero')),
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pharmacy_profiles_display_name_not_blank
    check (length(btrim(display_name)) > 0),
  constraint pharmacy_profiles_username_not_blank
    check (length(btrim(username)) > 0)
);

create unique index if not exists pharmacy_profiles_username_unique
  on public.pharmacy_profiles (pharmacy_code, lower(username));

create index if not exists pharmacy_profiles_pharmacy_active_idx
  on public.pharmacy_profiles (pharmacy_code, active, display_name);

drop trigger if exists pharmacy_profiles_touch_updated_at on public.pharmacy_profiles;
create trigger pharmacy_profiles_touch_updated_at
before update on public.pharmacy_profiles
for each row execute function public.touch_updated_at();

alter table public.pharmacy_profiles enable row level security;

drop policy if exists pharmacy_profiles_read_relevant on public.pharmacy_profiles;
create policy pharmacy_profiles_read_relevant
  on public.pharmacy_profiles for select to authenticated
  using (public.is_admin() or pharmacy_code = public.my_pharmacy_code());

drop policy if exists pharmacy_profiles_admin_write on public.pharmacy_profiles;
create policy pharmacy_profiles_admin_write
  on public.pharmacy_profiles for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists pharmacy_profiles_pharmacy_update on public.pharmacy_profiles;
create policy pharmacy_profiles_pharmacy_update
  on public.pharmacy_profiles for update to authenticated
  using (public.is_pharmacy_user() and pharmacy_code = public.my_pharmacy_code())
  with check (public.is_pharmacy_user() and pharmacy_code = public.my_pharmacy_code());

grant select, insert, update on table public.pharmacy_profiles to authenticated;
grant select, insert, update, delete on table public.pharmacy_profiles to service_role;

alter table public.deliveries
  add column if not exists pharmacy_profile_id uuid
    references public.pharmacy_profiles(id) on delete set null;

create index if not exists deliveries_pharmacy_profile_idx
  on public.deliveries (pharmacy_profile_id, created_at desc);

create or replace function public.validate_delivery_pharmacy_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_pharmacy_code text;
  profile_active boolean;
begin
  if new.pharmacy_profile_id is null then
    return new;
  end if;

  select pharmacy_code, active
    into profile_pharmacy_code, profile_active
  from public.pharmacy_profiles
  where id = new.pharmacy_profile_id;

  if profile_pharmacy_code is null
     or profile_pharmacy_code <> new.pharmacy_code
     or profile_active is not true then
    raise exception 'El perfil de farmacia no pertenece a la farmacia del domicilio o está inactivo.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists deliveries_validate_pharmacy_profile on public.deliveries;
create trigger deliveries_validate_pharmacy_profile
before insert or update of pharmacy_profile_id, pharmacy_code on public.deliveries
for each row execute function public.validate_delivery_pharmacy_profile();

grant execute on function public.validate_delivery_pharmacy_profile() to authenticated;
