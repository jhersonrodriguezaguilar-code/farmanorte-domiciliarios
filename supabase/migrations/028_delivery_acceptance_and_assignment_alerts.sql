-- Correcciones operativas para las pruebas reales:
-- 1) una misma persona puede aceptar varios domicilios independientes;
-- 2) una oferta vencida no se puede aceptar;
-- 3) la asignación manual se notifica desde la página de farmacia.

create or replace function public.accept_delivery(
  requested_delivery_id uuid,
  requested_as_support boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  delivery_row public.deliveries%rowtype;
  has_eligible_shift boolean;
begin
  if auth.uid() is null then
    raise exception 'La sesión no está autenticada.';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'courier'
      and active = true
  ) then
    raise exception 'Solo un domiciliario activo puede aceptar domicilios.';
  end if;

  select *
    into delivery_row
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

  if delivery_row.expires_at is not null
     and delivery_row.expires_at <= now() then
    -- La ventana de cinco minutos solo vence la aceptación automática. Se
    -- conserva como `offered` para que la farmacia todavía pueda asignarlo
    -- manualmente después de ese tiempo.
    raise exception 'La ventana de aceptación venció. La farmacia todavía puede asignar este domicilio.';
  end if;

  select exists (
    select 1
    from public.shifts s
    where s.courier_id = auth.uid()
      and s.scheduled_for = current_date
      and s.status in ('scheduled', 'active')
      and (
        (requested_as_support and s.assignment_type = 'support')
        or (
          not requested_as_support
          and s.assignment_type = 'zone'
          and s.zone_id = delivery_row.zone_id
        )
      )
  ) into has_eligible_shift;

  if not has_eligible_shift then
    raise exception 'No tienes un turno válido para esta zona hoy.';
  end if;

  update public.deliveries
     set status = 'accepted',
         accepted_courier_id = auth.uid(),
         assigned_as_support = requested_as_support,
         accepted_at = now(),
         updated_at = now()
   where id = requested_delivery_id
     and status = 'offered'
     and accepted_courier_id is null;

  if not found then
    return false;
  end if;

  insert into public.delivery_events (
    delivery_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    metadata
  ) values (
    requested_delivery_id,
    auth.uid(),
    'status_changed',
    'offered',
    'accepted',
    jsonb_build_object(
      'source', 'courier_app',
      'assignment_type', case when requested_as_support then 'support' else 'zone' end
    )
  );

  return true;
end;
$fn$;

grant execute on function public.accept_delivery(uuid, boolean) to authenticated;
