-- The push Edge Function uses the server-side Supabase secret key.  Keep
-- client roles restricted, but give the server role only the read/update
-- access needed to resolve recipients and deactivate stale device tokens.
grant usage on schema public to service_role;
grant select on public.deliveries to service_role;
grant select on public.zone_pharmacies to service_role;
grant select on public.shifts to service_role;
grant select on public.profiles to service_role;
grant select, update on public.push_tokens to service_role;
grant select on public.delivery_chat_messages to service_role;
