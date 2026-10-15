-- Reduce the exposed API surface of SECURITY DEFINER functions.
-- Anonymous/public execution is not needed: app RPCs run only after Supabase
-- authentication, and trigger functions are invoked by their database triggers.

revoke execute on function public.accept_delivery(uuid, boolean) from public, anon;
revoke execute on function public.acknowledge_delivery_equivalent(uuid) from public, anon;
revoke execute on function public.assign_delivery_to_courier(uuid, uuid) from public, anon;
revoke execute on function public.complete_password_change() from public, anon;
revoke execute on function public.courier_has_zone(uuid) from public, anon;
revoke execute on function public.create_delivery_equivalent_from_delivery() from public, anon;
revoke execute on function public.delivery_customer_matches(text, uuid, uuid) from public, anon;
revoke execute on function public.ensure_delivery_equivalent(uuid) from public, anon;
revoke execute on function public.get_admin_courier_fee_summary(date) from public, anon;
revoke execute on function public.get_courier_fee_summary(date) from public, anon;
revoke execute on function public.get_equivalent_payment_timing() from public, anon;
revoke execute on function public.get_pharmacy_zone_couriers(uuid, date) from public, anon;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.is_pharmacy_user() from public, anon;
revoke execute on function public.mark_delivery_equivalent_paid(uuid, numeric) from public, anon;
revoke execute on function public.my_pharmacy_code() from public, anon;
revoke execute on function public.record_delivery_event() from public, anon;
revoke execute on function public.rls_auto_enable() from public, anon;
revoke execute on function public.set_delivery_chat_sender() from public, anon;
revoke execute on function public.set_delivery_equivalent_service_date() from public, anon;
revoke execute on function public.set_delivery_fee() from public, anon;
revoke execute on function public.sign_delivery_equivalent(uuid, text) from public, anon;
revoke execute on function public.sign_delivery_equivalent_with_image(uuid, text, text) from public, anon;
revoke execute on function public.update_courier_fee_settings(numeric, numeric) from public, anon;
revoke execute on function public.update_equivalent_payment_timing(text) from public, anon;
revoke execute on function public.upsert_customer_contact(text, text, text) from public, anon;
revoke execute on function public.validate_delivery_pharmacy_profile() from public, anon;

-- These functions are implementation details for triggers/event triggers.
-- They must not be exposed as callable RPCs to authenticated clients either.
revoke execute on function public.create_delivery_equivalent_from_delivery() from authenticated;
revoke execute on function public.record_delivery_event() from authenticated;
revoke execute on function public.rls_auto_enable() from authenticated;
revoke execute on function public.set_delivery_chat_sender() from authenticated;
revoke execute on function public.set_delivery_equivalent_service_date() from authenticated;
revoke execute on function public.set_delivery_fee() from authenticated;
revoke execute on function public.validate_delivery_pharmacy_profile() from authenticated;

-- Keep the authenticated RPCs and RLS predicate helpers used by the clients.
grant execute on function public.accept_delivery(uuid, boolean) to authenticated;
grant execute on function public.acknowledge_delivery_equivalent(uuid) to authenticated;
grant execute on function public.assign_delivery_to_courier(uuid, uuid) to authenticated;
grant execute on function public.complete_password_change() to authenticated;
grant execute on function public.courier_has_zone(uuid) to authenticated;
grant execute on function public.delivery_customer_matches(text, uuid, uuid) to authenticated;
grant execute on function public.ensure_delivery_equivalent(uuid) to authenticated;
grant execute on function public.get_admin_courier_fee_summary(date) to authenticated;
grant execute on function public.get_courier_fee_summary(date) to authenticated;
grant execute on function public.get_equivalent_payment_timing() to authenticated;
grant execute on function public.get_pharmacy_zone_couriers(uuid, date) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_pharmacy_user() to authenticated;
grant execute on function public.mark_delivery_equivalent_paid(uuid, numeric) to authenticated;
grant execute on function public.my_pharmacy_code() to authenticated;
grant execute on function public.sign_delivery_equivalent_with_image(uuid, text, text) to authenticated;
grant execute on function public.update_courier_fee_settings(numeric, numeric) to authenticated;
grant execute on function public.update_equivalent_payment_timing(text) to authenticated;
grant execute on function public.upsert_customer_contact(text, text, text) to authenticated;
