-- FarmaNorte · Etapa 2/7 · bitácora mínima de acciones administrativas.

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

