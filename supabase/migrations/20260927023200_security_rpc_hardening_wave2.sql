-- YummyPro security hardening wave 2
-- Restrict maintenance, trigger and staff-only SECURITY DEFINER functions.

-- Maintenance / cron functions: backend only.
revoke all on function public.cleanup_expired_table_qr_mp_orders() from public;
revoke execute on function public.cleanup_expired_table_qr_mp_orders() from anon, authenticated;
grant execute on function public.cleanup_expired_table_qr_mp_orders() to service_role;

revoke all on function public.process_subscription_email_reminders() from public;
revoke execute on function public.process_subscription_email_reminders() from anon, authenticated;
grant execute on function public.process_subscription_email_reminders() to service_role;

revoke all on function public.retail_release_expired_online_orders() from public;
revoke execute on function public.retail_release_expired_online_orders() from anon, authenticated;
grant execute on function public.retail_release_expired_online_orders() to service_role;

-- Trigger-only functions: no direct PostgREST execution.
revoke all on function public.mark_mp_credential_source_from_override() from public;
revoke execute on function public.mark_mp_credential_source_from_override() from anon, authenticated;

revoke all on function public.notify_new_restaurant_by_email() from public;
revoke execute on function public.notify_new_restaurant_by_email() from anon, authenticated;

revoke all on function public.streaming_sync_order_status() from public;
revoke execute on function public.streaming_sync_order_status() from anon, authenticated;

revoke all on function public.sync_account_identity() from public;
revoke execute on function public.sync_account_identity() from anon, authenticated;

revoke all on function public.sync_demo_api_defaults_after_global_change() from public;
revoke execute on function public.sync_demo_api_defaults_after_global_change() from anon, authenticated;

-- Staff-only operational RPCs: signed-in users only; body permission checks remain.
revoke all on function public.get_ready_table_qr_orders(bigint) from public;
grant execute on function public.get_ready_table_qr_orders(bigint) to authenticated, service_role;

revoke all on function public.get_restaurant_staff_directory(bigint) from public;
grant execute on function public.get_restaurant_staff_directory(bigint) to authenticated, service_role;

revoke all on function public.get_waiter_paid_qr_orders(bigint) from public;
grant execute on function public.get_waiter_paid_qr_orders(bigint) to authenticated, service_role;

revoke all on function public.restaurant_has_open_cash(bigint) from public;
grant execute on function public.restaurant_has_open_cash(bigint) to authenticated, service_role;

revoke all on function public.update_waiter_order(bigint, text, text, text, jsonb) from public;
grant execute on function public.update_waiter_order(bigint, text, text, text, jsonb) to authenticated, service_role;

revoke all on function public.withdraw_table_qr_order(bigint) from public;
grant execute on function public.withdraw_table_qr_order(bigint) to authenticated, service_role;

revoke all on function public.withdraw_waiter_order(bigint) from public;
grant execute on function public.withdraw_waiter_order(bigint) to authenticated, service_role;
