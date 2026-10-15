-- Reduce direct table privileges for client roles.
-- State transitions, signatures, payments and administrative writes must go
-- through the validated SECURITY DEFINER RPCs. This migration changes only
-- grants; it does not alter or delete operational rows.

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'deliveries',
    'delivery_tasks',
    'delivery_events',
    'delivery_equivalents',
    'delivery_chat_messages',
    'push_tokens',
    'shifts',
    'profiles',
    'pharmacy_profiles',
    'customers',
    'customer_addresses',
    'admin_audit_log',
    'courier_fee_payments'
  ] loop
    execute format(
      'revoke all on table public.%I from public, anon, authenticated',
      table_name
    );
  end loop;
end;
$$;

-- Read-only or append-only operational data.
grant select, insert on public.deliveries to authenticated;
grant select, insert on public.delivery_tasks to authenticated;
grant select, insert on public.delivery_events to authenticated;
grant select on public.delivery_equivalents to authenticated;
grant select, insert on public.delivery_chat_messages to authenticated;

-- A client owns only its push-token rows; RLS remains the authorization
-- boundary for the row-level scope, while these are the required verbs for
-- register/refresh/deactivate flows.
grant select, insert, update, delete on public.push_tokens to authenticated;

-- Admin scheduling and account-management screens still use direct writes;
-- their RLS policies restrict which rows each role can touch.
grant select, insert, update, delete on public.shifts to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.pharmacy_profiles to authenticated;

-- The shared customer directory supports lookup and contact upserts.
grant select, insert, update on public.customers to authenticated;
grant select, insert, update on public.customer_addresses to authenticated;

-- Audit and fee-payment rows are written only by protected RPCs.
grant select on public.admin_audit_log to authenticated;
grant select on public.courier_fee_payments to authenticated;
