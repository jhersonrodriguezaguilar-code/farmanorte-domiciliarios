-- FarmaNorte · Correcciones operativas de turnos.
--
-- RLS sigue limitando las filas al administrador; estos privilegios habilitan
-- las operaciones SQL que el panel autenticado necesita ejecutar.
grant select, insert, update, delete
on table public.shifts
to authenticated;

drop policy if exists shifts_admin_write on public.shifts;
create policy shifts_admin_write
  on public.shifts for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- La deuda se conserva cuando un turno ya está activo o terminado. Un turno
-- cancelado no genera cuota; un turno programado para un solo día sí genera
-- exactamente una cuota diaria.
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
       and s.status <> 'cancelled'
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
     and s.status <> 'cancelled'
     and s.scheduled_for >= requested_week_start
     and s.scheduled_for < requested_week_start + 7
   where p.role = 'courier'
     and p.active = true
   group by p.id, p.full_name, settings.daily_amount,
            settings.double_shift_surcharge
   order by p.full_name;
$fn$;

grant execute on function public.get_courier_fee_summary(date)
  to authenticated;
grant execute on function public.get_admin_courier_fee_summary(date)
  to authenticated;
