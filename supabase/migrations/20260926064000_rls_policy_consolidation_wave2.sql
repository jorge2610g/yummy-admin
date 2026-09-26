-- RLS consolidation wave 2: preserve current permission unions while eliminating remaining overlaps.

drop policy if exists "countries admin manage" on public.platform_countries;
drop policy if exists "countries public read" on public.platform_countries;
create policy "countries select" on public.platform_countries for select to anon,authenticated
using (active=true or public.is_site_admin());
create policy "countries insert" on public.platform_countries for insert to authenticated with check (public.is_site_admin());
create policy "countries update" on public.platform_countries for update to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
create policy "countries delete" on public.platform_countries for delete to authenticated using (public.is_site_admin());

drop policy if exists "restaurant managers manage orders" on public.restaurant_orders;
drop policy if exists "customers create own orders" on public.restaurant_orders;
drop policy if exists "public_can_create_restaurant_orders" on public.restaurant_orders;
drop policy if exists "restaurant orders public insert" on public.restaurant_orders;
drop policy if exists "customers read own orders" on public.restaurant_orders;
drop policy if exists "restaurant orders admin read" on public.restaurant_orders;
drop policy if exists "restaurant staff read own orders" on public.restaurant_orders;
drop policy if exists "operational staff update orders" on public.restaurant_orders;
drop policy if exists "restaurant orders admin update" on public.restaurant_orders;
create policy "restaurant orders insert" on public.restaurant_orders for insert to anon,authenticated with check (true);
create policy "restaurant orders select" on public.restaurant_orders for select to authenticated
using (
  public.can_manage_restaurant(restaurant_id)
  or customer_id=(select auth.uid())
  or public.is_site_admin()
  or exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_orders.restaurant_id and s.user_id=(select auth.uid()) and s.active=true)
);
create policy "restaurant orders update" on public.restaurant_orders for update to authenticated
using (public.can_manage_restaurant(restaurant_id) or public.has_restaurant_permission(restaurant_id,'orders') or public.is_site_admin())
with check (public.can_manage_restaurant(restaurant_id) or public.has_restaurant_permission(restaurant_id,'orders') or public.is_site_admin());
create policy "restaurant orders delete" on public.restaurant_orders for delete to authenticated
using (public.can_manage_restaurant(restaurant_id));

drop policy if exists "payment methods managers manage" on public.restaurant_payment_methods;
drop policy if exists "payment methods public read" on public.restaurant_payment_methods;
create policy "payment methods select" on public.restaurant_payment_methods for select to anon,authenticated
using ((active and exists(select 1 from public.restaurants r where r.id=restaurant_id and r.active)) or public.can_manage_restaurant(restaurant_id) or public.is_site_admin());
create policy "payment methods insert" on public.restaurant_payment_methods for insert to authenticated with check (public.can_manage_restaurant(restaurant_id) or public.is_site_admin());
create policy "payment methods update" on public.restaurant_payment_methods for update to authenticated using (public.can_manage_restaurant(restaurant_id) or public.is_site_admin()) with check (public.can_manage_restaurant(restaurant_id) or public.is_site_admin());
create policy "payment methods delete" on public.restaurant_payment_methods for delete to authenticated using (public.can_manage_restaurant(restaurant_id) or public.is_site_admin());

drop policy if exists "staff manage payments" on public.restaurant_payments;
drop policy if exists "customers read own payments" on public.restaurant_payments;
create policy "restaurant payments select" on public.restaurant_payments for select to authenticated
using (public.has_restaurant_permission(restaurant_id,'payments') or exists(select 1 from public.restaurant_orders o where o.id=order_id and o.customer_id=(select auth.uid())));
create policy "restaurant payments insert" on public.restaurant_payments for insert to authenticated with check (public.has_restaurant_permission(restaurant_id,'payments'));
create policy "restaurant payments update" on public.restaurant_payments for update to authenticated using (public.has_restaurant_permission(restaurant_id,'payments')) with check (public.has_restaurant_permission(restaurant_id,'payments'));
create policy "restaurant payments delete" on public.restaurant_payments for delete to authenticated using (public.has_restaurant_permission(restaurant_id,'payments'));

drop policy if exists "staff manage option groups" on public.restaurant_product_option_groups;
drop policy if exists "public read option groups" on public.restaurant_product_option_groups;
create policy "option groups select" on public.restaurant_product_option_groups for select to anon,authenticated
using ((active and exists(select 1 from public.restaurant_products p where p.id=product_id and p.available)) or public.has_restaurant_permission(restaurant_id,'menu'));
create policy "option groups insert" on public.restaurant_product_option_groups for insert to authenticated with check (public.has_restaurant_permission(restaurant_id,'menu'));
create policy "option groups update" on public.restaurant_product_option_groups for update to authenticated using (public.has_restaurant_permission(restaurant_id,'menu')) with check (public.has_restaurant_permission(restaurant_id,'menu'));
create policy "option groups delete" on public.restaurant_product_option_groups for delete to authenticated using (public.has_restaurant_permission(restaurant_id,'menu'));

