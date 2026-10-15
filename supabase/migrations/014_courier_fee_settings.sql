-- Cuota semanal derivada de los turnos publicados.
-- No guarda valores de demostración: la deuda se calcula con los turnos reales.

create table if not exists public.courier_fee_settings (
  id boolean primary key default true check (id),
  daily_amount numeric(12, 2) not null default 8000
    check (daily_amount >= 0),
  double_shift_surcharge numeric(12, 2) not null default 2000
    check (double_shift_surcharge >= 0),
  updated_at timestamptz not null default now()
);

insert into public.courier_fee_settings (id, daily_amount, double_shift_surcharge)
values (true, 8000, 2000)
on conflict (id) do nothing;

alter table public.courier_fee_settings enable row level security;
revoke all on public.courier_fee_settings from anon;
grant select on public.courier_fee_settings to authenticated;

drop policy if exists courier_fee_settings_read_authenticated
  on public.courier_fee_settings;
create policy courier_fee_settings_read_authenticated
  on public.courier_fee_settings for select to authenticated
  using (true);

create or replace function public.update_courier_fee_settings(
  requested_daily_amount numeric,
  requested_double_shift_surcharge numeric
)
returns public.courier_fee_settings
language plpgsql
security definer
set search_path = public
as $fn$
declare
  updated_row public.courier_fee_settings;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede modificar las cuotas.';
  end if;

  if coalesce(requested_daily_amount, -1) < 0
     or coalesce(requested_double_shift_surcharge, -1) < 0 then
    raise exception 'Los valores de cuota no pueden ser negativos.';
  end if;

  update public.courier_fee_settings
     set daily_amount = requested_daily_amount,
         double_shift_surcharge = requested_double_shift_surcharge,
         updated_at = now()
   where id = true
   returning * into updated_row;

  return updated_row;
end;
$fn$;

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
  daily_amount numeric,
  double_shift_surcharge numeric
)
language sql
stable
security definer
set search_path = public
as $fn$
  with settings as (
    select daily_amount, double_shift_surcharge
      from public.courier_fee_settings
     where id = true
  ), scheduled as (
    select count(distinct s.scheduled_for) as scheduled_days,
           count(*) filter (where s.is_double) as double_shift_count
      from public.shifts s
     where s.courier_id = auth.uid()
       and s.status = 'scheduled'
       and s.scheduled_for >= requested_week_start
       and s.scheduled_for < requested_week_start + 7
  )
  select requested_week_start,
         requested_week_start + 6,
         scheduled.scheduled_days,
         scheduled.double_shift_count,
         scheduled.scheduled_days * settings.daily_amount,
         scheduled.double_shift_count * settings.double_shift_surcharge,
         scheduled.scheduled_days * settings.daily_amount
           + scheduled.double_shift_count * settings.double_shift_surcharge,
         settings.daily_amount,
         settings.double_shift_surcharge
    from scheduled cross join settings;
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
  daily_amount numeric,
  double_shift_surcharge numeric
)
language sql
stable
security definer
set search_path = public
as $fn$
  with settings as (
    select daily_amount, double_shift_surcharge
      from public.courier_fee_settings
     where id = true
  )
  select p.id,
         p.full_name,
         count(distinct s.scheduled_for) filter (where s.id is not null),
         count(s.id) filter (where s.is_double),
         count(distinct s.scheduled_for) filter (where s.id is not null)
           * settings.daily_amount
           + count(s.id) filter (where s.is_double)
           * settings.double_shift_surcharge,
         settings.daily_amount,
         settings.double_shift_surcharge
    from public.profiles p
    cross join settings
    left join public.shifts s
      on s.courier_id = p.id
     and s.status = 'scheduled'
     and s.scheduled_for >= requested_week_start
     and s.scheduled_for < requested_week_start + 7
   where p.role = 'courier'
     and p.active = true
   group by p.id, p.full_name, settings.daily_amount,
            settings.double_shift_surcharge
   order by p.full_name;
$fn$;

grant execute on function public.update_courier_fee_settings(numeric, numeric)
  to authenticated;
grant execute on function public.get_courier_fee_summary(date)
  to authenticated;
grant execute on function public.get_admin_courier_fee_summary(date)
  to authenticated;
