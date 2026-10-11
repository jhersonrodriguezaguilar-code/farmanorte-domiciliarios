-- Algunos turnos cubren toda una zona y no necesitan un punto de farmacia
-- específico. La zona sigue siendo obligatoria; el punto puede quedar NULL.
alter table public.shifts
  alter column pharmacy_code drop not null;
