-- FarmaNorte · Etapa 4/5/6 · transiciones seguras y contraseña temporal.
-- Las aplicaciones no actualizan directamente columnas sensibles de deliveries.
-- Todas las transiciones pasan por funciones atómicas que validan rol, estado y
-- relación con el domicilio.

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

-- Solo el administrador puede consultar el resumen global de cuotas.
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
end;
$fn$;

grant execute on function public.get_admin_courier_fee_summary(date)
  to authenticated;

create or replace function public.request_delivery_approval(
  requested_delivery_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  courier_name text;
  has_eligible_shift boolean;
  has_active_delivery boolean;
begin
  if not exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and p.role = 'courier'
       and p.active = true
  ) then
    raise exception 'Solo un domiciliario activo puede solicitar otro domicilio.';
  end if;

  select * into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;
  if delivery_row.status <> 'offered'
     or delivery_row.accepted_courier_id is not null then
    return false;
  end if;
  if delivery_row.approval_pending then
    return true;
  end if;

  select exists (
    select 1
      from public.shifts s
     where s.courier_id = auth.uid()
       and s.scheduled_for = current_date
       and s.status in ('scheduled', 'active')
       and (s.assignment_type = 'support' or s.zone_id = delivery_row.zone_id)
  ) into has_eligible_shift;
  if not has_eligible_shift then
    raise exception 'No tienes un turno válido para esta zona hoy.';
  end if;

  select exists (
    select 1
      from public.deliveries d
     where d.accepted_courier_id = auth.uid()
       and d.status in ('accepted', 'pickedUp')
  ) into has_active_delivery;
  if not has_active_delivery then
    raise exception 'Este domicilio se puede aceptar directamente porque no tienes otro activo.';
  end if;

  select p.full_name into courier_name
    from public.profiles p
   where p.id = auth.uid();

  update public.deliveries
     set approval_pending = true,
         approval_courier_id = auth.uid(),
         approval_courier_name = courier_name,
         updated_at = now()
   where id = requested_delivery_id
     and status = 'offered'
     and accepted_courier_id is null;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'second_delivery_requested',
    'offered', 'offered',
    jsonb_build_object('courier_name', courier_name)
  );
  return true;
end;
$fn$;

grant execute on function public.request_delivery_approval(uuid)
  to authenticated;

create or replace function public.approve_delivery_request(
  requested_delivery_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  support_assignment boolean;
begin
  select * into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;

  if not found then
    raise exception 'El domicilio no existe.';
  end if;
  if not (public.is_admin() or delivery_row.pharmacy_code = public.my_pharmacy_code()) then
    raise exception 'No tienes permiso para aprobar este domicilio.';
  end if;
  if not delivery_row.approval_pending
     or delivery_row.approval_courier_id is null
     or delivery_row.status <> 'offered' then
    raise exception 'Este domicilio no tiene una solicitud pendiente.';
  end if;

  select
    exists (
      select 1 from public.shifts s
       where s.courier_id = delivery_row.approval_courier_id
         and s.scheduled_for = current_date
         and s.status in ('scheduled', 'active')
         and s.assignment_type = 'support'
    )
    and not exists (
      select 1 from public.shifts s
       where s.courier_id = delivery_row.approval_courier_id
         and s.scheduled_for = current_date
         and s.status in ('scheduled', 'active')
         and s.assignment_type = 'zone'
         and s.zone_id = delivery_row.zone_id
    )
  into support_assignment;

  update public.deliveries
     set status = 'accepted',
         accepted_courier_id = approval_courier_id,
         accepted_at = now(),
         assigned_as_support = support_assignment,
         approval_pending = false,
         approval_courier_id = null,
         approval_courier_name = null,
         updated_at = now()
   where id = requested_delivery_id
     and status = 'offered'
     and approval_pending = true;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'second_delivery_approved',
    'offered', 'accepted',
    jsonb_build_object(
      'assigned_courier_id', delivery_row.approval_courier_id,
      'assignment_type', case when support_assignment then 'support' else 'zone' end
    )
  );
  return true;
end;
$fn$;

grant execute on function public.approve_delivery_request(uuid)
  to authenticated;

