-- YummyPro security hardening wave 1b
-- Some functions had explicit grants to anon/authenticated in addition to PUBLIC.
-- Remove those role-specific grants where direct RPC execution is not intended.

-- Trigger-only functions: never callable through the API.
revoke execute on function public.clear_demo_mp_user_on_inheritance() from anon, authenticated;
revoke execute on function public.enforce_customer_profile_account_type() from anon, authenticated;
revoke execute on function public.enforce_restaurant_creator_account_type() from anon, authenticated;
revoke execute on function public.enforce_restaurant_staff_account_type() from anon, authenticated;
revoke execute on function public.enforce_streaming_no_delivery() from anon, authenticated;
revoke execute on function public.enforce_white_label_plan_capability() from anon, authenticated;

-- Admin RPCs: anonymous execution is never required.
revoke execute on function public.admin_business_directory_page(integer, integer, text, text, text) from anon;
revoke execute on function public.admin_dashboard_overview(bigint) from anon;
revoke execute on function public.admin_plan_recommendations_page(integer, integer, integer, text, bigint) from anon;
revoke execute on function public.admin_set_restaurant_subscription_access(bigint, bigint, jsonb, numeric, timestamptz, text) from anon;

-- Cashier actions require a signed-in restaurant operator.
revoke execute on function public.create_cashier_sale(bigint, text, text, text, jsonb) from anon;
