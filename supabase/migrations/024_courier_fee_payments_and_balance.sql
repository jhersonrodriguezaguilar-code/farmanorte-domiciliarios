-- FarmaNorte · Etapa 6 · liquidación real de cuotas.
-- Registra abonos sin borrar turnos ni modificar el historial operativo.

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
revoke all on public.courier_fee_payments from anon;
grant select on public.courier_fee_payments to authenticated;

drop policy if exists courier_fee_payments_read_relevant
  on public.courier_fee_payments;
create policy courier_fee_payments_read_relevant
  on public.courier_fee_payments for select to authenticated
  using (public.is_admin() or courier_id = auth.uid());

create or replace function public.record_courier_fee_payment(
  requested_courier_id uuid,
  requested_week_start date,
  requested_amount numeric,
  requested_payment_method text default 'cash',
  requested_note text default null
)
returns public.courier_fee_payments
language plpgsql
security definer
set search_path = public
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
    courier_id,
    week_start,
    amount,
    payment_method,
    note,
    recorded_by
  ) values (
    requested_courier_id,
    requested_week_start,
    requested_amount,
    normalized_method,
    nullif(btrim(coalesce(requested_note, '')), ''),
    auth.uid()
  ) returning * into payment_row;

  insert into public.admin_audit_log (
    actor_id,
    action,
    target_user_id,
    metadata
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

grant execute on function public.record_courier_fee_payment(uuid, date, numeric, text, text)
  to authenticated;

-- Mantiene el resumen semanal anterior y añade lo que ya fue abonado y el
-- saldo pendiente. Los turnos cancelados no generan cuota.
drop function if exists public.get_courier_fee_summary(date);
drop function if exists public.get_admin_courier_fee_summary(date);

create or replace function public.get_courier_fee_summary(
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
set search_path = public
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
      select (count(distinct s.scheduled_for))::bigint as scheduled_days,
             (count(*) filter (where s.is_double))::bigint as double_shift_count
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

create or replace function public.get_admin_courier_fee_summary(
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
set search_path = public
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

grant execute on function public.get_courier_fee_summary(date) to authenticated;
grant execute on function public.get_admin_courier_fee_summary(date) to authenticated;