drop policy if exists "staff manage product options" on public.restaurant_product_options;
drop policy if exists "public read product options" on public.restaurant_product_options;
create policy "product options select" on public.restaurant_product_options for select to anon,authenticated
using ((available and exists(select 1 from public.restaurant_product_option_groups g where g.id=group_id and g.active)) or public.has_restaurant_permission(restaurant_id,'menu'));
create policy "product options insert" on public.restaurant_product_options for insert to authenticated with check (public.has_restaurant_permission(restaurant_id,'menu'));
create policy "product options update" on public.restaurant_product_options for update to authenticated using (public.has_restaurant_permission(restaurant_id,'menu')) with check (public.has_restaurant_permission(restaurant_id,'menu'));
create policy "product options delete" on public.restaurant_product_options for delete to authenticated using (public.has_restaurant_permission(restaurant_id,'menu'));

drop policy if exists "staff manage promotion products" on public.restaurant_promotion_products;
drop policy if exists "public read promotion products" on public.restaurant_promotion_products;
create policy "promotion products select" on public.restaurant_promotion_products for select to anon,authenticated
using (
  exists(select 1 from public.restaurant_promotions p where p.id=promotion_id and p.active and (p.starts_at is null or p.starts_at<=now()) and (p.ends_at is null or p.ends_at>=now()))
  or public.has_restaurant_permission(restaurant_id,'promotions')
);
create policy "promotion products insert" on public.restaurant_promotion_products for insert to authenticated with check (public.has_restaurant_permission(restaurant_id,'promotions'));
create policy "promotion products update" on public.restaurant_promotion_products for update to authenticated using (public.has_restaurant_permission(restaurant_id,'promotions')) with check (public.has_restaurant_permission(restaurant_id,'promotions'));
create policy "promotion products delete" on public.restaurant_promotion_products for delete to authenticated using (public.has_restaurant_permission(restaurant_id,'promotions'));

drop policy if exists "staff manage promotions" on public.restaurant_promotions;
drop policy if exists "public read active promotions" on public.restaurant_promotions;
create policy "promotions select" on public.restaurant_promotions for select to anon,authenticated
using ((active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now())) or public.has_restaurant_permission(restaurant_id,'promotions'));
create policy "promotions insert" on public.restaurant_promotions for insert to authenticated with check (public.has_restaurant_permission(restaurant_id,'promotions'));
create policy "promotions update" on public.restaurant_promotions for update to authenticated using (public.has_restaurant_permission(restaurant_id,'promotions')) with check (public.has_restaurant_permission(restaurant_id,'promotions'));
create policy "promotions delete" on public.restaurant_promotions for delete to authenticated using (public.has_restaurant_permission(restaurant_id,'promotions'));

drop policy if exists "staff manage reviews" on public.restaurant_reviews;
drop policy if exists "customers create reviews" on public.restaurant_reviews;
drop policy if exists "public read published reviews" on public.restaurant_reviews;
drop policy if exists "customers update own reviews" on public.restaurant_reviews;
create policy "reviews select" on public.restaurant_reviews for select to anon,authenticated
using (published or public.has_restaurant_permission(restaurant_id,'reviews'));
create policy "reviews insert" on public.restaurant_reviews for insert to authenticated
with check (
  public.has_restaurant_permission(restaurant_id,'reviews')
  or (customer_id=(select auth.uid()) and exists(select 1 from public.restaurant_orders o where o.id=order_id and o.customer_id=(select auth.uid()) and o.status='entregado'))
);
create policy "reviews update" on public.restaurant_reviews for update to authenticated
using (public.has_restaurant_permission(restaurant_id,'reviews') or customer_id=(select auth.uid()))
with check (public.has_restaurant_permission(restaurant_id,'reviews') or customer_id=(select auth.uid()));
create policy "reviews delete" on public.restaurant_reviews for delete to authenticated
using (public.has_restaurant_permission(restaurant_id,'reviews'));

drop policy if exists "restaurant settings admin write" on public.restaurant_settings;
create policy "restaurant settings insert" on public.restaurant_settings for insert to authenticated with check (public.is_site_admin());
create policy "restaurant settings update" on public.restaurant_settings for update to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
create policy "restaurant settings delete" on public.restaurant_settings for delete to authenticated using (public.is_site_admin());

