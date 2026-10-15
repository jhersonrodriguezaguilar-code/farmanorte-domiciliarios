-- FarmaNorte · Etapas 4/5/6 · cierre de firma manuscrita y presencia.
-- La firma escrita quedó disponible en la primera versión de equivalentes. El
-- flujo actual solo acepta una imagen dibujada desde la APK; se revoca el RPC
-- antiguo para que un cliente desactualizado no pueda saltarse esa regla.

revoke all on function public.sign_delivery_equivalent(uuid, text)
  from public, anon, authenticated;

-- Mantiene el nombre en el esquema por compatibilidad con clientes antiguos,
-- pero cualquier intento de usarlo falla de forma explícita. La única ruta
-- válida es sign_delivery_equivalent_with_image(uuid, text, text).
create or replace function public.sign_delivery_equivalent(
  requested_equivalent_id uuid,
  requested_signature_name text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  raise exception 'La firma debe dibujarse manualmente en la pantalla.';
end;
$fn$;

revoke all on function public.sign_delivery_equivalent(uuid, text)
  from public, anon, authenticated;

-- Presencia fiable: si la app deja de enviar latidos, una farmacia no debe
-- seguir mostrando al domiciliario como conectado indefinidamente.
create or replace function public.get_pharmacy_zone_couriers(
  requested_zone_id uuid,
  requested_date date default current_date
)
returns table (
  courier_id uuid,
  full_name text,
  phone text,
  connected boolean,
  scheduled_for date,
  starts_at time,
  ends_at time,
  status text,
  is_double boolean,
  pharmacy_code text,
  assignment_type text,
  is_support boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    s.courier_id,
    p.full_name,
    p.phone,
    (
      coalesce(cp.connected, false)
      and cp.last_seen_at is not null
      and cp.last_seen_at >= now() - interval '2 minutes'
    ) as connected,
    s.scheduled_for,
    s.starts_at,
    s.ends_at,
    s.status,
    s.is_double,
    case when s.assignment_type = 'support' then null else s.pharmacy_code end,
    coalesce(s.assignment_type, 'zone'),
    s.assignment_type = 'support'
  from public.shifts s
  join public.profiles p on p.id = s.courier_id
  left join public.courier_presence cp on cp.courier_id = s.courier_id
  where s.scheduled_for = coalesce(requested_date, current_date)
    and s.status in ('scheduled', 'active')
    and p.role = 'courier'
    and p.active = true
    and (
      s.zone_id = requested_zone_id
      or s.assignment_type = 'support'
    )
    and (
      public.is_admin()
      or (
        public.is_pharmacy_user()
        and exists (
          select 1
          from public.zone_pharmacies zp
          where zp.zone_id = requested_zone_id
            and zp.pharmacy_code = public.my_pharmacy_code()
        )
      )
    )
  order by s.assignment_type = 'support',
           connected desc,
           s.starts_at,
           p.full_name;
$fn$;

grant execute on function public.get_pharmacy_zone_couriers(uuid, date)
  to authenticated;
