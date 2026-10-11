-- Hace idempotente la programación de turnos que cubren toda una zona.
-- PostgreSQL permite múltiples valores NULL en un índice UNIQUE; por eso
-- pharmacy_code no puede ser la clave de conflicto cuando el punto es NULL.
alter table public.shifts
  add column if not exists pharmacy_key text generated always as (
    coalesce(pharmacy_code, '__ALL_ZONE__')
  ) stored;

create unique index if not exists shifts_courier_schedule_key_unique
  on public.shifts(courier_id, scheduled_for, starts_at, ends_at, pharmacy_key);
