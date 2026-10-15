-- FarmaNorte · Reparación de deriva de producción · etapas 2 y 6.
--
-- La auditoría de producción encontró que las tablas de bitácora y abonos no
-- estaban creadas, y que get_admin_courier_fee_summary conservaba una versión
-- antigua sin validación de administrador. Esta migración es aditiva: no
-- borra domicilios, turnos, perfiles ni pagos existentes.

create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id),
  action text not null,
  target_user_id uuid references public.profiles(id),
  target_table text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_log_created_idx
  on public.admin_audit_log(created_at desc);
create index if not exists admin_audit_log_target_idx
  on public.admin_audit_log(target_user_id, created_at desc);

alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from anon, authenticated;
grant select on public.admin_audit_log to authenticated;
grant insert on public.admin_audit_log to service_role;

drop policy if exists admin_audit_log_read_admin on public.admin_audit_log;
create policy admin_audit_log_read_admin
  on public.admin_audit_log for select to authenticated
  using (public.is_admin());

create table if not exists public.courier_fee_payments (
  id uuid primary key default gen_random_uuid(),
  courier_id uuid not null references public.profiles(id),
  week_start date not null,
  amount numeric(12, 2) not null check (amount > 0),
  payment_method text not null default 'cash'
    check (payment_method in ('cash', 'transfer', 'other')),
  note text,
  paid_at timestamptz not null default now(),
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint courier_fee_payment_monday check (
    extract(isodow from week_start) = 1
  )
);

create index if not exists courier_fee_payments_courier_week_idx
  on public.courier_fee_payments(courier_id, week_start, paid_at desc);

alter table public.courier_fee_payments enable row level security;
revoke all on public.courier_fee_payments from anon, authenticated;
grant select on public.courier_fee_payments to authenticated;

drop policy if exists courier_fee_payments_read_relevant
  on public.courier_fee_payments;
create policy courier_fee_payments_read_relevant
  on public.courier_fee_payments for select to authenticated
  using (public.is_admin() or courier_id = auth.uid());

drop function if exists public.record_courier_fee_payment(uuid, date, numeric, text, text);
create function public.record_courier_fee_payment(
  requested_courier_id uuid,
  requested_week_start date,
  requested_amount numeric,
  requested_payment_method text default 'cash',
  requested_note text default null
)
returns public.courier_fee_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  payment_row public.courier_fee_payments;
  normalized_method text := lower(btrim(coalesce(requested_payment_method, 'cash')));
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede registrar pagos de cuotas.';
  end if;
  if requested_courier_id is null then
    raise exception 'Selecciona un domiciliario.';
  end if;
  if requested_week_start is null
     or extract(isodow from requested_week_start) <> 1 then
    raise exception 'La semana debe comenzar un lunes.';
  end if;
  if coalesce(requested_amount, 0) <= 0 then
    raise exception 'El abono debe ser mayor que cero.';
  end if;
  if normalized_method not in ('cash', 'transfer', 'other') then
    raise exception 'La forma de pago no es válida.';
  end if;
  if not exists (
    select 1
      from public.profiles p
     where p.id = requested_courier_id
       and p.role = 'courier'
  ) then
    raise exception 'El domiciliario no existe.';
  end if;

  insert into public.courier_fee_payments (
    courier_id, week_start, amount, payment_method, note, recorded_by
  ) values (
    requested_courier_id,
    requested_week_start,
    requested_amount,
    normalized_method,
    nullif(btrim(coalesce(requested_note, '')), ''),
    auth.uid()
  ) returning * into payment_row;

  insert into public.admin_audit_log (
    actor_id, action, target_user_id, metadata
  ) values (
    auth.uid(),
    'courier_fee_payment_recorded',
    requested_courier_id,
    jsonb_build_object(
      'week_start', requested_week_start,
      'amount', requested_amount,
      'payment_method', normalized_method
    )
  );

  return payment_row;
end;
$fn$;

revoke execute on function public.record_courier_fee_payment(uuid, date, numeric, text, text)
  from public, anon;
grant execute on function public.record_courier_fee_payment(uuid, date, numeric, text, text)
  to authenticated;

-- Se recrean ambas RPC porque PostgreSQL no permite cambiar el tipo de retorno
-- de una función con CREATE OR REPLACE. La versión anterior de producción no
-- exponía abonos ni saldo pendiente.
drop function if exists public.get_courier_fee_summary(date);
drop function if exists public.get_admin_courier_fee_summary(date);

