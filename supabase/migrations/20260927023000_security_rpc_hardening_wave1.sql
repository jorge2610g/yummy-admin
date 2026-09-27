-- YummyPro security hardening wave 1
-- Staging first. Reduce direct RPC attack surface without changing application behavior.

-- Pure helper: pin search_path to prevent caller-controlled object resolution.
alter function public.normalize_module_array(jsonb)
  set search_path = public, pg_temp;

-- Trigger-only functions must not be callable through PostgREST/RPC.
revoke all on function public.clear_demo_mp_user_on_inheritance() from public;
revoke all on function public.enforce_customer_profile_account_type() from public;
revoke all on function public.enforce_restaurant_creator_account_type() from public;
revoke all on function public.enforce_restaurant_staff_account_type() from public;
revoke all on function public.enforce_streaming_no_delivery() from public;
revoke all on function public.enforce_white_label_plan_capability() from public;

-- Admin RPCs: authenticated users can call them, while the function's own
-- is_site_admin() guard remains the authorization boundary.
revoke all on function public.admin_business_directory_page(integer, integer, text, text, text) from public;
grant execute on function public.admin_business_directory_page(integer, integer, text, text, text) to authenticated, service_role;

revoke all on function public.admin_dashboard_overview(bigint) from public;
grant execute on function public.admin_dashboard_overview(bigint) to authenticated, service_role;

revoke all on function public.admin_plan_recommendations_page(integer, integer, integer, text, bigint) from public;
grant execute on function public.admin_plan_recommendations_page(integer, integer, integer, text, bigint) to authenticated, service_role;

revoke all on function public.admin_set_restaurant_subscription_access(bigint, bigint, jsonb, numeric, timestamptz, text) from public;
grant execute on function public.admin_set_restaurant_subscription_access(bigint, bigint, jsonb, numeric, timestamptz, text) to authenticated, service_role;

-- Authenticated operational RPCs: remove anonymous execution while preserving
-- signed-in users and backend service jobs.
revoke all on function public.create_cashier_sale(bigint, text, text, text, jsonb) from public;
grant execute on function public.create_cashier_sale(bigint, text, text, text, jsonb) to authenticated, service_role;

revoke all on function public.get_active_restaurant_tables_for_pos(bigint) from public;
grant execute on function public.get_active_restaurant_tables_for_pos(bigint) to authenticated, service_role;

revoke all on function public.complete_table_qr_delivery(bigint) from public;
grant execute on function public.complete_table_qr_delivery(bigint) to authenticated, service_role;
