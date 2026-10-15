-- Chat persistente por domicilio entre la farmacia, el domiciliario y el
-- administrador. Cada mensaje queda asociado a una entrega concreta.
create table if not exists public.delivery_chat_messages (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  sender_name text not null,
  sender_role public.app_role not null,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists delivery_chat_messages_delivery_created_idx
  on public.delivery_chat_messages(delivery_id, created_at, id);

alter table public.delivery_chat_messages enable row level security;

revoke all on public.delivery_chat_messages from anon;
grant select, insert on public.delivery_chat_messages to authenticated;

-- El cliente solo envía el texto y su id. El servidor toma el nombre/rol del
-- perfil autenticado y fija la hora para que el registro no sea falsificable.
create or replace function public.set_delivery_chat_sender()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sender_profile public.profiles%rowtype;
begin
  if auth.uid() is null or new.sender_id <> auth.uid() then
    raise exception 'El remitente del mensaje no coincide con la sesión actual';
  end if;

  select *
    into sender_profile
    from public.profiles
   where id = auth.uid()
     and active = true;

  if not found then
    raise exception 'El usuario no tiene un perfil operativo activo';
  end if;

  new.sender_name := sender_profile.full_name;
  new.sender_role := sender_profile.role;
  new.body := btrim(new.body);
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists delivery_chat_messages_set_sender
  on public.delivery_chat_messages;
create trigger delivery_chat_messages_set_sender
before insert on public.delivery_chat_messages
for each row execute function public.set_delivery_chat_sender();

drop policy if exists delivery_chat_messages_read_relevant
  on public.delivery_chat_messages;
create policy delivery_chat_messages_read_relevant
  on public.delivery_chat_messages for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
        from public.deliveries d
       where d.id = delivery_id
         and (
           d.pharmacy_code = public.my_pharmacy_code()
           or d.accepted_courier_id = auth.uid()
           or d.approval_courier_id = auth.uid()
         )
    )
  );

drop policy if exists delivery_chat_messages_insert_relevant
  on public.delivery_chat_messages;
create policy delivery_chat_messages_insert_relevant
  on public.delivery_chat_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (
      public.is_admin()
      or exists (
        select 1
          from public.deliveries d
         where d.id = delivery_id
           and (
             d.pharmacy_code = public.my_pharmacy_code()
             or d.accepted_courier_id = auth.uid()
             or d.approval_courier_id = auth.uid()
           )
      )
    )
  );

do $$
begin
  if not exists (
    select 1
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'delivery_chat_messages'
  ) then
    alter publication supabase_realtime add table public.delivery_chat_messages;
  end if;
end;
$$;
