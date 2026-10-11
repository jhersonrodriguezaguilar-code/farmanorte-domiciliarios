-- Registra automáticamente cada creación y modificación de un domicilio.
-- La función es SECURITY DEFINER para que la auditoría no dependa del RLS
-- del usuario que cambió el domicilio.

create or replace function public.record_delivery_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_event text;
begin
  if tg_op = 'INSERT' then
    next_event := 'published';
    insert into public.delivery_events (
      delivery_id,
      actor_id,
      event_type,
      to_status,
      metadata
    ) values (
      new.id,
      coalesce(new.created_by, auth.uid()),
      next_event,
      new.status,
      jsonb_build_object('source', 'database_trigger', 'operation', tg_op)
    );
    return new;
  end if;

  if old.status is distinct from new.status then
    next_event := 'status_changed';
  else
    next_event := 'updated';
  end if;

  insert into public.delivery_events (
    delivery_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    metadata
  ) values (
    new.id,
    auth.uid(),
    next_event,
    old.status,
    new.status,
    jsonb_build_object('source', 'database_trigger', 'operation', tg_op)
  );
  return new;
end;
$$;

drop trigger if exists deliveries_record_event on public.deliveries;
create trigger deliveries_record_event
after insert or update on public.deliveries
for each row execute function public.record_delivery_event();
