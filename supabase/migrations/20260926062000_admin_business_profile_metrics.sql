-- Admin profile scalability: aggregate 360 metrics without downloading operation histories
create or replace function public.admin_business_profile_metrics(p_restaurant_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.restaurants%rowtype;
  v_tz text;
  v_today date;
  v_today_start timestamptz;
  v_tomorrow_start timestamptz;
  v_week_start timestamptz;
  v_month_start timestamptz;
  v_type text;
  v_result jsonb;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  select * into r from public.restaurants where id=p_restaurant_id;
  if r.id is null then raise exception 'Negocio no encontrado'; end if;

  v_type:=coalesce(r.business_type,'restaurant');
  v_tz:=coalesce(nullif(r.timezone,''),'America/Santiago');
  v_today:=(now() at time zone v_tz)::date;
  v_today_start:=v_today::timestamp at time zone v_tz;
  v_tomorrow_start:=(v_today+1)::timestamp at time zone v_tz;
  v_week_start:=(v_today-6)::timestamp at time zone v_tz;
  v_month_start:=date_trunc('month',v_today::timestamp) at time zone v_tz;

  if v_type in ('supermarket','minimarket') then
    select jsonb_build_object(
      'type',v_type,
      'operations_total',(select count(*) from public.retail_sales s where s.restaurant_id=p_restaurant_id)+(select count(*) from public.retail_online_orders o where o.restaurant_id=p_restaurant_id),
      'today_activity',(select count(*) from public.retail_sales s where s.restaurant_id=p_restaurant_id and s.created_at>=v_today_start and s.created_at<v_tomorrow_start)+(select count(*) from public.retail_online_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_today_start and o.created_at<v_tomorrow_start),
      'week_activity',(select count(*) from public.retail_sales s where s.restaurant_id=p_restaurant_id and s.created_at>=v_week_start)+(select count(*) from public.retail_online_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_week_start),
      'month_activity',(select count(*) from public.retail_sales s where s.restaurant_id=p_restaurant_id and s.created_at>=v_month_start)+(select count(*) from public.retail_online_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_month_start),
      'online_active',(select count(*) from public.retail_online_orders o where o.restaurant_id=p_restaurant_id and o.status in ('received','preparing','ready')),
      'active_products',(select count(*) from public.retail_products p where p.restaurant_id=p_restaurant_id and p.active),
      'low_stock',(select count(*) from public.retail_products p where p.restaurant_id=p_restaurant_id and p.active and p.current_stock<=p.minimum_stock),
      'active_suppliers',(select count(*) from public.retail_suppliers s where s.restaurant_id=p_restaurant_id and s.active),
      'purchases_total',(select count(*) from public.retail_purchases p where p.restaurant_id=p_restaurant_id)
    ) into v_result;
  elsif v_type='professional' then
    select jsonb_build_object(
      'type',v_type,
      'appointments_total',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id),
      'week_created',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id and a.created_at>=v_week_start),
      'month_created',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id and a.created_at>=v_month_start),
      'today_appointments',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id and a.starts_at>=v_today_start and a.starts_at<v_tomorrow_start),
      'upcoming',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id and a.starts_at>now() and a.status not in ('cancelled','completed','no_show')),
      'completed',(select count(*) from public.professional_appointments a where a.restaurant_id=p_restaurant_id and a.status='completed'),
      'active_services',(select count(*) from public.professional_services s where s.restaurant_id=p_restaurant_id and s.active),
      'active_providers',(select count(*) from public.professional_providers p where p.restaurant_id=p_restaurant_id and p.active)
    ) into v_result;
  elsif v_type='streaming' then
    select jsonb_build_object(
      'type',v_type,
      'subscriptions_total',(select count(*) from public.streaming_subscriptions s where s.restaurant_id=p_restaurant_id),
      'subscriptions_active',(select count(*) from public.streaming_subscriptions s where s.restaurant_id=p_restaurant_id and s.status not in ('cancelled','paused') and s.expires_at>now()),
      'expiring_7d',(select count(*) from public.streaming_subscriptions s where s.restaurant_id=p_restaurant_id and s.status not in ('cancelled','paused') and s.expires_at>now() and s.expires_at<=now()+interval '7 days'),
      'expired',(select count(*) from public.streaming_subscriptions s where s.restaurant_id=p_restaurant_id and s.status not in ('cancelled','paused') and s.expires_at<=now()),
      'active_customers',(select count(*) from public.streaming_customers c where c.restaurant_id=p_restaurant_id and c.active),
      'active_accounts',(select count(*) from public.streaming_accounts a where a.restaurant_id=p_restaurant_id and a.active),
      'active_platforms',(select count(*) from public.streaming_platforms p where p.restaurant_id=p_restaurant_id and p.active),
      'renewals_month',(select count(*) from public.streaming_renewals x where x.restaurant_id=p_restaurant_id and x.created_at>=v_month_start)
    ) into v_result;
  else
    select jsonb_build_object(
      'type','restaurant',
      'orders_total',(select count(*) from public.restaurant_orders o where o.restaurant_id=p_restaurant_id),
      'today_orders',(select count(*) from public.restaurant_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_today_start and o.created_at<v_tomorrow_start),
      'week_orders',(select count(*) from public.restaurant_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_week_start),
      'month_orders',(select count(*) from public.restaurant_orders o where o.restaurant_id=p_restaurant_id and o.created_at>=v_month_start),
      'active_products',(select count(*) from public.restaurant_products p where p.restaurant_id=p_restaurant_id and p.available),
      'active_staff',(select count(*) from public.restaurant_staff s where s.restaurant_id=p_restaurant_id and s.active),
      'low_stock',(select count(*) from public.restaurant_inventory_items i where i.restaurant_id=p_restaurant_id and i.active and i.current_stock<=i.minimum_stock)
    ) into v_result;
  end if;

  return coalesce(v_result,'{}'::jsonb);
end
$$;

revoke all on function public.admin_business_profile_metrics(bigint) from public,anon;
grant execute on function public.admin_business_profile_metrics(bigint) to authenticated;
