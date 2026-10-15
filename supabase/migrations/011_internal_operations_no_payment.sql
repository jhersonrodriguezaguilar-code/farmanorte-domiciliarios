-- Internal purchases/crosses do not have a client payment method.
-- Client-facing services keep cash, card and QR; internal operations use none.
alter table public.deliveries
  drop constraint if exists deliveries_payment_method_check;

alter table public.deliveries
  add constraint deliveries_payment_method_check
  check (payment_method in ('cash', 'card', 'qr', 'none'));

alter table public.deliveries
  add column if not exists cash_change numeric(12, 2);
