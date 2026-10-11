-- Permite que la programación semanal sea idempotente:
-- repetir una sugerencia actualiza el turno existente en vez de duplicarlo.
create unique index if not exists shifts_courier_schedule_unique
  on public.shifts(courier_id, scheduled_for, starts_at, ends_at, pharmacy_code);
