-- RLS performance consolidation (staging): preserve effective access while reducing permissive-policy overlap.

drop policy if exists "admin can view own admin row" on public.admin_users;
drop policy if exists "admins can view admin directory" on public.admin_users;
create policy "admin users select" on public.admin_users for select to authenticated
using (user_id=(select auth.uid()) or (select public.current_account_role())='admin');

drop policy if exists "customers read own profile" on public.customer_profiles;
drop policy if exists "site admins read customer profiles" on public.customer_profiles;
create policy "customer profiles select" on public.customer_profiles for select to authenticated
using ((user_id=(select auth.uid()) and public.current_account_role()='customer') or public.is_site_admin());

drop policy if exists "restaurant categories admin write" on public.restaurant_categories;
drop policy if exists "restaurant managers manage categories" on public.restaurant_categories;
drop policy if exists "public read categories" on public.restaurant_categories;
drop policy if exists "restaurant categories public read" on public.restaurant_categories;
create policy "restaurant categories select" on public.restaurant_categories for select to anon,authenticated
using (active=true or public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant categories insert" on public.restaurant_categories for insert to authenticated
with check (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant categories update" on public.restaurant_categories for update to authenticated
using (public.is_site_admin() or public.can_manage_restaurant(restaurant_id))
with check (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant categories delete" on public.restaurant_categories for delete to authenticated
using (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));

drop policy if exists "restaurant managers manage products" on public.restaurant_products;
drop policy if exists "restaurant products admin write" on public.restaurant_products;
drop policy if exists "public read products" on public.restaurant_products;
drop policy if exists "restaurant products public read" on public.restaurant_products;
create policy "restaurant products select" on public.restaurant_products for select to anon,authenticated
using (available=true or public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant products insert" on public.restaurant_products for insert to authenticated
with check (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant products update" on public.restaurant_products for update to authenticated
using (public.is_site_admin() or public.can_manage_restaurant(restaurant_id))
with check (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));
create policy "restaurant products delete" on public.restaurant_products for delete to authenticated
using (public.is_site_admin() or public.can_manage_restaurant(restaurant_id));

drop policy if exists "retail products manage" on public.retail_products;
create policy "retail products insert" on public.retail_products for insert to authenticated
with check (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'products') or public.has_restaurant_permission(restaurant_id,'inventory'));
create policy "retail products update" on public.retail_products for update to authenticated
using (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'products') or public.has_restaurant_permission(restaurant_id,'inventory'))
with check (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'products') or public.has_restaurant_permission(restaurant_id,'inventory'));
create policy "retail products delete" on public.retail_products for delete to authenticated
using (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'products') or public.has_restaurant_permission(restaurant_id,'inventory'));

drop policy if exists "professional_appointments_staff" on public.professional_appointments;
drop policy if exists "professional_appointments_customer_read" on public.professional_appointments;
create policy "professional appointments select" on public.professional_appointments for select to authenticated
using (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='professional')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'appointments') or customer_id=(select auth.uid()))
);
create policy "professional appointments insert" on public.professional_appointments for insert to authenticated
with check (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='professional')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'appointments'))
);
create policy "professional appointments update" on public.professional_appointments for update to authenticated
using (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='professional')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'appointments'))
)
with check (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='professional')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'appointments'))
);
create policy "professional appointments delete" on public.professional_appointments for delete to authenticated
using (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='professional')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'appointments'))
);

drop policy if exists "streaming_subscriptions_staff" on public.streaming_subscriptions;
drop policy if exists "streaming_subscriptions_customer_select" on public.streaming_subscriptions;
create policy "streaming subscriptions select" on public.streaming_subscriptions for select to authenticated
using (
  (
    exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='streaming')
    and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'orders') or public.has_restaurant_permission(restaurant_id,'products'))
  )
  or (
    order_id is not null
    and exists(select 1 from public.streaming_orders o where o.id=order_id and o.customer_user_id=(select auth.uid()))
  )
);
create policy "streaming subscriptions insert" on public.streaming_subscriptions for insert to authenticated
with check (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='streaming')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'orders') or public.has_restaurant_permission(restaurant_id,'products'))
);
create policy "streaming subscriptions update" on public.streaming_subscriptions for update to authenticated
using (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='streaming')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'orders') or public.has_restaurant_permission(restaurant_id,'products'))
)
with check (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='streaming')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'orders') or public.has_restaurant_permission(restaurant_id,'products'))
);
create policy "streaming subscriptions delete" on public.streaming_subscriptions for delete to authenticated
using (
  exists(select 1 from public.restaurants r where r.id=restaurant_id and r.business_type='streaming')
  and (public.is_site_admin() or public.has_restaurant_permission(restaurant_id,'orders') or public.has_restaurant_permission(restaurant_id,'products'))
);

drop policy if exists "restaurant_managers_read_subscription_payments" on public.subscription_payments;
drop policy if exists "users_read_own_subscription_payments" on public.subscription_payments;
create policy "subscription payments select" on public.subscription_payments for select to authenticated
using (
  public.can_manage_restaurant_staff(restaurant_id)
  or user_id=(select auth.uid())
  or exists(select 1 from public.admin_users a where a.user_id=(select auth.uid()))
);

drop policy if exists "superadmins_manage_subscription_plans" on public.subscription_plans;
drop policy if exists "authenticated_read_active_subscription_plans" on public.subscription_plans;
create policy "authenticated subscription plans select" on public.subscription_plans for select to authenticated
using (active=true or exists(select 1 from public.admin_users a where a.user_id=(select auth.uid())));
create policy "admin subscription plans insert" on public.subscription_plans for insert to authenticated
with check (exists(select 1 from public.admin_users a where a.user_id=(select auth.uid())));
create policy "admin subscription plans update" on public.subscription_plans for update to authenticated
using (exists(select 1 from public.admin_users a where a.user_id=(select auth.uid())))
with check (exists(select 1 from public.admin_users a where a.user_id=(select auth.uid())));
create policy "admin subscription plans delete" on public.subscription_plans for delete to authenticated
using (exists(select 1 from public.admin_users a where a.user_id=(select auth.uid())));
