-- YummyPro security hardening wave 3
-- Staging first. Remove anonymous EXECUTE from RPCs that already require an authenticated session.

revoke execute on function public.get_ready_table_qr_orders(bigint) from anon;
revoke execute on function public.restaurant_has_open_cash(bigint) from anon;
revoke execute on function public.get_restaurant_subscription_access(bigint) from anon;
revoke execute on function public.can_register_customer() from anon;
revoke execute on function public.streaming_create_order(bigint, jsonb, text, text) from anon;

grant execute on function public.get_ready_table_qr_orders(bigint) to authenticated, service_role;
grant execute on function public.restaurant_has_open_cash(bigint) to authenticated, service_role;
grant execute on function public.get_restaurant_subscription_access(bigint) to authenticated, service_role;
grant execute on function public.can_register_customer() to authenticated, service_role;
grant execute on function public.streaming_create_order(bigint, jsonb, text, text) to authenticated, service_role;