create or replace function public.reject_delivery_request(
  requested_delivery_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
begin
  select * into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;
  if not found then
    raise exception 'El domicilio no existe.';
  end if;
  if not (public.is_admin() or delivery_row.pharmacy_code = public.my_pharmacy_code()) then
    raise exception 'No tienes permiso para rechazar este domicilio.';
  end if;
  if not delivery_row.approval_pending then
    return false;
  end if;

  update public.deliveries
     set approval_pending = false,
         approval_courier_id = null,
         approval_courier_name = null,
         updated_at = now()
   where id = requested_delivery_id
     and approval_pending = true;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'second_delivery_rejected',
    delivery_row.status, delivery_row.status, '{}'::jsonb
  );
  return true;
end;
$fn$;

grant execute on function public.reject_delivery_request(uuid)
  to authenticated;

create or replace function public.transition_delivery_status(
  requested_delivery_id uuid,
  requested_status text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  actor_role public.app_role;
  normalized_status text := btrim(coalesce(requested_status, ''));
  next_picked_up_at timestamptz;
  next_delivered_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;
  if normalized_status not in ('pickedUp', 'delivered', 'notDelivered', 'cancelled') then
    raise exception 'Estado de domicilio no permitido.';
  end if;

  select p.role into actor_role
    from public.profiles p
   where p.id = auth.uid()
     and p.active = true;
  if actor_role is null then
    raise exception 'El perfil operativo no está activo.';
  end if;

  select * into delivery_row
    from public.deliveries
   where id = requested_delivery_id
   for update;
  if not found then
    raise exception 'El domicilio no existe.';
  end if;

  if actor_role = 'courier' then
    if delivery_row.accepted_courier_id <> auth.uid()
       and delivery_row.approval_courier_id <> auth.uid() then
      raise exception 'Este domicilio no está asignado a tu usuario.';
    end if;
    if normalized_status = 'cancelled' then
      raise exception 'Un domiciliario no puede cancelar un domicilio desde este flujo.';
    end if;
  elsif actor_role = 'pharmacy' then
    if delivery_row.pharmacy_code <> public.my_pharmacy_code()
       or normalized_status <> 'cancelled' then
      raise exception 'La farmacia solo puede cancelar sus domicilios publicados.';
    end if;
  elsif actor_role <> 'admin' then
    raise exception 'El rol no puede cambiar estados.';
  end if;

  if normalized_status = 'pickedUp'
     and delivery_row.status <> 'accepted' then
    raise exception 'El domicilio debe estar aceptado antes de iniciar el recorrido.';
  end if;
  if normalized_status in ('delivered', 'notDelivered')
     and delivery_row.status not in ('accepted', 'pickedUp') then
    raise exception 'El domicilio debe estar aceptado o en recorrido.';
  end if;
  if normalized_status = 'cancelled'
     and delivery_row.status not in ('offered', 'accepted') then
    raise exception 'Este domicilio ya no se puede cancelar.';
  end if;

  next_picked_up_at := case
    when normalized_status = 'pickedUp' then now()
    else delivery_row.picked_up_at
  end;
  next_delivered_at := case
    when normalized_status in ('delivered', 'notDelivered') then now()
    else delivery_row.delivered_at
  end;

  update public.deliveries
     set status = normalized_status,
         picked_up_at = next_picked_up_at,
         delivered_at = next_delivered_at,
         delivery_outcome = case
           when normalized_status = 'delivered' then coalesce(delivery_outcome, 'Entregado')
           when normalized_status = 'notDelivered' then coalesce(delivery_outcome, 'No entregado')
           else delivery_outcome
         end,
         updated_at = now()
   where id = requested_delivery_id;

  insert into public.delivery_events (
    delivery_id, actor_id, event_type, from_status, to_status, metadata
  ) values (
    requested_delivery_id, auth.uid(), 'status_changed',
    delivery_row.status, normalized_status,
    jsonb_build_object('source', 'secure_transition_rpc')
  );
  return true;
end;
$fn$;

grant execute on function public.transition_delivery_status(uuid, text)
  to authenticated;

-- La escritura de deliveries se limita a inserciones; las modificaciones
-- operativas se realizan mediante las funciones anteriores.
drop policy if exists deliveries_update_relevant on public.deliveries;
revoke update on public.deliveries from authenticated;