drop policy if exists "managers manage staff" on public.restaurant_staff;
drop policy if exists "restaurant managers view staff" on public.restaurant_staff;
drop policy if exists "staff view own memberships" on public.restaurant_staff;
drop policy if exists "restaurant managers update staff" on public.restaurant_staff;
create policy "restaurant staff select" on public.restaurant_staff for select to authenticated
using (public.is_system_manager() or public.can_manage_restaurant_staff(restaurant_id) or user_id=(select auth.uid()) or public.is_site_admin());
create policy "restaurant staff insert" on public.restaurant_staff for insert to authenticated
with check (public.is_system_manager() and role in ('restaurant','editor','manager'));
create policy "restaurant staff update" on public.restaurant_staff for update to authenticated
using (public.is_system_manager() or (public.can_manage_restaurant_staff(restaurant_id) and role<>'restaurant'))
with check (
  (public.is_system_manager() and role in ('restaurant','editor','manager'))
  or (public.can_manage_restaurant_staff(restaurant_id) and role in ('manager','editor','cashier','kitchen','courier','waiter'))
);
create policy "restaurant staff delete" on public.restaurant_staff for delete to authenticated using (public.is_system_manager());

drop policy if exists "subscription history admins read" on public.restaurant_subscription_history;

drop policy if exists "restaurant owners manage whatsapp automations" on public.restaurant_whatsapp_automations;
drop policy if exists "restaurant members read whatsapp automations" on public.restaurant_whatsapp_automations;
create policy "whatsapp automations select" on public.restaurant_whatsapp_automations for select to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true));
create policy "whatsapp automations insert" on public.restaurant_whatsapp_automations for insert to authenticated
with check (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));
create policy "whatsapp automations update" on public.restaurant_whatsapp_automations for update to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')))
with check (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));
create policy "whatsapp automations delete" on public.restaurant_whatsapp_automations for delete to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));

drop policy if exists "restaurant owners manage whatsapp connection" on public.restaurant_whatsapp_connections;
drop policy if exists "restaurant members read whatsapp connection" on public.restaurant_whatsapp_connections;
create policy "whatsapp connections select" on public.restaurant_whatsapp_connections for select to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true));
create policy "whatsapp connections insert" on public.restaurant_whatsapp_connections for insert to authenticated
with check (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));
create policy "whatsapp connections update" on public.restaurant_whatsapp_connections for update to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')))
with check (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));
create policy "whatsapp connections delete" on public.restaurant_whatsapp_connections for delete to authenticated
using (exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurant_id and s.user_id=(select auth.uid()) and s.active=true and s.role in ('restaurant','manager')));

drop policy if exists "system managers manage restaurants" on public.restaurants;
drop policy if exists "public read active restaurants" on public.restaurants;
drop policy if exists "restaurant staff update own restaurant" on public.restaurants;
create policy "restaurants select" on public.restaurants for select to anon,authenticated using (active=true or public.is_system_manager());
create policy "restaurants insert" on public.restaurants for insert to authenticated with check (public.is_system_manager());
create policy "restaurants update" on public.restaurants for update to authenticated
using (
  public.is_system_manager()
  or exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurants.id and s.user_id=(select auth.uid()) and s.active and s.role='restaurant')
)
with check (
  public.is_system_manager()
  or exists(select 1 from public.restaurant_staff s where s.restaurant_id=restaurants.id and s.user_id=(select auth.uid()) and s.active and s.role='restaurant')
);
create policy "restaurants delete" on public.restaurants for delete to authenticated using (public.is_system_manager());

drop policy if exists "subscription providers admin manage" on public.subscription_payment_providers;
create policy "subscription providers insert" on public.subscription_payment_providers for insert to authenticated with check (public.is_site_admin());
create policy "subscription providers update" on public.subscription_payment_providers for update to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
create policy "subscription providers delete" on public.subscription_payment_providers for delete to authenticated using (public.is_site_admin());

drop policy if exists "admins manage profiles" on public.user_profiles;
drop policy if exists "users read own profile" on public.user_profiles;
create policy "user profiles select" on public.user_profiles for select to authenticated using (public.is_site_admin() or user_id=(select auth.uid()));
create policy "user profiles insert" on public.user_profiles for insert to authenticated with check (public.is_site_admin());
create policy "user profiles update" on public.user_profiles for update to authenticated using (public.is_site_admin()) with check (public.is_site_admin());
create policy "user profiles delete" on public.user_profiles for delete to authenticated using (public.is_site_admin());