create function public.get_courier_fee_summary(
  requested_week_start date
)
returns table (
  week_start date,
  week_end date,
  scheduled_days bigint,
  double_shift_count bigint,
  base_amount numeric,
  double_surcharge numeric,
  total_due numeric,
  total_paid numeric,
  balance_due numeric,
  daily_amount numeric,
  double_shift_surcharge numeric,
  last_payment_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and p.role = 'courier'
       and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede consultar su cuota.';
  end if;

  return query
    with settings as (
      select c.daily_amount, c.double_shift_surcharge
        from public.courier_fee_settings c
       where c.id = true
    ), scheduled as (
      select count(distinct s.scheduled_for)::bigint as scheduled_days,
             count(*) filter (where s.is_double)::bigint as double_shift_count
        from public.shifts s
       where s.courier_id = auth.uid()
         and s.status <> 'cancelled'
         and s.scheduled_for >= requested_week_start
         and s.scheduled_for < requested_week_start + 7
    ), payments as (
      select coalesce(sum(f.amount), 0)::numeric as total_paid,
             max(f.paid_at) as last_payment_at
        from public.courier_fee_payments f
       where f.courier_id = auth.uid()
         and f.week_start = requested_week_start
    )
    select requested_week_start,
           requested_week_start + 6,
           scheduled.scheduled_days,
           scheduled.double_shift_count,
           scheduled.scheduled_days * settings.daily_amount,
           scheduled.double_shift_count * settings.double_shift_surcharge,
           scheduled.scheduled_days * settings.daily_amount
             + scheduled.double_shift_count * settings.double_shift_surcharge,
           payments.total_paid,
           greatest(
             scheduled.scheduled_days * settings.daily_amount
               + scheduled.double_shift_count * settings.double_shift_surcharge
               - payments.total_paid,
             0
           ),
           settings.daily_amount,
           settings.double_shift_surcharge,
           payments.last_payment_at
      from scheduled
      cross join settings
      cross join payments;
end;
$fn$;

create function public.get_admin_courier_fee_summary(
  requested_week_start date
)
returns table (
  courier_id uuid,
  courier_name text,
  scheduled_days bigint,
  double_shift_count bigint,
  total_due numeric,
  total_paid numeric,
  balance_due numeric,
  daily_amount numeric,
  double_shift_surcharge numeric,
  last_payment_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede consultar las cuotas globales.';
  end if;

  return query
    with settings as (
      select c.daily_amount, c.double_shift_surcharge
        from public.courier_fee_settings c
       where c.id = true
    ), scheduled as (
      select p.id as courier_id,
             p.full_name as courier_name,
             (count(distinct s.scheduled_for) filter (where s.id is not null))::bigint as scheduled_days,
             (count(s.id) filter (where s.is_double))::bigint as double_shift_count
        from public.profiles p
        left join public.shifts s
          on s.courier_id = p.id
         and s.status <> 'cancelled'
         and s.scheduled_for >= requested_week_start
         and s.scheduled_for < requested_week_start + 7
       where p.role = 'courier'
         and p.active = true
       group by p.id, p.full_name
    ), payments as (
      select f.courier_id,
             coalesce(sum(f.amount), 0)::numeric as total_paid,
             max(f.paid_at) as last_payment_at
        from public.courier_fee_payments f
       where f.week_start = requested_week_start
       group by f.courier_id
    )
    select scheduled.courier_id,
           scheduled.courier_name,
           scheduled.scheduled_days,
           scheduled.double_shift_count,
           scheduled.scheduled_days * settings.daily_amount
             + scheduled.double_shift_count * settings.double_shift_surcharge,
           coalesce(payments.total_paid, 0),
           greatest(
             scheduled.scheduled_days * settings.daily_amount
               + scheduled.double_shift_count * settings.double_shift_surcharge
               - coalesce(payments.total_paid, 0),
             0
           ),
           settings.daily_amount,
           settings.double_shift_surcharge,
           payments.last_payment_at
      from scheduled
      cross join settings
      left join payments on payments.courier_id = scheduled.courier_id
     order by scheduled.courier_name;
end;
$fn$;

revoke execute on function public.get_courier_fee_summary(date) from public, anon;
revoke execute on function public.get_admin_courier_fee_summary(date) from public, anon;
grant execute on function public.get_courier_fee_summary(date) to authenticated;
grant execute on function public.get_admin_courier_fee_summary(date) to authenticated;
