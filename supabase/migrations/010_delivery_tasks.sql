-- Pasos independientes de una compra externa o un cruce.
-- Los registros históricos de clientes y documentos se conservan; el formulario
-- actual no los consulta ni depende de ellos.
create table if not exists public.delivery_tasks (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  sequence_no integer not null check (sequence_no > 0),
  task_type text not null check (task_type in ('purchase', 'cross')),
  origin_pharmacy_code text references public.pharmacies(code),
  destination_pharmacy_code text references public.pharmacies(code),
  merchant_name text,
  merchant_branch text,
  product text not null,
  quantity numeric(12, 2) not null default 1 check (quantity > 0),
  notes text,
  return_to_pharmacy boolean not null default false,
  created_at timestamptz not null default now(),
  constraint delivery_tasks_purchase_fields check (
    task_type <> 'purchase'
    or (merchant_name is not null and merchant_branch is not null)
  ),
  constraint delivery_tasks_cross_fields check (
    task_type <> 'cross'
    or (
      origin_pharmacy_code is not null
      and destination_pharmacy_code is not null
      and origin_pharmacy_code <> destination_pharmacy_code
    )
  )
);

create index if not exists delivery_tasks_delivery_sequence_idx
  on public.delivery_tasks(delivery_id, sequence_no);

alter table public.delivery_tasks enable row level security;

revoke all on public.delivery_tasks from anon;
grant select, insert on public.delivery_tasks to authenticated;

drop policy if exists delivery_tasks_read_relevant on public.delivery_tasks;
create policy delivery_tasks_read_relevant
  on public.delivery_tasks for select to authenticated
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
          or public.courier_has_zone(d.zone_id)
        )
    )
  );

drop policy if exists delivery_tasks_insert_relevant on public.delivery_tasks;
create policy delivery_tasks_insert_relevant
  on public.delivery_tasks for insert to authenticated
  with check (
    public.is_admin()
    or exists (
      select 1
      from public.deliveries d
      where d.id = delivery_id
        and d.pharmacy_code = public.my_pharmacy_code()
    )
  );
