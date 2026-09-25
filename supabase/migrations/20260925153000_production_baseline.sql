--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Debian 17.11-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: activate_admin_client_preview(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activate_admin_client_preview(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid:=auth.uid();
  v_sid text:=auth.jwt()->>'session_id';
  v_business public.restaurants%rowtype;
begin
  if v_uid is null or not public.is_site_admin() then
    raise exception 'Solo el administrador general puede activar esta vista de prueba';
  end if;
  if nullif(v_sid,'') is null then
    raise exception 'La sesión no tiene identificador válido';
  end if;

  select * into v_business
  from public.restaurants
  where id=p_restaurant_id
    and active is distinct from false;

  if not found then raise exception 'Negocio no encontrado'; end if;
  if not coalesce(v_business.is_demo,false) then
    raise exception 'La vista cliente automática del administrador solo está disponible para negocios demo';
  end if;

  delete from public.admin_client_preview_sessions where expires_at<=now();

  insert into public.admin_client_preview_sessions(session_id,user_id,restaurant_id,created_at,expires_at)
  values(v_sid,v_uid,p_restaurant_id,now(),now()+interval '2 hours')
  on conflict(session_id) do update
  set user_id=excluded.user_id,
      restaurant_id=excluded.restaurant_id,
      created_at=excluded.created_at,
      expires_at=excluded.expires_at;

  return jsonb_build_object(
    'active',true,
    'restaurant_id',p_restaurant_id,
    'expires_at',now()+interval '2 hours'
  );
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: restaurant_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_orders (
    id bigint NOT NULL,
    order_code text NOT NULL,
    customer_name text NOT NULL,
    customer_phone text,
    order_type text NOT NULL,
    delivery_address text,
    payment_method text NOT NULL,
    notes text,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric(12,2) NOT NULL,
    status text DEFAULT 'recibido'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    restaurant_id bigint,
    customer_id uuid,
    customer_email text,
    delivery_fee numeric DEFAULT 0 NOT NULL,
    delivery_distance_km numeric,
    delivery_latitude double precision,
    delivery_longitude double precision,
    payment_status text DEFAULT 'not_applicable'::text NOT NULL,
    mp_preference_id text,
    mp_payment_id text,
    paid_at timestamp with time zone,
    refund_status text,
    refunded_at timestamp with time zone,
    mp_refund_id text,
    kitchen_started_at timestamp with time zone,
    ready_at timestamp with time zone,
    delivered_at timestamp with time zone,
    inventory_deducted_at timestamp with time zone,
    assigned_courier_id uuid,
    order_source text DEFAULT 'online'::text NOT NULL,
    table_reference text,
    created_by uuid,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    payment_reference text,
    payment_verification_status text DEFAULT 'not_required'::text NOT NULL,
    restaurant_table_id bigint,
    kitchen_picked_up_at timestamp with time zone,
    mp_credential_source text,
    CONSTRAINT restaurant_orders_delivery_fee_check CHECK ((delivery_fee >= (0)::numeric)),
    CONSTRAINT restaurant_orders_mp_credential_source_check CHECK (((mp_credential_source IS NULL) OR (mp_credential_source = ANY (ARRAY['admin'::text, 'business'::text])))),
    CONSTRAINT restaurant_orders_order_source_check CHECK ((order_source = ANY (ARRAY['online'::text, 'waiter'::text, 'admin'::text, 'whatsapp'::text, 'cashier'::text, 'table_qr'::text]))),
    CONSTRAINT restaurant_orders_order_type_check CHECK ((order_type = ANY (ARRAY['Retiro'::text, 'Delivery'::text, 'Mesa'::text]))),
    CONSTRAINT restaurant_orders_payment_verification_status_check CHECK ((payment_verification_status = ANY (ARRAY['not_required'::text, 'pending'::text, 'approved'::text, 'rejected'::text]))),
    CONSTRAINT restaurant_orders_status_check CHECK ((status = ANY (ARRAY['recibido'::text, 'preparacion'::text, 'listo'::text, 'retirado_mesa'::text, 'en_camino'::text, 'entregado'::text, 'cancelado'::text]))),
    CONSTRAINT restaurant_orders_total_check CHECK ((total >= (0)::numeric))
);

ALTER TABLE ONLY public.restaurant_orders REPLICA IDENTITY FULL;


--
-- Name: add_table_qr_order_items(bigint, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_table_qr_order_items(p_order_id bigint, p_table_token uuid, p_items jsonb) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
  v_table public.restaurant_tables%rowtype;
  v_restaurant public.restaurants%rowtype;
  v_item jsonb;
  v_qty integer;
  v_unit numeric;
  v_product public.restaurant_products%rowtype;
  v_option public.restaurant_product_options%rowtype;
  v_option_id bigint;
  v_extra_id_text text;
  v_item_name text;
  v_extras jsonb;
  v_has_required_single boolean;
  v_clean_items jsonb := '[]'::jsonb;
  v_add_total numeric := 0;
  v_ing record;
begin
  select * into v_order from public.restaurant_orders o where o.id=p_order_id for update;
  if not found or v_order.order_source<>'table_qr' then raise exception 'Pedido QR no encontrado'; end if;

  select * into v_table from public.restaurant_tables t
   where t.id=v_order.restaurant_table_id and t.token=p_table_token and t.active=true limit 1;
  if not found then raise exception 'Este pedido no pertenece al QR actual'; end if;

  if v_order.status not in ('recibido','preparacion') then
    raise exception 'Este pedido ya no admite productos nuevos. Puedes hacer un pedido adicional.';
  end if;

  if lower(trim(coalesce(v_order.payment_method,''))) in ('mercado pago','qr bolivia')
     or lower(trim(coalesce(v_order.payment_status,'')))='approved' then
    raise exception 'Este pedido ya tiene un pago en línea iniciado o confirmado. Haz un pedido adicional para agregar productos.';
  end if;

  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Agrega al menos un producto'; end if;

  select * into v_restaurant from public.restaurants r
   where r.id=v_order.restaurant_id and r.active=true
     and r.subscription_status in ('trial','active') and r.subscription_expires_at>now();
  if not found then raise exception 'El restaurante no está disponible'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if nullif(v_item->>'product_id','') is null then raise exception 'Producto inválido'; end if;
    v_qty := greatest(1,least(99,coalesce((v_item->>'qty')::integer,1)));

    select * into v_product from public.restaurant_products p
     where p.id=(v_item->>'product_id')::bigint and p.restaurant_id=v_order.restaurant_id and p.available=true;
    if not found then raise exception 'Producto no disponible'; end if;

    v_unit:=coalesce(v_product.price,0);v_item_name:=v_product.name;v_extras:='[]'::jsonb;v_option_id:=null;

    if nullif(v_item->>'option_id','') is not null then
      v_option_id:=(v_item->>'option_id')::bigint;
      select o.* into v_option
      from public.restaurant_product_options o
      join public.restaurant_product_option_groups g on g.id=o.group_id
      where o.id=v_option_id and o.restaurant_id=v_order.restaurant_id and o.available=true
        and g.restaurant_id=v_order.restaurant_id and g.product_id=v_product.id and g.active=true and g.selection_type='single'
      limit 1;
      if not found then raise exception 'Opción de producto inválida'; end if;
      v_unit:=v_unit+coalesce(v_option.price_delta,0);v_item_name:=v_product.name||' '||v_option.name;
    else
      select exists(select 1 from public.restaurant_product_option_groups g
        where g.restaurant_id=v_order.restaurant_id and g.product_id=v_product.id
          and g.active=true and g.selection_type='single' and g.required=true) into v_has_required_single;
      if v_has_required_single then raise exception 'Selecciona una opción obligatoria para %',v_product.name; end if;
    end if;

    for v_extra_id_text in select value from jsonb_array_elements_text(coalesce(v_item->'extra_option_ids','[]'::jsonb))
    loop
      select o.* into v_option
      from public.restaurant_product_options o
      join public.restaurant_product_option_groups g on g.id=o.group_id
      where o.id=v_extra_id_text::bigint and o.restaurant_id=v_order.restaurant_id and o.available=true
        and g.restaurant_id=v_order.restaurant_id and g.product_id=v_product.id and g.active=true and g.selection_type='multiple'
      limit 1;
      if not found then raise exception 'Extra de producto inválido'; end if;
      v_unit:=v_unit+coalesce(v_option.price_delta,0);v_extras:=v_extras||jsonb_build_array(v_option.name);
    end loop;

    if v_unit<0 then raise exception 'Precio de producto inválido'; end if;
    v_add_total:=v_add_total+(v_qty*v_unit);
    v_clean_items:=v_clean_items||jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,'name',v_item_name,'qty',v_qty,'unit_price',v_unit,
      'extras',v_extras,'note',left(coalesce(v_item->>'note',''),500)
    ));

    if v_order.inventory_deducted_at is not null then
      for v_ing in select inventory_item_id,quantity_per_unit
       from public.restaurant_product_ingredients
       where restaurant_id=v_order.restaurant_id and product_id=v_product.id
      loop
        insert into public.restaurant_inventory_movements(
          restaurant_id,inventory_item_id,movement_type,quantity_delta,note,created_by
        ) values (
          v_order.restaurant_id,v_ing.inventory_item_id,'consumo',
          -(v_ing.quantity_per_unit*v_qty),'Agregado pedido '||v_order.order_code,auth.uid()
        );
      end loop;
    end if;
  end loop;

  if v_add_total<=0 then raise exception 'El total agregado no es válido'; end if;
  update public.restaurant_orders
     set items=coalesce(items,'[]'::jsonb)||v_clean_items,total=total+v_add_total,updated_at=now()
   where id=v_order.id returning * into v_order;
  return v_order;
end
$$;


--
-- Name: admin_business_directory_page(integer, integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_business_directory_page(p_limit integer DEFAULT 20, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_status text DEFAULT 'all'::text, p_business_type text DEFAULT 'all'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,20),1),100);
  v_offset integer := greatest(coalesce(p_offset,0),0);
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_result jsonb;
begin
  if not public.is_site_admin() then
    raise exception 'No autorizado';
  end if;

  with page as (
    select r.*
    from public.restaurants r
    where
      (coalesce(p_business_type,'all')='all' or r.business_type=p_business_type)
      and (
        coalesce(p_status,'all')='all'
        or (
          case
            when coalesce(r.subscription_status,'trial') in ('trial','active')
             and r.subscription_expires_at is not null
             and r.subscription_expires_at < now()
              then 'expired'
            else coalesce(r.subscription_status,'trial')
          end
        )=p_status
      )
      and (
        v_search is null
        or (
          coalesce(r.name,'') || ' ' ||
          coalesce(r.address,'') || ' ' ||
          coalesce(r.custom_domain,'') || ' ' ||
          coalesce(r.city,'') || ' ' ||
          coalesce(r.slug,'')
        ) ilike '%'||v_search||'%'
      )
    order by r.created_at desc, r.id desc
    offset v_offset
    limit v_limit
  ),
  total_count as (
    select count(*)::bigint as total
    from public.restaurants r
    where
      (coalesce(p_business_type,'all')='all' or r.business_type=p_business_type)
      and (
        coalesce(p_status,'all')='all'
        or (
          case
            when coalesce(r.subscription_status,'trial') in ('trial','active')
             and r.subscription_expires_at is not null
             and r.subscription_expires_at < now()
              then 'expired'
            else coalesce(r.subscription_status,'trial')
          end
        )=p_status
      )
      and (
        v_search is null
        or (
          coalesce(r.name,'') || ' ' ||
          coalesce(r.address,'') || ' ' ||
          coalesce(r.custom_domain,'') || ' ' ||
          coalesce(r.city,'') || ' ' ||
          coalesce(r.slug,'')
        ) ilike '%'||v_search||'%'
      )
  ),
  counts as (
    select
      count(*) filter (
        where r.business_type='restaurant'
          and r.active is distinct from false
          and (
            case
              when coalesce(r.subscription_status,'trial') in ('trial','active')
               and r.subscription_expires_at is not null
               and r.subscription_expires_at < now()
                then 'expired'
              else coalesce(r.subscription_status,'trial')
            end
          ) in ('active','trial')
      )::bigint as restaurants,
      count(*) filter (
        where r.business_type='supermarket'
          and r.active is distinct from false
          and (
            case
              when coalesce(r.subscription_status,'trial') in ('trial','active')
               and r.subscription_expires_at is not null
               and r.subscription_expires_at < now()
                then 'expired'
              else coalesce(r.subscription_status,'trial')
            end
          ) in ('active','trial')
      )::bigint as supermarkets,
      count(*) filter (
        where r.business_type='minimarket'
          and r.active is distinct from false
          and (
            case
              when coalesce(r.subscription_status,'trial') in ('trial','active')
               and r.subscription_expires_at is not null
               and r.subscription_expires_at < now()
                then 'expired'
              else coalesce(r.subscription_status,'trial')
            end
          ) in ('active','trial')
      )::bigint as minimarkets,
      count(*) filter (
        where r.business_type='professional'
          and r.active is distinct from false
          and (
            case
              when coalesce(r.subscription_status,'trial') in ('trial','active')
               and r.subscription_expires_at is not null
               and r.subscription_expires_at < now()
                then 'expired'
              else coalesce(r.subscription_status,'trial')
            end
          ) in ('active','trial')
      )::bigint as professionals,
      count(*) filter (
        where r.business_type='streaming'
          and r.active is distinct from false
          and (
            case
              when coalesce(r.subscription_status,'trial') in ('trial','active')
               and r.subscription_expires_at is not null
               and r.subscription_expires_at < now()
                then 'expired'
              else coalesce(r.subscription_status,'trial')
            end
          ) in ('active','trial')
      )::bigint as streaming
    from public.restaurants r
  )
  select jsonb_build_object(
    'total',(select total from total_count),
    'rows',coalesce(
      (select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.id desc) from page p),
      '[]'::jsonb
    ),
    'counts',(
      select jsonb_build_object(
        'restaurants',restaurants,
        'supermarkets',supermarkets,
        'minimarkets',minimarkets,
        'professionals',professionals,
        'streaming',streaming,
        'total',restaurants+supermarkets+minimarkets+professionals+streaming
      )
      from counts
    )
  )
  into v_result;

  return v_result;
end
$$;


--
-- Name: admin_dashboard_metrics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_dashboard_metrics() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v jsonb;
begin
  if not public.is_site_admin() then
    raise exception 'not authorized';
  end if;
  select jsonb_build_object(
    'restaurants',(select count(*) from public.restaurants),
    'active_subscriptions',(select count(*) from public.restaurants r where coalesce(r.subscription_status,'') in ('active','trial') or (r.trial_ends_at is not null and r.trial_ends_at > now())),
    'plans',(select count(*) from public.subscription_plans p where p.active=true),
    'products',(select count(*) from public.restaurant_products),
    'categories',(select count(*) from public.restaurant_categories),
    'orders',(select count(*) from public.restaurant_orders where payment_method='Mercado Pago' and payment_status='approved'),
    'restaurant_options',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) order by r.name),'[]'::jsonb) from public.restaurants r)
  ) into v;
  return v;
end;
$$;


--
-- Name: admin_dashboard_overview(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_dashboard_overview(p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_result jsonb;
begin
  if not public.is_site_admin() then
    raise exception 'No autorizado';
  end if;

  with all_activity as (
    select
      'restaurant_order'::text as activity_type,
      o.id,
      o.restaurant_id,
      o.order_code,
      o.customer_name,
      o.customer_id,
      o.status,
      o.created_at
    from public.restaurant_orders o
    where p_restaurant_id is null or o.restaurant_id=p_restaurant_id

    union all

    select
      'retail_order'::text,
      o.id,
      o.restaurant_id,
      o.order_code,
      o.customer_name,
      o.customer_id,
      o.status,
      o.created_at
    from public.retail_online_orders o
    where p_restaurant_id is null or o.restaurant_id=p_restaurant_id

    union all

    select
      'professional_booking'::text,
      a.id,
      a.restaurant_id,
      null::text,
      a.customer_name,
      a.customer_id,
      a.status,
      a.created_at
    from public.professional_appointments a
    where p_restaurant_id is null or a.restaurant_id=p_restaurant_id
  ),
  metrics as (
    select
      count(*)::bigint as activity_count,
      count(*) filter (where created_at>=date_trunc('day',now()))::bigint as today_count,
      count(*) filter (where created_at>=date_trunc('day',now())-interval '6 days')::bigint as week_count,
      count(*) filter (where created_at>=date_trunc('month',now()))::bigint as month_count,
      count(distinct customer_id)::bigint as customer_count
    from all_activity
  ),
  daily_raw as (
    select date_trunc('day',created_at)::date as day,count(*)::bigint as count
    from all_activity
    where created_at>=date_trunc('day',now())-interval '6 days'
    group by 1
  ),
  daily as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object('day',d.day::date,'count',coalesce(r.count,0))
        order by d.day
      ),
      '[]'::jsonb
    ) as rows
    from generate_series(
      date_trunc('day',now())-interval '6 days',
      date_trunc('day',now()),
      interval '1 day'
    ) as d(day)
    left join daily_raw r on r.day=d.day::date
  ),
  recent_activity as (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) as rows
    from (
      select
        a.activity_type,a.id,a.order_code,a.restaurant_id,
        r.name as restaurant_name,a.customer_name,a.status,a.created_at
      from all_activity a
      left join public.restaurants r on r.id=a.restaurant_id
      order by a.created_at desc
      limit 16
    ) x
  ),
  recent_subscriptions as (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) as rows
    from (
      select
        h.id,h.restaurant_id,r.name as restaurant_name,h.action,h.new_status,
        h.amount,h.created_at,coalesce(r.currency_code,'CLP') as currency_code
      from public.restaurant_subscription_history h
      left join public.restaurants r on r.id=h.restaurant_id
      where p_restaurant_id is null or h.restaurant_id=p_restaurant_id
      order by h.created_at desc
      limit 20
    ) x
  ),
  selected as (
    select to_jsonb(r) as row
    from public.restaurants r
    where r.id=p_restaurant_id
  ),
  active_businesses as (
    select
      count(distinct restaurant_id) filter (
        where created_at>=date_trunc('day',now())-interval '6 days'
      )::bigint as active_7d,
      count(distinct restaurant_id) filter (
        where created_at>=date_trunc('day',now())-interval '29 days'
      )::bigint as active_30d
    from all_activity
  )
  select jsonb_build_object(
    'orders',(select activity_count from metrics),
    'valid_orders',(select activity_count from metrics),
    'customers',(select customer_count from metrics),
    'today_orders',(select today_count from metrics),
    'week_orders',(select week_count from metrics),
    'month_orders',(select month_count from metrics),
    'active_businesses_7d',(select active_7d from active_businesses),
    'active_businesses_30d',(select active_30d from active_businesses),
    'sales','[]'::jsonb,
    'today_sales','[]'::jsonb,
    'daily',(select rows from daily),
    'recent_orders',(select rows from recent_activity),
    'recent_subscriptions',(select rows from recent_subscriptions),
    'registered_customers',(select count(*) from public.customer_profiles),
    'active_plans',(select count(*) from public.subscription_plans where active=true),
    'product_count',case
      when p_restaurant_id is null then null
      else (select count(*) from public.restaurant_products where restaurant_id=p_restaurant_id)
    end,
    'selected_business',(select row from selected)
  )
  into v_result;

  return v_result;
end
$$;


--
-- Name: admin_delete_subscription_plan(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_subscription_plan(p_plan_id bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_approved integer;
begin
  if not exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  ) then
    raise exception 'Solo el administrador puede eliminar planes';
  end if;

  if exists(select 1 from public.subscription_plans where id=p_plan_id and is_default_trial=true) then
    raise exception 'La prueba gratuita predeterminada no se puede eliminar';
  end if;

  select count(*) into v_approved
  from public.subscription_payments
  where plan_id = p_plan_id
    and status = 'approved';

  if v_approved > 0 then
    update public.subscription_plans
       set active = false, updated_at = now()
     where id = p_plan_id;
    return 'archived';
  end if;

  delete from public.subscription_payments where plan_id = p_plan_id;
  delete from public.subscription_plans where id = p_plan_id;

  return 'deleted';
end
$$;


--
-- Name: admin_general_metrics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_general_metrics() RETURNS TABLE(restaurants bigint, active_subscriptions bigint, plans bigint, products bigint, categories bigint, orders bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select
 (select count(*) from public.restaurants),
 (select count(*) from public.restaurants r where coalesce(r.subscription_status,'') in ('active','trial') and (r.subscription_expires_at is null or r.subscription_expires_at >= now())),
 (select count(*) from public.subscription_plans p where p.active=true),
 (select count(*) from public.restaurant_products),
 (select count(*) from public.restaurant_categories),
 (
   (select count(*) from public.restaurant_orders) +
   (select count(*) from public.retail_online_orders) +
   (select count(*) from public.professional_appointments)
 )
 where public.is_site_admin();
$$;


--
-- Name: admin_get_business_payment_test_credentials(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_business_payment_test_credentials(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_status jsonb;
begin
  if not public.is_site_admin() then
    raise exception 'No autorizado';
  end if;

  select public.business_payment_public_status(p_restaurant_id) into v_status;
  if v_status is null then raise exception 'Negocio no encontrado'; end if;
  return v_status;
end;
$$;


--
-- Name: admin_observability_summary(integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_observability_summary(p_days integer DEFAULT 1, p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_since timestamptz:=now()-make_interval(days=>greatest(coalesce(p_days,1),1));
  v_events bigint;
  v_system_errors bigint;
  v_user_errors bigint;
  v_open_reports bigint;
  v_top_restaurant jsonb;
  v_top_client jsonb;
  v_error_codes jsonb;
  v_plan_interest jsonb;
  v_recent_reports jsonb;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  select count(*) into v_events from public.app_events
   where occurred_at>=v_since and (p_restaurant_id is null or restaurant_id=p_restaurant_id);

  select
    count(*) filter(where not is_user_error),
    count(*) filter(where is_user_error)
  into v_system_errors,v_user_errors
  from public.app_errors
  where occurred_at>=v_since and (p_restaurant_id is null or restaurant_id=p_restaurant_id);

  select count(*) into v_open_reports from public.user_issue_reports
   where status in ('open','reviewing') and (p_restaurant_id is null or restaurant_id=p_restaurant_id);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.events desc),'[]'::jsonb) into v_top_restaurant
  from (
    select module,count(*)::bigint events
    from public.app_events
    where occurred_at>=v_since and app_context='restaurant' and module is not null
      and (p_restaurant_id is null or restaurant_id=p_restaurant_id)
    group by module order by count(*) desc limit 8
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.events desc),'[]'::jsonb) into v_top_client
  from (
    select module,count(*)::bigint events
    from public.app_events
    where occurred_at>=v_since and app_context='client' and module is not null
      and (p_restaurant_id is null or restaurant_id=p_restaurant_id)
    group by module order by count(*) desc limit 8
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.errors desc),'[]'::jsonb) into v_error_codes
  from (
    select app_context,category,coalesce(error_code,'sin_codigo') error_code,is_user_error,count(*)::bigint errors,max(occurred_at) last_seen
    from public.app_errors
    where occurred_at>=v_since and (p_restaurant_id is null or restaurant_id=p_restaurant_id)
    group by app_context,category,coalesce(error_code,'sin_codigo'),is_user_error
    order by count(*) desc limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.interest_count desc),'[]'::jsonb) into v_plan_interest
  from (
    select p.id plan_id,p.name plan_name,count(*)::bigint interest_count
    from public.restaurants r
    join public.subscription_plans p on p.id=r.trial_intended_plan_id
    where (p_restaurant_id is null or r.id=p_restaurant_id)
    group by p.id,p.name order by count(*) desc
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_recent_reports
  from (
    select i.id,i.created_at,i.app_context,i.restaurant_id,r.name restaurant_name,i.title,i.status
    from public.user_issue_reports i
    left join public.restaurants r on r.id=i.restaurant_id
    where (p_restaurant_id is null or i.restaurant_id=p_restaurant_id)
    order by i.created_at desc limit 8
  ) x;

  return jsonb_build_object(
    'days',greatest(coalesce(p_days,1),1),
    'total_events',coalesce(v_events,0),
    'system_errors',coalesce(v_system_errors,0),
    'user_errors',coalesce(v_user_errors,0),
    'open_reports',coalesce(v_open_reports,0),
    'top_restaurant_modules',coalesce(v_top_restaurant,'[]'::jsonb),
    'top_client_modules',coalesce(v_top_client,'[]'::jsonb),
    'error_codes',coalesce(v_error_codes,'[]'::jsonb),
    'plan_interest',coalesce(v_plan_interest,'[]'::jsonb),
    'recent_reports',coalesce(v_recent_reports,'[]'::jsonb),
    'generated_at',now()
  );
end
$$;


--
-- Name: admin_plan_recommendations(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_plan_recommendations(p_days integer DEFAULT 30) RETURNS TABLE(restaurant_id bigint, restaurant_name text, intended_plan_id bigint, intended_plan_name text, recommended_plan_id bigint, recommended_plan_name text, modules_used jsonb, module_count bigint, recommendation_reason text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
with allowed as (
  select 1 where public.is_site_admin()
), normalized as (
  select distinct e.restaurant_id,
    case when e.module='table_qr' then 'pos' when e.module='plans' then null else e.module end as module
  from public.app_events e
  where e.app_context='restaurant'
    and e.restaurant_id is not null
    and e.module is not null
    and e.occurred_at>=now()-make_interval(days=>greatest(coalesce(p_days,30),1))
), used as (
  select n.restaurant_id,jsonb_agg(n.module order by n.module) modules_used,count(*)::bigint module_count
  from normalized n where n.module is not null group by n.restaurant_id
)
select r.id,r.name,
       r.trial_intended_plan_id,ip.name,
       rec.id,rec.name,
       coalesce(u.modules_used,'[]'::jsonb),coalesce(u.module_count,0),
       case
         when coalesce(u.module_count,0)=0 and r.trial_intended_plan_id is not null then 'Sin uso suficiente todavía; se conserva el plan que interesó al registrarse'
         when coalesce(u.module_count,0)=0 then 'Todavía no hay uso suficiente para sugerir un plan'
         when rec.id is null then 'El uso actual requiere revisar módulos o crear un plan superior'
         else 'Plan mínimo del tipo de negocio que cubre los módulos utilizados durante el período'
       end
from allowed a
cross join public.restaurants r
left join used u on u.restaurant_id=r.id
left join public.subscription_plans ip on ip.id=r.trial_intended_plan_id
left join lateral (
  select p.id,p.name,p.amount
  from public.subscription_plans p
  where p.active=true
    and coalesce(p.is_default_trial,false)=false
    and p.business_type=coalesce(r.business_type,'restaurant')
    and coalesce(u.module_count,0)>0
    and not exists (
      select 1 from jsonb_array_elements_text(coalesce(u.modules_used,'[]'::jsonb)) m
      where not (p.modules ? m.value)
    )
  order by p.amount asc,p.id asc
  limit 1
) rec on true
order by r.id
$$;


--
-- Name: admin_plan_recommendations_page(integer, integer, integer, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_plan_recommendations_page(p_days integer DEFAULT 30, p_limit integer DEFAULT 10, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS TABLE(restaurant_id bigint, restaurant_name text, intended_plan_id bigint, intended_plan_name text, recommended_plan_id bigint, recommended_plan_name text, modules_used jsonb, module_count bigint, recommendation_reason text, total_count bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
with allowed as (
  select 1 where public.is_site_admin()
),
filtered_restaurants as (
  select r.*
  from allowed a
  cross join public.restaurants r
  where (p_restaurant_id is null or r.id = p_restaurant_id)
    and (
      coalesce(btrim(p_search),'') = ''
      or r.name ilike '%' || btrim(p_search) || '%'
      or r.slug ilike '%' || btrim(p_search) || '%'
      or coalesce(r.city,'') ilike '%' || btrim(p_search) || '%'
    )
),
total as (
  select count(*)::bigint as total_count
  from filtered_restaurants
),
page as (
  select r.*
  from filtered_restaurants r
  order by r.id
  offset greatest(coalesce(p_offset,0),0)
  limit least(greatest(coalesce(p_limit,10),1),100)
),
normalized as (
  select distinct e.restaurant_id,
    case
      when e.module='table_qr' then 'pos'
      when e.module='plans' then null
      else e.module
    end as module
  from public.app_events e
  join page r on r.id=e.restaurant_id
  where e.app_context='restaurant'
    and e.module is not null
    and e.occurred_at>=now()-make_interval(days=>greatest(coalesce(p_days,30),1))
),
used as (
  select n.restaurant_id,
         jsonb_agg(n.module order by n.module) as modules_used,
         count(*)::bigint as module_count
  from normalized n
  where n.module is not null
  group by n.restaurant_id
)
select r.id,
       r.name,
       r.trial_intended_plan_id,
       ip.name,
       rec.id,
       rec.name,
       coalesce(u.modules_used,'[]'::jsonb),
       coalesce(u.module_count,0),
       case
         when coalesce(u.module_count,0)=0 and r.trial_intended_plan_id is not null
           then 'Sin uso suficiente todavía; se conserva el plan que interesó al registrarse'
         when coalesce(u.module_count,0)=0
           then 'Todavía no hay uso suficiente para sugerir un plan'
         when rec.id is null
           then 'El uso actual requiere revisar módulos o crear un plan superior'
         else 'Plan mínimo del tipo de negocio que cubre los módulos utilizados durante el período'
       end,
       t.total_count
from page r
cross join total t
left join used u on u.restaurant_id=r.id
left join public.subscription_plans ip on ip.id=r.trial_intended_plan_id
left join lateral (
  select p.id,p.name,p.amount
  from public.subscription_plans p
  where p.active=true
    and coalesce(p.is_default_trial,false)=false
    and p.business_type=coalesce(r.business_type,'restaurant')
    and coalesce(u.module_count,0)>0
    and not exists (
      select 1
      from jsonb_array_elements_text(coalesce(u.modules_used,'[]'::jsonb)) m
      where not (p.modules ? m.value)
    )
  order by p.amount asc,p.id asc
  limit 1
) rec on true
order by r.id
$$;


--
-- Name: admin_retail_summary(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_retail_summary(p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_supermarkets bigint;
  v_minimarkets bigint;
  v_products bigint;
  v_low_stock bigint;
  v_sales_30d bigint;
  v_purchases_30d bigint;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  select count(*) filter(where business_type='supermarket'),
         count(*) filter(where business_type='minimarket')
    into v_supermarkets,v_minimarkets
  from public.restaurants
  where active=true and (p_restaurant_id is null or id=p_restaurant_id);

  select count(*) filter(where p.active),
         count(*) filter(where p.active and p.current_stock<=p.minimum_stock)
    into v_products,v_low_stock
  from public.retail_products p
  where (p_restaurant_id is null or p.restaurant_id=p_restaurant_id);

  select count(*) into v_sales_30d
  from public.retail_sales s
  where s.status='completed'
    and s.created_at>=now()-interval '30 days'
    and (p_restaurant_id is null or s.restaurant_id=p_restaurant_id);

  select count(*) into v_purchases_30d
  from public.retail_purchases p
  where p.status='received'
    and p.created_at>=now()-interval '30 days'
    and (p_restaurant_id is null or p.restaurant_id=p_restaurant_id);

  return jsonb_build_object(
    'supermarkets',coalesce(v_supermarkets,0),
    'minimarkets',coalesce(v_minimarkets,0),
    'active_products',coalesce(v_products,0),
    'low_stock',coalesce(v_low_stock,0),
    'sales_30d',coalesce(v_sales_30d,0),
    'purchases_30d',coalesce(v_purchases_30d,0)
  );
end;
$$;


--
-- Name: admin_set_business_payment_test_credentials(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_business_payment_test_credentials(p_restaurant_id bigint, p_enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_r public.restaurants%rowtype;
  v_conn public.restaurant_payment_connections%rowtype;
  v_cfg public.subscription_payment_settings%rowtype;
  v_override public.business_payment_test_overrides%rowtype;
  v_pending integer:=0;
begin
  if not public.is_site_admin() then
    raise exception 'No autorizado';
  end if;

  select * into v_r
  from public.restaurants
  where id=p_restaurant_id
  for update;

  if v_r.id is null then
    raise exception 'Negocio no encontrado';
  end if;

  select * into v_override
  from public.business_payment_test_overrides
  where restaurant_id=p_restaurant_id
  for update;

  if coalesce(p_enabled,false) then
    select * into v_cfg
    from public.subscription_payment_settings
    order by id
    limit 1;

    if v_cfg.id is null
       or nullif(trim(coalesce(v_cfg.public_key,'')),'') is null
       or nullif(trim(coalesce(v_cfg.access_token,'')),'') is null then
      raise exception 'Las credenciales del administrador no están configuradas';
    end if;

    select * into v_conn
    from public.restaurant_payment_connections
    where restaurant_id=p_restaurant_id;

    insert into public.business_payment_test_overrides(
      restaurant_id,enabled,updated_by,updated_at,
      business_public_key_backup,business_access_token_backup,business_mp_user_id_backup,
      business_connection_existed,backup_taken_at
    ) values(
      p_restaurant_id,true,auth.uid(),now(),
      v_r.mercadopago_public_key,v_conn.access_token,v_conn.mp_user_id,
      v_conn.restaurant_id is not null,now()
    )
    on conflict (restaurant_id) do update
    set enabled=true,
        updated_by=auth.uid(),
        updated_at=now(),
        business_public_key_backup=case
          when public.business_payment_test_overrides.enabled then public.business_payment_test_overrides.business_public_key_backup
          else excluded.business_public_key_backup
        end,
        business_access_token_backup=case
          when public.business_payment_test_overrides.enabled then public.business_payment_test_overrides.business_access_token_backup
          else excluded.business_access_token_backup
        end,
        business_mp_user_id_backup=case
          when public.business_payment_test_overrides.enabled then public.business_payment_test_overrides.business_mp_user_id_backup
          else excluded.business_mp_user_id_backup
        end,
        business_connection_existed=case
          when public.business_payment_test_overrides.enabled then public.business_payment_test_overrides.business_connection_existed
          else excluded.business_connection_existed
        end,
        backup_taken_at=case
          when public.business_payment_test_overrides.enabled then public.business_payment_test_overrides.backup_taken_at
          else now()
        end;

    update public.restaurants
    set mercadopago_public_key=v_cfg.public_key,updated_at=now()
    where id=p_restaurant_id;

    insert into public.restaurant_payment_connections(
      restaurant_id,provider,access_token,mp_user_id,connected_at,updated_at
    ) values(
      p_restaurant_id,'mercadopago',v_cfg.access_token,null,now(),now()
    )
    on conflict (restaurant_id) do update
    set provider='mercadopago',
        access_token=excluded.access_token,
        mp_user_id=null,
        updated_at=now();
  else
    if v_override.restaurant_id is not null and v_override.enabled then
      select count(*) into v_pending
      from (
        select 1 from public.restaurant_orders
        where restaurant_id=p_restaurant_id and mp_credential_source='admin'
          and mp_preference_id is not null and coalesce(payment_status,'pending') in ('pending','processing')
        union all
        select 1 from public.retail_online_orders
        where restaurant_id=p_restaurant_id and mp_credential_source='admin'
          and mp_preference_id is not null and coalesce(payment_status,'pending') in ('pending','processing')
        union all
        select 1 from public.professional_booking_payment_intents
        where restaurant_id=p_restaurant_id and mp_credential_source='admin'
          and mp_preference_id is not null and coalesce(payment_status,'pending') in ('pending','processing')
        union all
        select 1 from public.professional_appointments
        where restaurant_id=p_restaurant_id and mp_credential_source='admin'
          and mp_preference_id is not null and coalesce(payment_status,'pending') in ('pending','processing')
        union all
        select 1 from public.streaming_orders
        where restaurant_id=p_restaurant_id and mp_credential_source='admin'
          and mp_preference_id is not null and coalesce(payment_status,'pending') in ('pending','processing')
      ) x;

      if v_pending>0 then
        raise exception 'No puedes desactivar todavía: hay % pago(s) pendiente(s) iniciado(s) con las credenciales del administrador.',v_pending;
      end if;

      update public.restaurants
      set mercadopago_public_key=v_override.business_public_key_backup,updated_at=now()
      where id=p_restaurant_id;

      if v_override.business_connection_existed then
        insert into public.restaurant_payment_connections(
          restaurant_id,provider,access_token,mp_user_id,connected_at,updated_at
        ) values(
          p_restaurant_id,'mercadopago',
          v_override.business_access_token_backup,
          v_override.business_mp_user_id_backup,
          now(),now()
        )
        on conflict (restaurant_id) do update
        set provider='mercadopago',
            access_token=excluded.access_token,
            mp_user_id=excluded.mp_user_id,
            updated_at=now();
      else
        delete from public.restaurant_payment_connections
        where restaurant_id=p_restaurant_id;
      end if;

      update public.business_payment_test_overrides
      set enabled=false,updated_by=auth.uid(),updated_at=now()
      where restaurant_id=p_restaurant_id;
    end if;
  end if;

  return public.business_payment_public_status(p_restaurant_id);
end;
$$;


--
-- Name: restaurants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurants (
    id bigint NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    custom_domain text,
    whatsapp text DEFAULT ''::text NOT NULL,
    address text DEFAULT ''::text NOT NULL,
    instagram text DEFAULT ''::text NOT NULL,
    open_time time without time zone DEFAULT '20:30:00'::time without time zone NOT NULL,
    close_time time without time zone DEFAULT '23:30:00'::time without time zone NOT NULL,
    pickup_eta text DEFAULT '20–30 min'::text NOT NULL,
    delivery_eta text DEFAULT '35–50 min'::text NOT NULL,
    delivery_note text DEFAULT 'Envío a confirmar'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    delivery_pricing_mode text DEFAULT 'fixed'::text NOT NULL,
    delivery_fixed_price numeric DEFAULT 0 NOT NULL,
    delivery_zones jsonb DEFAULT '[]'::jsonb NOT NULL,
    latitude double precision,
    longitude double precision,
    logo_url text,
    subscription_status text DEFAULT 'trial'::text NOT NULL,
    subscription_started_at timestamp with time zone,
    subscription_expires_at timestamp with time zone,
    subscription_plan text DEFAULT 'Prueba 30 días'::text NOT NULL,
    subscription_price numeric(12,2) DEFAULT 0 NOT NULL,
    subscription_notes text DEFAULT ''::text NOT NULL,
    mercadopago_public_key text,
    manual_open_status text,
    theme_primary_color text,
    theme_secondary_color text,
    theme_text_color text,
    subscription_plan_id bigint,
    mp_subscription_id text,
    mp_subscription_status text,
    mp_next_payment_date timestamp with time zone,
    mp_last_payment_status text,
    subscription_module_overrides jsonb DEFAULT '[]'::jsonb NOT NULL,
    country_code text DEFAULT 'CL'::text NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    locale text DEFAULT 'es-CL'::text NOT NULL,
    timezone text DEFAULT 'America/Santiago'::text NOT NULL,
    subscription_modules_customized boolean DEFAULT false NOT NULL,
    flow_customer_id text,
    flow_subscription_id text,
    flow_subscription_status text,
    flow_next_invoice_date timestamp with time zone,
    flow_last_payment_status text,
    flow_plan_id text,
    flow_card_brand text,
    flow_card_last4 text,
    subscription_billing_cycle text,
    subscription_bonus_months integer DEFAULT 0 NOT NULL,
    trial_intended_plan_id bigint,
    trial_intended_plan_selected_at timestamp with time zone,
    business_type text DEFAULT 'restaurant'::text NOT NULL,
    accept_cash boolean DEFAULT true NOT NULL,
    accept_bank_transfer boolean DEFAULT true NOT NULL,
    accept_mercadopago boolean DEFAULT true NOT NULL,
    professional_booking_auto_confirm boolean DEFAULT true NOT NULL,
    professional_booking_min_notice_hours integer DEFAULT 2 NOT NULL,
    professional_booking_max_days integer DEFAULT 60 NOT NULL,
    professional_booking_deposit_required boolean DEFAULT false NOT NULL,
    professional_booking_deposit_amount numeric DEFAULT 0 NOT NULL,
    professional_booking_payment_mode text DEFAULT 'full'::text,
    is_demo boolean DEFAULT false NOT NULL,
    use_demo_api_defaults boolean DEFAULT false NOT NULL,
    demo_api_synced_at timestamp with time zone,
    city text DEFAULT ''::text NOT NULL,
    CONSTRAINT restaurants_business_type_check CHECK ((business_type = ANY (ARRAY['restaurant'::text, 'supermarket'::text, 'minimarket'::text, 'professional'::text, 'streaming'::text]))),
    CONSTRAINT restaurants_delivery_fixed_price_check CHECK ((delivery_fixed_price >= (0)::numeric)),
    CONSTRAINT restaurants_delivery_pricing_mode_check CHECK ((delivery_pricing_mode = ANY (ARRAY['fixed'::text, 'distance'::text]))),
    CONSTRAINT restaurants_manual_open_status_check CHECK (((manual_open_status IS NULL) OR (manual_open_status = ANY (ARRAY['open'::text, 'closed'::text])))),
    CONSTRAINT restaurants_professional_booking_deposit_amount_check CHECK ((professional_booking_deposit_amount >= (0)::numeric)),
    CONSTRAINT restaurants_professional_booking_max_days_check CHECK (((professional_booking_max_days >= 1) AND (professional_booking_max_days <= 365))),
    CONSTRAINT restaurants_professional_booking_min_notice_check CHECK ((professional_booking_min_notice_hours >= 0)),
    CONSTRAINT restaurants_professional_booking_payment_mode_check CHECK ((professional_booking_payment_mode = ANY (ARRAY['none'::text, 'deposit'::text, 'full'::text]))),
    CONSTRAINT restaurants_subscription_module_overrides_is_array CHECK ((jsonb_typeof(subscription_module_overrides) = 'array'::text)),
    CONSTRAINT restaurants_subscription_status_check CHECK ((subscription_status = ANY (ARRAY['trial'::text, 'active'::text, 'expired'::text, 'suspended'::text])))
);


--
-- Name: COLUMN restaurants.accept_cash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.restaurants.accept_cash IS 'Whether cash is shown as a customer payment method.';


--
-- Name: COLUMN restaurants.accept_bank_transfer; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.restaurants.accept_bank_transfer IS 'Whether configured bank transfer methods are shown to customers.';


--
-- Name: COLUMN restaurants.accept_mercadopago; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.restaurants.accept_mercadopago IS 'Whether Mercado Pago is shown when country support and valid credentials are available.';


--
-- Name: admin_set_restaurant_subscription_access(bigint, bigint, jsonb, numeric, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_restaurant_subscription_access(p_restaurant_id bigint, p_plan_id bigint, p_selected_modules jsonb, p_price numeric, p_expires_at timestamp with time zone, p_notes text) RETURNS public.restaurants
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  r_old public.restaurants%rowtype;
  r_new public.restaurants%rowtype;
  p public.subscription_plans%rowtype;
  v_base jsonb := '[]'::jsonb;
  v_selected jsonb := public.normalize_module_array(coalesce(p_selected_modules,'[]'::jsonb));
  v_custom boolean := false;
  v_status text;
  v_expiry timestamptz;
begin
  if not public.is_site_admin() then
    raise exception 'Solo el administrador general puede modificar accesos de suscripción';
  end if;

  select * into r_old from public.restaurants where id=p_restaurant_id for update;
  if not found then raise exception 'Restaurante no encontrado'; end if;

  if p_plan_id is null then
    select * into p from public.subscription_plans where is_default_trial=true limit 1;
  else
    select * into p from public.subscription_plans where id=p_plan_id;
  end if;

  if not found then raise exception 'Plan no encontrado'; end if;

  v_base := public.normalize_module_array(coalesce(p.modules,'[]'::jsonb));
  v_custom := v_selected <> v_base;
  v_status := case when p.is_default_trial then 'trial' else 'active' end;
  v_expiry := coalesce(
    p_expires_at,
    case when p.is_default_trial then now()+make_interval(days=>greatest(p.days,1))
         else r_old.subscription_expires_at end
  );

  update public.restaurants
  set subscription_plan_id = p.id,
      subscription_plan = p.name,
      subscription_status = v_status,
      subscription_price = case when p.is_default_trial then 0 else greatest(coalesce(p_price,p.amount,0),0) end,
      subscription_expires_at = v_expiry,
      subscription_notes = coalesce(p_notes,''),
      subscription_modules_customized = v_custom,
      subscription_module_overrides = case when v_custom then v_selected else '[]'::jsonb end,
      updated_at = now()
  where id=p_restaurant_id
  returning * into r_new;

  insert into public.restaurant_subscription_history(
    restaurant_id,action,previous_status,new_status,
    previous_expires_at,new_expires_at,amount,notes
  ) values (
    r_new.id,
    case
      when p.is_default_trial and v_custom then 'Prueba gratuita personalizada'
      when p.is_default_trial then 'Prueba gratuita predeterminada'
      when v_custom then 'Configuración personalizada de accesos'
      else 'Accesos vinculados al plan'
    end,
    r_old.subscription_status,
    r_new.subscription_status,
    r_old.subscription_expires_at,
    r_new.subscription_expires_at,
    r_new.subscription_price,
    r_new.subscription_notes
  );

  return r_new;
end
$$;


--
-- Name: admin_set_restaurant_subscription_access_date(bigint, bigint, jsonb, numeric, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_restaurant_subscription_access_date(p_restaurant_id bigint, p_plan_id bigint, p_selected_modules jsonb, p_price numeric, p_expiry_date date, p_notes text) RETURNS public.restaurants
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  r_old public.restaurants%rowtype;
  r_new public.restaurants%rowtype;
  p public.subscription_plans%rowtype;
  v_base jsonb := '[]'::jsonb;
  v_selected jsonb := public.normalize_module_array(coalesce(p_selected_modules,'[]'::jsonb));
  v_custom boolean := false;
  v_status text;
  v_expiry timestamptz;
  v_tz text;
  v_default_local_date date;
begin
  if not public.is_site_admin() then raise exception 'Solo el administrador general puede modificar accesos de suscripción'; end if;

  select * into r_old from public.restaurants where id=p_restaurant_id for update;
  if not found then raise exception 'Negocio no encontrado'; end if;

  if p_plan_id is null then
    select * into p
    from public.subscription_plans
    where is_default_trial=true and business_type=coalesce(r_old.business_type,'restaurant')
    limit 1;
  else
    select * into p
    from public.subscription_plans
    where id=p_plan_id and business_type=coalesce(r_old.business_type,'restaurant');
  end if;

  if not found then raise exception 'El plan no corresponde al tipo de negocio'; end if;

  v_tz := coalesce(nullif(r_old.timezone,''),'America/Santiago');
  v_base := public.normalize_module_array(coalesce(p.modules,'[]'::jsonb));
  v_custom := v_selected <> v_base;
  v_status := case when p.is_default_trial then 'trial' else 'active' end;

  if p_expiry_date is not null then
    v_expiry := (p_expiry_date + time '23:59:59') at time zone v_tz;
  elsif r_old.subscription_expires_at is not null then
    v_expiry := r_old.subscription_expires_at;
  else
    v_default_local_date := (now() at time zone v_tz)::date + greatest(p.days,1);
    v_expiry := (v_default_local_date + time '23:59:59') at time zone v_tz;
  end if;

  update public.restaurants
  set subscription_plan_id=p.id,
      subscription_plan=p.name,
      subscription_status=v_status,
      subscription_price=case when p.is_default_trial then 0 else greatest(coalesce(p_price,p.amount,0),0) end,
      subscription_expires_at=v_expiry,
      subscription_notes=coalesce(p_notes,''),
      subscription_modules_customized=v_custom,
      subscription_module_overrides=case when v_custom then v_selected else '[]'::jsonb end,
      updated_at=now()
  where id=p_restaurant_id
  returning * into r_new;

  insert into public.restaurant_subscription_history(
    restaurant_id,action,previous_status,new_status,
    previous_expires_at,new_expires_at,amount,notes
  ) values (
    r_new.id,
    case
      when p.is_default_trial and v_custom then 'Prueba gratuita personalizada'
      when p.is_default_trial then 'Prueba gratuita predeterminada'
      when v_custom then 'Configuración personalizada de accesos'
      else 'Accesos vinculados al plan'
    end,
    r_old.subscription_status,r_new.subscription_status,
    r_old.subscription_expires_at,r_new.subscription_expires_at,
    r_new.subscription_price,r_new.subscription_notes
  );

  return r_new;
end;
$$;


--
-- Name: apply_inventory_movement(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_inventory_movement() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 update public.restaurant_inventory_items
 set current_stock=current_stock+new.quantity_delta,updated_at=now()
 where id=new.inventory_item_id and restaurant_id=new.restaurant_id;
 if not found then raise exception 'Inventory item does not belong to restaurant'; end if;
 return new;
end;
$$;


--
-- Name: approve_professional_appointment_manual_payment(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.approve_professional_appointment_manual_payment(p_appointment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_a public.professional_appointments%rowtype;
  v_auto boolean;
begin
  select * into v_a
  from public.professional_appointments
  where id=p_appointment_id
  for update;

  if v_a.id is null then raise exception 'Reserva no encontrada'; end if;

  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(v_a.restaurant_id,'appointments')
  ) then
    raise exception 'No tienes permiso para confirmar pagos';
  end if;

  if v_a.payment_status='approved' then
    return jsonb_build_object(
      'id',v_a.id,'payment_status',v_a.payment_status,
      'paid_amount',v_a.paid_amount,'status',v_a.status
    );
  end if;

  if v_a.payment_status<>'pending' or coalesce(v_a.payment_amount_due,0)<=0 then
    raise exception 'Esta reserva no tiene un pago pendiente';
  end if;

  if nullif(btrim(coalesce(v_a.payment_method,'')),'') is null
     or lower(v_a.payment_method)='mercado pago' then
    raise exception 'Este pago debe validarse mediante su pasarela';
  end if;

  select coalesce(professional_booking_auto_confirm,true)
  into v_auto
  from public.restaurants
  where id=v_a.restaurant_id and business_type='professional';

  update public.professional_appointments
  set payment_status='approved',
      paid_amount=payment_amount_due,
      paid_at=now(),
      payment_expires_at=null,
      status=case when v_auto then 'confirmed' else status end,
      updated_at=now()
  where id=v_a.id
  returning * into v_a;

  return jsonb_build_object(
    'id',v_a.id,
    'payment_status',v_a.payment_status,
    'paid_amount',v_a.paid_amount,
    'payment_method',v_a.payment_method,
    'paid_at',v_a.paid_at,
    'status',v_a.status
  );
end;
$$;


--
-- Name: approve_professional_booking_manual_payment(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.approve_professional_booking_manual_payment(p_intent_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_i public.professional_booking_payment_intents%rowtype;
  v_result jsonb;
begin
  select * into v_i
  from public.professional_booking_payment_intents
  where id=p_intent_id
  for update;

  if v_i.id is null then raise exception 'Pago pendiente no encontrado'; end if;
  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(v_i.restaurant_id,'appointments')
  ) then raise exception 'No tienes permiso para confirmar pagos'; end if;
  if v_i.appointment_id is not null then
    return jsonb_build_object('appointment_id',v_i.appointment_id,'payment_status','approved','already_finalized',true);
  end if;
  if v_i.status not in ('pending','processing') or v_i.expires_at<=now() then
    raise exception 'El intento de pago venció';
  end if;
  if nullif(btrim(coalesce(v_i.payment_method,'')),'') is null
     or lower(v_i.payment_method)='mercado pago' then
    raise exception 'Este pago debe validarse mediante su pasarela';
  end if;

  select public.finalize_professional_booking_payment_intent(
    v_i.id,v_i.amount_due,v_i.payment_method,null,now()
  ) into v_result;

  return v_result;
end;
$$;


--
-- Name: assign_restaurant_staff(text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_restaurant_staff(p_email text, p_restaurant_id bigint, p_role text DEFAULT 'manager'::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare uid uuid; sid bigint; actor_role text;
begin
 if p_role not in ('manager','editor','cashier','kitchen','courier','waiter') then raise exception 'Rol inválido'; end if;
 if not public.is_site_admin() then
   select role into actor_role from public.restaurant_staff where restaurant_id=p_restaurant_id and user_id=(select auth.uid()) and active limit 1;
   if actor_role not in ('restaurant','manager') then raise exception 'No autorizado'; end if;
 end if;
 select id into uid from auth.users where lower(email)=lower(trim(p_email)) limit 1;
 if uid is null then raise exception 'El usuario no existe en Authentication'; end if;
 insert into public.restaurant_staff(restaurant_id,user_id,email,role,active)
 values(p_restaurant_id,uid,lower(trim(p_email)),p_role,true)
 on conflict(restaurant_id,user_id) do update set email=excluded.email,role=excluded.role,active=true
 returning id into sid;
 return sid;
end $$;


--
-- Name: auto_confirm_customer_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auto_confirm_customer_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'auth', 'public'
    AS $$ begin new.email_confirmed_at=coalesce(new.email_confirmed_at,now()); new.confirmation_token=''; new.confirmation_sent_at=null; return new; end; $$;


--
-- Name: business_payment_public_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_payment_public_status(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
with base as (
  select
    r.id,
    r.is_demo,
    coalesce(r.accept_mercadopago,true) as accept_mp,
    coalesce(o.enabled,false) as use_admin,
    nullif(trim(coalesce(r.mercadopago_public_key,'')),'') is not null as own_public,
    exists(
      select 1
      from public.restaurant_payment_connections pc
      where pc.restaurant_id=r.id
        and nullif(trim(coalesce(pc.access_token,'')),'') is not null
    ) as own_token,
    exists(
      select 1
      from public.subscription_payment_settings s
      where nullif(trim(coalesce(s.public_key,'')),'') is not null
        and nullif(trim(coalesce(s.access_token,'')),'') is not null
    ) as admin_ready,
    coalesce((
      select c.mercadopago_enabled
      from public.platform_countries c
      where c.code=r.country_code and c.active
      limit 1
    ),false) as country_ready
  from public.restaurants r
  left join public.business_payment_test_overrides o on o.restaurant_id=r.id
  where r.id=p_restaurant_id
)
select jsonb_build_object(
  'restaurant_id',id,
  'is_demo',is_demo,
  'using_admin_credentials',use_admin,
  'effective_demo',coalesce(is_demo,false) and not coalesce(use_admin,false),
  'source',case when use_admin then 'admin' else 'business' end,
  'online_ready',
    accept_mp and country_ready and
    case when use_admin then admin_ready else (own_public and own_token) end,
  'message',
    case
      when not accept_mp then 'Mercado Pago está desactivado para este negocio.'
      when not country_ready then 'Mercado Pago no está disponible para el país configurado.'
      when use_admin and admin_ready then 'Credenciales del administrador activadas para pruebas.'
      when use_admin and not admin_ready then 'Las credenciales de prueba del administrador no están configuradas.'
      when is_demo and not (own_public and own_token) then 'Los pagos están deshabilitados para esta cuenta demo. El administrador puede habilitar credenciales de prueba.'
      when not is_demo and not (own_public and own_token) then 'Configura tus credenciales de Mercado Pago para habilitar pagos online.'
      else 'Mercado Pago configurado con las credenciales propias del negocio.'
    end
)
from base;
$$;


--
-- Name: business_public_client_mode(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_public_client_mode(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
select jsonb_build_object(
  'effective_demo',coalesce(r.is_demo,false) and not coalesce(o.enabled,false),
  'payment_online_ready',
    coalesce(r.accept_mercadopago,true)
    and coalesce((
      select c.mercadopago_enabled
      from public.platform_countries c
      where c.code=r.country_code and c.active
      limit 1
    ),false)
    and nullif(trim(coalesce(r.mercadopago_public_key,'')),'') is not null
    and exists(
      select 1
      from public.restaurant_payment_connections pc
      where pc.restaurant_id=r.id
        and nullif(trim(coalesce(pc.access_token,'')),'') is not null
    )
)
from public.restaurants r
left join public.business_payment_test_overrides o on o.restaurant_id=r.id
where r.id=p_restaurant_id;
$$;


--
-- Name: can_manage_restaurant(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_restaurant(rid bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
 select public.is_site_admin() or exists(select 1 from public.restaurant_staff s where s.restaurant_id=rid and s.user_id=auth.uid() and s.active and s.role in ('restaurant','editor','manager'));
$$;


--
-- Name: can_manage_restaurant_staff(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_restaurant_staff(rid bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
 select public.is_site_admin() or exists(
   select 1 from public.restaurant_staff s
   where s.restaurant_id=rid and s.user_id=(select auth.uid()) and s.active and s.role in ('restaurant','manager')
 );
$$;


--
-- Name: can_register_customer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_register_customer() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select auth.uid() is not null
    and exists(
      select 1 from public.user_profiles up
      where up.user_id=auth.uid() and up.account_type='customer'
    )
    and not exists(select 1 from public.admin_users a where a.user_id=auth.uid())
    and not exists(select 1 from public.restaurant_staff s where s.user_id=auth.uid() and s.active)
$$;


--
-- Name: cleanup_expired_table_qr_mp_orders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_table_qr_mp_orders() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_count integer := 0;
begin
  delete from public.restaurant_orders o
  where o.order_source='table_qr'
    and lower(coalesce(o.payment_method,''))='mercado pago'
    and lower(coalesce(o.payment_status,'')) in ('pending','rejected','cancelled')
    and o.created_at < now() - interval '30 minutes';

  get diagnostics v_count = row_count;
  return v_count;
end
$$;


--
-- Name: clear_demo_mp_user_on_inheritance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_demo_mp_user_on_inheritance() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.is_demo and new.use_demo_api_defaults then
    update public.restaurant_payment_connections
    set mp_user_id=null,
        updated_at=now()
    where restaurant_id=new.id;
  end if;
  return new;
end;
$$;


--
-- Name: complete_counter_qr_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_counter_qr_order(p_order_id bigint) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
  v_session public.restaurant_cash_sessions%rowtype;
  v_manual boolean;
begin
  select * into v_order
  from public.restaurant_orders
  where id=p_order_id
  for update;

  if not found or v_order.order_source<>'table_qr' or v_order.order_type<>'Retiro' then
    raise exception 'Pedido de mostrador no encontrado';
  end if;

  if auth.uid() is null
     or (
       not public.is_site_admin()
       and not (
         public.has_restaurant_permission(v_order.restaurant_id,'cash')
         or public.has_restaurant_permission(v_order.restaurant_id,'pos')
       )
     ) then
    raise exception 'No autorizado para entregar este pedido';
  end if;

  if v_order.status='entregado' then return v_order; end if;
  if v_order.status<>'listo' then raise exception 'El pedido todavía no está listo'; end if;

  v_manual:=lower(trim(coalesce(v_order.payment_method,''))) not in ('mercado pago','qr bolivia');

  if not v_manual then
    if lower(trim(coalesce(v_order.payment_status,'')))<>'approved' then
      raise exception 'El pago en línea todavía no está acreditado';
    end if;
  elsif lower(trim(coalesce(v_order.payment_status,'')))<>'approved' then
    select * into v_session
    from public.restaurant_cash_sessions
    where restaurant_id=v_order.restaurant_id and status='open'
    order by opened_at desc
    limit 1;

    if not found then
      raise exception 'Primero debe abrirse la caja para cobrar el pedido';
    end if;

    update public.restaurant_orders
       set payment_status='approved',
           payment_verification_status='approved',
           paid_at=coalesce(paid_at,now()),
           updated_at=now()
     where id=v_order.id
     returning * into v_order;

    insert into public.restaurant_cash_movements(
      restaurant_id,session_id,order_id,movement_type,payment_method,amount,description,created_by
    )
    values(
      v_order.restaurant_id,v_session.id,v_order.id,'sale',
      v_order.payment_method,v_order.total,
      'Retiro mostrador '||v_order.order_code,auth.uid()
    );
  end if;

  update public.restaurant_orders
     set status='entregado',
         delivered_at=coalesce(delivered_at,now()),
         updated_at=now()
   where id=v_order.id
   returning * into v_order;

  return v_order;
end
$$;


--
-- Name: complete_table_qr_delivery(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_table_qr_delivery(p_order_id bigint) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
begin
  select * into v_order
  from public.restaurant_orders
  where id=p_order_id
  for update;

  if not found or v_order.order_source<>'table_qr' or v_order.order_type<>'Mesa' then
    raise exception 'Pedido QR de mesa no encontrado';
  end if;

  if auth.uid() is null
     or (
       not public.is_site_admin()
       and (
         not public.has_restaurant_permission(v_order.restaurant_id,'pos')
         or v_order.created_by is distinct from auth.uid()
       )
     ) then
    raise exception 'Solo el mesero que retiró el pedido puede marcarlo como entregado en mesa';
  end if;

  if lower(trim(coalesce(v_order.payment_method,''))) not in ('mercado pago','qr bolivia')
     or lower(trim(coalesce(v_order.payment_status,'')))<>'approved' then
    raise exception 'Esta acción es solo para pedidos QR pagados en línea';
  end if;

  if v_order.status='entregado' then return v_order; end if;
  if v_order.status<>'retirado_mesa' then raise exception 'Primero retira el pedido de cocina'; end if;

  update public.restaurant_orders
  set status='entregado',
      delivered_at=coalesce(delivered_at,now()),
      updated_at=now()
  where id=p_order_id
  returning * into v_order;

  return v_order;
end
$$;


--
-- Name: create_cashier_sale(bigint, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_cashier_sale(p_restaurant_id bigint, p_customer_name text, p_notes text, p_payment_method text, p_items jsonb) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_item jsonb;
  v_product public.restaurant_products%rowtype;
  v_qty integer;
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_order public.restaurant_orders%rowtype;
  v_session public.restaurant_cash_sessions%rowtype;
  v_code text;
  v_method text;
  v_currency text;
begin
  if not public.has_restaurant_permission(p_restaurant_id,'cash') then
    raise exception 'No autorizado para vender desde Caja';
  end if;

  select * into v_session
  from public.restaurant_cash_sessions
  where restaurant_id=p_restaurant_id and status='open'
  order by opened_at desc
  limit 1;

  if not found then
    raise exception 'Primero debe abrirse la caja para registrar una venta';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Agrega al menos un producto';
  end if;

  v_method := nullif(trim(coalesce(p_payment_method,'')),'');
  if v_method is null then raise exception 'Selecciona un método de pago'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := greatest(1,least(99,coalesce((v_item->>'qty')::integer,1)));
    select * into v_product
    from public.restaurant_products
    where id=(v_item->>'product_id')::bigint
      and restaurant_id=p_restaurant_id
      and available=true;

    if not found then raise exception 'Producto no disponible'; end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,
      'name',v_product.name,
      'qty',v_qty,
      'unit_price',v_product.price,
      'note',coalesce(v_item->>'note','')
    ));
    v_total := v_total + (v_product.price*v_qty);
  end loop;

  select coalesce(currency_code,'CLP') into v_currency
  from public.restaurants
  where id=p_restaurant_id;

  v_code := 'CAJA-' || to_char(clock_timestamp(),'YYMMDDHH24MISS') || '-' ||
            lpad((floor(random()*1000))::int::text,3,'0');

  insert into public.restaurant_orders(
    order_code,restaurant_id,customer_name,order_type,payment_method,payment_status,
    payment_verification_status,status,items,total,notes,order_source,created_by,
    paid_at,delivered_at,currency_code
  ) values (
    v_code,p_restaurant_id,coalesce(nullif(trim(p_customer_name),''),'Cliente caja'),
    'Retiro',v_method,'approved','approved','entregado',v_items,v_total,
    nullif(trim(coalesce(p_notes,'')),''),
    'cashier',auth.uid(),now(),now(),coalesce(v_currency,'CLP')
  ) returning * into v_order;

  insert into public.restaurant_cash_movements(
    restaurant_id,session_id,order_id,movement_type,payment_method,amount,description,created_by
  ) values (
    p_restaurant_id,v_session.id,v_order.id,'sale',v_method,v_total,
    'Venta de caja '||v_order.order_code,auth.uid()
  );

  return v_order;
end
$$;


--
-- Name: create_my_trial_restaurant(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_my_trial_restaurant(p_name text, p_whatsapp text DEFAULT ''::text, p_address text DEFAULT ''::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_restaurant_id bigint;
  v_slug text;
  v_trial public.subscription_plans%rowtype;
begin
  if v_uid is null then raise exception 'Debes iniciar sesión para crear tu restaurante'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'El nombre del restaurante es obligatorio'; end if;

  if exists(select 1 from public.restaurant_staff where user_id=v_uid and active) then
    raise exception 'Tu usuario ya tiene un restaurante asignado';
  end if;

  select * into v_trial
  from public.subscription_plans
  where is_default_trial=true and active=true
  limit 1;

  if not found then
    raise exception 'La prueba gratuita predeterminada no está configurada';
  end if;

  select email into v_email from auth.users where id=v_uid;

  v_slug := lower(regexp_replace(extensions.unaccent(trim(p_name)), '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug);
  if v_slug = '' then v_slug := 'restaurante'; end if;
  if exists(select 1 from public.restaurants where slug=v_slug) then
    v_slug := v_slug || '-' || substr(replace(v_uid::text,'-',''),1,6);
  end if;

  insert into public.restaurants(
    name,slug,whatsapp,address,active,
    subscription_status,subscription_started_at,subscription_expires_at,
    subscription_plan_id,subscription_plan,subscription_price,
    subscription_modules_customized,subscription_module_overrides
  )
  values(
    trim(p_name),v_slug,coalesce(trim(p_whatsapp),''),coalesce(trim(p_address),''),
    true,'trial',now(),now()+make_interval(days=>greatest(v_trial.days,1)),
    v_trial.id,v_trial.name,0,false,'[]'::jsonb
  )
  returning id into v_restaurant_id;

  insert into public.restaurant_staff(restaurant_id,user_id,email,role,active)
  values(v_restaurant_id,v_uid,coalesce(v_email,''),'restaurant',true);

  return v_restaurant_id;
end
$$;


--
-- Name: create_my_trial_restaurant_v2(text, text, text, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_my_trial_restaurant_v2(p_name text, p_whatsapp text DEFAULT ''::text, p_address text DEFAULT ''::text, p_country_code text DEFAULT 'CL'::text, p_intended_plan_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_restaurant_id bigint;
  v_slug text;
  v_trial public.subscription_plans%rowtype;
  v_country public.platform_countries%rowtype;
  v_intended_plan_id bigint;
begin
  if v_uid is null then raise exception 'Debes iniciar sesión para crear tu restaurante'; end if;
  if coalesce(trim(p_name),'')='' then raise exception 'El nombre del restaurante es obligatorio'; end if;

  if exists(select 1 from public.restaurant_staff where user_id=v_uid and active) then
    raise exception 'Tu usuario ya tiene un restaurante asignado';
  end if;

  select * into v_trial
  from public.subscription_plans
  where is_default_trial=true and active=true
  limit 1;
  if not found then raise exception 'La prueba gratuita predeterminada no está configurada'; end if;

  select id into v_intended_plan_id
  from public.subscription_plans
  where id=p_intended_plan_id and active=true and coalesce(is_default_trial,false)=false;
  if not found then v_intended_plan_id:=null; end if;

  select * into v_country
  from public.platform_countries
  where code=upper(trim(coalesce(p_country_code,'CL'))) and active=true
  limit 1;

  if not found then
    select * into v_country from public.platform_countries where code='CL' and active=true limit 1;
  end if;
  if not found then raise exception 'No hay un país activo disponible para crear el restaurante'; end if;

  select email into v_email from auth.users where id=v_uid;

  v_slug:=lower(regexp_replace(extensions.unaccent(trim(p_name)),'[^a-zA-Z0-9]+','-','g'));
  v_slug:=trim(both '-' from v_slug);
  if v_slug='' then v_slug:='restaurante'; end if;
  if exists(select 1 from public.restaurants where slug=v_slug) then
    v_slug:=v_slug||'-'||substr(replace(v_uid::text,'-',''),1,6);
  end if;

  insert into public.restaurants(
    name,slug,whatsapp,address,active,
    country_code,currency_code,locale,timezone,
    subscription_status,subscription_started_at,subscription_expires_at,
    subscription_plan_id,subscription_plan,subscription_price,
    subscription_modules_customized,subscription_module_overrides,
    trial_intended_plan_id,trial_intended_plan_selected_at
  )
  values(
    trim(p_name),v_slug,coalesce(trim(p_whatsapp),''),coalesce(trim(p_address),''),
    true,v_country.code,v_country.currency_code,v_country.locale,v_country.timezone,
    'trial',now(),now()+make_interval(days=>greatest(v_trial.days,1)),
    v_trial.id,v_trial.name,0,false,'[]'::jsonb,
    v_intended_plan_id,case when v_intended_plan_id is not null then now() else null end
  )
  returning id into v_restaurant_id;

  insert into public.restaurant_staff(restaurant_id,user_id,email,role,active)
  values(v_restaurant_id,v_uid,coalesce(v_email,''),'restaurant',true);

  insert into public.app_events(app_context,event_name,module,restaurant_id,user_id,plan_id,metadata)
  values('landing','trial_started','signup',v_restaurant_id,v_uid,v_intended_plan_id,jsonb_build_object('country_code',v_country.code));

  return v_restaurant_id;
end
$$;


--
-- Name: create_my_trial_restaurant_v3(text, text, text, text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_my_trial_restaurant_v3(p_name text, p_whatsapp text DEFAULT ''::text, p_address text DEFAULT ''::text, p_country_code text DEFAULT 'CL'::text, p_intended_plan_id bigint DEFAULT NULL::bigint, p_business_type text DEFAULT 'restaurant'::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_restaurant_id bigint;
  v_slug text;
  v_trial public.subscription_plans%rowtype;
  v_country public.platform_countries%rowtype;
  v_intended_plan_id bigint;
  v_business_type text:=lower(btrim(coalesce(p_business_type,'restaurant')));
begin
  if v_uid is null then raise exception 'Debes iniciar sesión para crear tu negocio'; end if;
  if coalesce(trim(p_name),'')='' then raise exception 'El nombre del negocio es obligatorio'; end if;
  if v_business_type not in ('restaurant','supermarket','minimarket','professional','streaming') then
    raise exception 'Tipo de negocio inválido';
  end if;
  if exists(select 1 from public.restaurant_staff where user_id=v_uid and active) then
    raise exception 'Tu usuario ya tiene un negocio asignado';
  end if;

  select * into v_trial
  from public.subscription_plans
  where is_default_trial=true and active=true and business_type=v_business_type
  limit 1;
  if not found then raise exception 'La prueba gratuita para este tipo de negocio no está configurada'; end if;

  select id into v_intended_plan_id
  from public.subscription_plans
  where id=p_intended_plan_id
    and active=true
    and coalesce(is_default_trial,false)=false
    and business_type=v_business_type;
  if not found then v_intended_plan_id:=null; end if;

  select * into v_country
  from public.platform_countries
  where code=upper(trim(coalesce(p_country_code,'CL'))) and active=true
  limit 1;
  if not found then
    select * into v_country
    from public.platform_countries
    where code='CL' and active=true
    limit 1;
  end if;
  if not found then raise exception 'No hay un país activo disponible para crear el negocio'; end if;

  select email into v_email from auth.users where id=v_uid;
  v_slug:=lower(regexp_replace(extensions.unaccent(trim(p_name)),'[^a-zA-Z0-9]+','-','g'));
  v_slug:=trim(both '-' from v_slug);
  if v_slug='' then v_slug:='negocio'; end if;
  if exists(select 1 from public.restaurants where slug=v_slug) then
    v_slug:=v_slug||'-'||substr(replace(v_uid::text,'-',''),1,6);
  end if;

  insert into public.restaurants(
    name,slug,whatsapp,address,active,business_type,is_demo,
    country_code,currency_code,locale,timezone,
    subscription_status,subscription_started_at,subscription_expires_at,
    subscription_plan_id,subscription_plan,subscription_price,
    subscription_modules_customized,subscription_module_overrides,
    trial_intended_plan_id,trial_intended_plan_selected_at
  )
  values(
    trim(p_name),v_slug,coalesce(trim(p_whatsapp),''),coalesce(trim(p_address),''),
    true,v_business_type,true,v_country.code,v_country.currency_code,v_country.locale,v_country.timezone,
    'trial',now(),now()+make_interval(days=>greatest(v_trial.days,1)),
    v_trial.id,v_trial.name,0,false,'[]'::jsonb,
    v_intended_plan_id,case when v_intended_plan_id is not null then now() else null end
  )
  returning id into v_restaurant_id;

  insert into public.restaurant_staff(restaurant_id,user_id,email,role,active)
  values(v_restaurant_id,v_uid,coalesce(v_email,''),'restaurant',true);

  insert into public.app_events(app_context,event_name,module,restaurant_id,user_id,plan_id,metadata)
  values('landing','trial_started','signup',v_restaurant_id,v_uid,v_intended_plan_id,
    jsonb_build_object('country_code',v_country.code,'business_type',v_business_type,'is_demo',true));

  return v_restaurant_id;
end;
$$;


--
-- Name: create_professional_appointment(bigint, bigint, bigint, timestamp with time zone, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_professional_appointment(p_restaurant_id bigint, p_service_id bigint, p_provider_id bigint, p_starts_at timestamp with time zone, p_customer_name text, p_customer_phone text DEFAULT ''::text, p_customer_email text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_service public.professional_services%rowtype;
  v_rest public.restaurants%rowtype;
  v_end timestamptz;
  v_id bigint;
begin
  select * into v_rest from public.restaurants
  where id=p_restaurant_id and business_type='professional' and active
    and subscription_status in ('trial','active')
    and (subscription_expires_at is null or subscription_expires_at > now());
  if not found then raise exception 'Este profesional no está disponible'; end if;

  select * into v_service from public.professional_services
  where id=p_service_id and restaurant_id=p_restaurant_id and active;
  if not found then raise exception 'Servicio no disponible'; end if;

  if not exists(select 1 from public.professional_providers p where p.id=p_provider_id and p.restaurant_id=p_restaurant_id and p.active)
  then raise exception 'Profesional no disponible'; end if;

  if coalesce(btrim(p_customer_name),'')='' then raise exception 'Ingresa tu nombre'; end if;
  if p_starts_at < now()+make_interval(hours=>v_rest.professional_booking_min_notice_hours)
     or p_starts_at > now()+make_interval(days=>v_rest.professional_booking_max_days)
  then raise exception 'Horario fuera de la ventana de reserva'; end if;

  v_end := p_starts_at + make_interval(mins=>v_service.duration_minutes);

  if not exists(
    select 1 from public.get_professional_available_slots(p_restaurant_id,p_service_id,p_provider_id,(p_starts_at at time zone v_rest.timezone)::date) s
    where s.slot_start=p_starts_at
  ) then raise exception 'Ese horario ya no está disponible'; end if;

  insert into public.professional_appointments(
    restaurant_id,service_id,provider_id,customer_id,customer_name,customer_phone,customer_email,
    starts_at,ends_at,status,notes,payment_status,deposit_amount,total_amount
  ) values(
    p_restaurant_id,p_service_id,p_provider_id,auth.uid(),btrim(p_customer_name),coalesce(p_customer_phone,''),
    nullif(btrim(coalesce(p_customer_email,'')),''),p_starts_at,v_end,
    case when v_rest.professional_booking_auto_confirm then 'confirmed' else 'pending' end,
    nullif(btrim(coalesce(p_notes,'')),''),
    case when v_rest.professional_booking_deposit_required then 'pending' else 'not_required' end,
    case when v_rest.professional_booking_deposit_required then v_rest.professional_booking_deposit_amount else 0 end,
    v_service.price
  ) returning id into v_id;

  return v_id;
end;
$$;


--
-- Name: create_professional_booking_payment_intent(bigint, bigint, bigint, timestamp with time zone, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_professional_booking_payment_intent(p_restaurant_id bigint, p_service_id bigint, p_provider_id bigint, p_starts_at timestamp with time zone, p_customer_name text, p_customer_phone text DEFAULT ''::text, p_customer_email text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid:=auth.uid();
  v_rest public.restaurants%rowtype;
  v_service public.professional_services%rowtype;
  v_end timestamptz;
  v_mode text;
  v_due numeric;
  v_deposit numeric;
  v_id bigint;
  v_token uuid;
  v_expires timestamptz:=now()+interval '20 minutes';
begin
  if v_uid is null
     or (public.current_account_role()<>'customer'
         and not public.has_admin_client_preview(p_restaurant_id)) then
    raise exception 'Inicia sesión como cliente para continuar';
  end if;
  if nullif(btrim(p_customer_name),'') is null then raise exception 'Ingresa tu nombre'; end if;
  if nullif(btrim(coalesce(p_customer_phone,'')),'') is null then raise exception 'Ingresa tu teléfono'; end if;

  perform pg_advisory_xact_lock(p_provider_id);
  perform public.professional_release_expired_booking_payment_intents(p_restaurant_id);

  select * into v_rest
  from public.restaurants
  where id=p_restaurant_id
    and business_type='professional'
    and active
    and subscription_status in ('trial','active')
    and (subscription_expires_at is null or subscription_expires_at>now());
  if not found then raise exception 'Este profesional no está disponible'; end if;

  select * into v_service
  from public.professional_services
  where id=p_service_id and restaurant_id=p_restaurant_id and active;
  if not found then raise exception 'Servicio no disponible'; end if;

  if not exists(
    select 1 from public.professional_provider_services ps
    join public.professional_providers p on p.id=ps.provider_id
    where ps.restaurant_id=p_restaurant_id
      and ps.service_id=p_service_id
      and ps.provider_id=p_provider_id
      and p.active
  ) then raise exception 'Profesional no disponible'; end if;

  select s.slot_end into v_end
  from public.get_professional_available_slots(
    p_restaurant_id,p_service_id,p_provider_id,
    (p_starts_at at time zone coalesce(nullif(v_rest.timezone,''),'America/Santiago'))::date
  ) s
  where s.slot_start=p_starts_at
  limit 1;
  if v_end is null then raise exception 'Ese horario ya no está disponible'; end if;

  v_mode:=case when v_rest.professional_booking_payment_mode='deposit' then 'deposit' else 'full' end;
  v_deposit:=least(greatest(coalesce(v_rest.professional_booking_deposit_amount,0),0),coalesce(v_service.price,0));
  v_due:=case when v_mode='deposit' then v_deposit else coalesce(v_service.price,0) end;

  if v_due<=0 then raise exception 'Este servicio no tiene un monto de pago válido'; end if;

  insert into public.professional_booking_payment_intents(
    restaurant_id,service_id,provider_id,customer_id,
    customer_name,customer_phone,customer_email,notes,
    starts_at,ends_at,block_ends_at,payment_mode,total_amount,amount_due,
    payment_status,status,expires_at
  ) values (
    p_restaurant_id,p_service_id,p_provider_id,v_uid,
    btrim(p_customer_name),btrim(coalesce(p_customer_phone,'')),
    nullif(btrim(coalesce(p_customer_email,'')),''),
    nullif(btrim(coalesce(p_notes,'')),''),
    p_starts_at,v_end,v_end+make_interval(mins=>coalesce(v_service.buffer_minutes,0)),
    v_mode,coalesce(v_service.price,0),v_due,
    'pending','pending',v_expires
  )
  returning id,public_token into v_id,v_token;

  return jsonb_build_object(
    'intent_id',v_id,
    'public_token',v_token,
    'payment_mode',v_mode,
    'payment_status','pending',
    'amount_due',v_due,
    'total_amount',coalesce(v_service.price,0),
    'starts_at',p_starts_at,
    'ends_at',v_end,
    'expires_at',v_expires
  );
exception
  when exclusion_violation then
    raise exception 'Ese horario acaba de ser tomado. Elige otro.';
end;
$$;


--
-- Name: create_public_professional_appointment(bigint, bigint, bigint, timestamp with time zone, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_public_professional_appointment(p_restaurant_id bigint, p_service_id bigint, p_provider_id bigint, p_starts_at timestamp with time zone, p_customer_name text, p_customer_phone text DEFAULT ''::text, p_customer_email text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_end timestamptz;
  v_status text;
  v_price numeric;
  v_deposit numeric;
  v_payment_due numeric;
  v_payment_mode text;
  v_id bigint;
  v_timezone text;
  v_public_token uuid;
  v_payment_expires_at timestamptz;
begin
  if nullif(btrim(p_customer_name),'') is null then
    raise exception 'Ingresa el nombre del cliente';
  end if;
  if nullif(btrim(coalesce(p_customer_phone,'')),'') is null then
    raise exception 'Ingresa el teléfono del cliente';
  end if;

  select coalesce(nullif(timezone,''),'America/Santiago')
  into v_timezone
  from public.restaurants
  where id=p_restaurant_id and business_type='professional';

  if v_timezone is null then
    raise exception 'Negocio profesional no disponible';
  end if;

  select s.slot_end into v_end
  from public.get_professional_available_slots(
    p_restaurant_id,p_service_id,p_provider_id,(p_starts_at at time zone v_timezone)::date
  ) s
  where s.slot_start=p_starts_at
  limit 1;

  if v_end is null then
    raise exception 'Ese horario ya no está disponible';
  end if;

  select
    svc.price,
    coalesce(nullif(r.professional_booking_payment_mode,''),case when coalesce(r.professional_booking_deposit_required,false) then 'deposit' else 'full' end),
    case when coalesce(r.professional_booking_deposit_required,false)
         then least(greatest(coalesce(r.professional_booking_deposit_amount,0),0),svc.price)
         else 0 end,
    case when coalesce(r.professional_booking_auto_confirm,true) then 'confirmed' else 'pending' end
  into v_price,v_payment_mode,v_deposit,v_status
  from public.professional_services svc
  join public.restaurants r on r.id=svc.restaurant_id
  where svc.id=p_service_id and svc.restaurant_id=p_restaurant_id and svc.active;

  v_payment_due :=
    case v_payment_mode
      when 'full' then coalesce(v_price,0)
      when 'deposit' then coalesce(v_deposit,0)
      else 0
    end;

  if coalesce(v_payment_due,0)>0 then
    v_status:='pending';
    v_payment_expires_at:=now()+interval '20 minutes';
  end if;

  insert into public.professional_appointments(
    restaurant_id,service_id,provider_id,customer_id,customer_name,
    customer_phone,customer_email,starts_at,ends_at,status,notes,
    payment_status,deposit_amount,total_amount,payment_amount_due,paid_amount,
    created_by,payment_expires_at
  ) values (
    p_restaurant_id,p_service_id,p_provider_id,(select auth.uid()),btrim(p_customer_name),
    btrim(coalesce(p_customer_phone,'')),nullif(btrim(coalesce(p_customer_email,'')),''),
    p_starts_at,v_end,v_status,nullif(btrim(coalesce(p_notes,'')),''),
    case when coalesce(v_payment_due,0)>0 then 'pending' else 'not_required' end,
    case when v_payment_mode='deposit' then coalesce(v_deposit,0) else 0 end,
    coalesce(v_price,0),coalesce(v_payment_due,0),0,
    (select auth.uid()),v_payment_expires_at
  )
  returning id,public_token into v_id,v_public_token;

  return jsonb_build_object(
    'id',v_id,'public_token',v_public_token,'status',v_status,
    'starts_at',p_starts_at,'ends_at',v_end,
    'payment_mode',v_payment_mode,
    'payment_status',case when coalesce(v_payment_due,0)>0 then 'pending' else 'not_required' end,
    'deposit_amount',case when v_payment_mode='deposit' then coalesce(v_deposit,0) else 0 end,
    'payment_amount_due',coalesce(v_payment_due,0),
    'paid_amount',0,
    'total_amount',coalesce(v_price,0),
    'payment_expires_at',v_payment_expires_at
  );
exception
  when exclusion_violation then
    raise exception 'Ese horario acaba de ser reservado. Elige otro.';
end;
$$;


--
-- Name: create_table_qr_order(uuid, text, text, text, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_table_qr_order(p_table_token uuid, p_customer_name text, p_customer_phone text, p_payment_method text, p_notes text, p_items jsonb, p_currency_code text DEFAULT 'CLP'::text) RETURNS TABLE(order_id bigint, order_code text, restaurant_id bigint, table_id bigint, table_name text, total numeric, payment_method text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_table public.restaurant_tables%rowtype;
  v_restaurant public.restaurants%rowtype;
  v_plan_modules jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_item jsonb;
  v_qty integer;
  v_unit numeric;
  v_method text;
  v_code text;
  v_order public.restaurant_orders%rowtype;
  v_product public.restaurant_products%rowtype;
  v_option public.restaurant_product_options%rowtype;
  v_option_id bigint;
  v_extra_id_text text;
  v_item_name text;
  v_extras jsonb;
  v_has_required_single boolean;
begin
  select t.* into v_table
  from public.restaurant_tables t
  where t.token=p_table_token and t.active=true
  limit 1;

  if not found then
    raise exception 'QR de mesa inválido o desactivado';
  end if;

  select r.* into v_restaurant
  from public.restaurants r
  where r.id=v_table.restaurant_id
    and r.active=true
    and r.subscription_status in ('trial','active')
    and r.subscription_expires_at > now();

  if not found then
    raise exception 'El restaurante no está disponible';
  end if;

  if not public.restaurant_subscription_module_enabled(v_restaurant.id,'table_qr') then
    raise exception 'QR de Mesa no está habilitado en la suscripción';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Agrega al menos un producto';
  end if;

  v_method := nullif(trim(coalesce(p_payment_method,'')),'');
  if v_method is null or char_length(v_method)>80 then
    raise exception 'Selecciona un método de pago válido';
  end if;

  if lower(v_method) not in ('efectivo','tarjeta pos','mercado pago','qr bolivia')
     and not exists (
       select 1 from public.restaurant_payment_methods pm
       where pm.restaurant_id=v_restaurant.id
         and pm.active=true
         and lower(trim(pm.label))=lower(v_method)
     ) then
    raise exception 'El método de pago seleccionado no está habilitado';
  end if;

  p_items := coalesce(p_items,'[]'::jsonb);
  declare
    v_clean_items jsonb := '[]'::jsonb;
  begin
    for v_item in select value from jsonb_array_elements(p_items)
    loop
      if nullif(v_item->>'product_id','') is null then
        raise exception 'Producto inválido';
      end if;

      v_qty := greatest(1,least(99,coalesce((v_item->>'qty')::integer,1)));

      select p.* into v_product
      from public.restaurant_products p
      where p.id=(v_item->>'product_id')::bigint
        and p.restaurant_id=v_restaurant.id
        and p.available=true;

      if not found then
        raise exception 'Producto no disponible';
      end if;

      v_unit := coalesce(v_product.price,0);
      v_item_name := v_product.name;
      v_extras := '[]'::jsonb;
      v_option_id := null;

      if nullif(v_item->>'option_id','') is not null then
        v_option_id := (v_item->>'option_id')::bigint;
        select o.* into v_option
        from public.restaurant_product_options o
        join public.restaurant_product_option_groups g on g.id=o.group_id
        where o.id=v_option_id
          and o.restaurant_id=v_restaurant.id
          and o.available=true
          and g.restaurant_id=v_restaurant.id
          and g.product_id=v_product.id
          and g.active=true
          and g.selection_type='single'
        limit 1;
        if not found then
          raise exception 'Opción de producto inválida';
        end if;
        v_unit := v_unit + coalesce(v_option.price_delta,0);
        v_item_name := v_product.name || ' ' || v_option.name;
      else
        select exists(
          select 1 from public.restaurant_product_option_groups g
          where g.restaurant_id=v_restaurant.id
            and g.product_id=v_product.id
            and g.active=true
            and g.selection_type='single'
            and g.required=true
        ) into v_has_required_single;
        if v_has_required_single then
          raise exception 'Selecciona una opción obligatoria para %', v_product.name;
        end if;
      end if;

      for v_extra_id_text in
        select value from jsonb_array_elements_text(coalesce(v_item->'extra_option_ids','[]'::jsonb))
      loop
        select o.* into v_option
        from public.restaurant_product_options o
        join public.restaurant_product_option_groups g on g.id=o.group_id
        where o.id=v_extra_id_text::bigint
          and o.restaurant_id=v_restaurant.id
          and o.available=true
          and g.restaurant_id=v_restaurant.id
          and g.product_id=v_product.id
          and g.active=true
          and g.selection_type='multiple'
        limit 1;
        if not found then
          raise exception 'Extra de producto inválido';
        end if;
        v_unit := v_unit + coalesce(v_option.price_delta,0);
        v_extras := v_extras || jsonb_build_array(v_option.name);
      end loop;

      if v_unit < 0 then
        raise exception 'Precio de producto inválido';
      end if;

      v_total := v_total + (v_qty * v_unit);
      v_clean_items := v_clean_items || jsonb_build_array(jsonb_build_object(
        'product_id',v_product.id,
        'name',v_item_name,
        'qty',v_qty,
        'unit_price',v_unit,
        'extras',v_extras,
        'note',left(coalesce(v_item->>'note',''),500)
      ));
    end loop;

    if v_total <= 0 then
      raise exception 'El total del pedido no es válido';
    end if;

    v_code := 'QR-' || to_char(clock_timestamp(),'YYMMDDHH24MISS') || '-' || lpad((floor(random()*1000))::int::text,3,'0');

    insert into public.restaurant_orders(
      order_code, restaurant_id, customer_name, customer_phone, customer_id,
      order_type, payment_method, payment_status, payment_verification_status,
      status, items, total, notes, order_source, table_reference,
      restaurant_table_id, currency_code
    ) values (
      v_code, v_restaurant.id,
      left(coalesce(nullif(trim(coalesce(p_customer_name,'')),''),'Cliente '||v_table.name),120),
      left(nullif(trim(coalesce(p_customer_phone,'')),''),40),
      auth.uid(),
      'Mesa', v_method, 'pending', 'not_required',
      'recibido', v_clean_items, v_total, left(nullif(trim(coalesce(p_notes,'')),''),1000),
      'table_qr', v_table.name, v_table.id,
      coalesce(nullif(trim(coalesce(p_currency_code,'')),''),v_restaurant.currency_code,'CLP')
    )
    returning * into v_order;
  end;

  return query select v_order.id, v_order.order_code, v_order.restaurant_id,
    v_table.id, v_table.name, v_order.total, v_order.payment_method;
end
$$;


--
-- Name: create_table_qr_order_v2(uuid, text, text, text, text, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_table_qr_order_v2(p_table_token uuid, p_customer_name text, p_customer_phone text, p_payment_method text, p_notes text, p_items jsonb, p_order_type text DEFAULT 'Mesa'::text, p_currency_code text DEFAULT 'CLP'::text) RETURNS TABLE(order_id bigint, order_code text, restaurant_id bigint, table_id bigint, table_name text, total numeric, payment_method text, order_type text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_created record;
  v_type text := case when lower(trim(coalesce(p_order_type,''))) in ('retiro','retiro mostrador','mostrador') then 'Retiro' else 'Mesa' end;
  v_order public.restaurant_orders%rowtype;
begin
  select * into v_created
  from public.create_table_qr_order(
    p_table_token,
    p_customer_name,
    p_customer_phone,
    p_payment_method,
    p_notes,
    p_items,
    p_currency_code
  );

  update public.restaurant_orders
     set order_type=v_type,
         updated_at=now()
   where id=v_created.order_id
   returning * into v_order;

  return query
  select v_order.id,v_order.order_code,v_order.restaurant_id,
         v_created.table_id,v_created.table_name,v_order.total,
         v_order.payment_method,v_order.order_type;
end
$$;


--
-- Name: create_waiter_order(bigint, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_waiter_order(p_restaurant_id bigint, p_customer_name text, p_table_reference text, p_notes text, p_items jsonb) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_item jsonb;
  v_product public.restaurant_products%rowtype;
  v_qty integer;
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_order public.restaurant_orders%rowtype;
  v_code text;
  v_cash_session_id bigint;
  v_table_name text;
begin
  if not public.has_restaurant_permission(p_restaurant_id,'pos') then
    raise exception 'Este módulo solo puede utilizarse con un usuario Mesero';
  end if;

  select id into v_cash_session_id
  from public.restaurant_cash_sessions
  where restaurant_id=p_restaurant_id
    and status='open'
  order by opened_at desc
  limit 1;

  if not found then
    raise exception 'Caja cerrada: primero debe abrirse una caja para ingresar pedidos en mesa';
  end if;

  if nullif(trim(p_customer_name),'') is null then
    raise exception 'El nombre del cliente es obligatorio';
  end if;

  if nullif(trim(coalesce(p_table_reference,'')),'') is null then
    raise exception 'Selecciona una mesa';
  end if;

  select t.name into v_table_name
  from public.restaurant_tables t
  where t.restaurant_id=p_restaurant_id
    and t.active=true
    and lower(trim(t.name))=lower(trim(p_table_reference))
  order by t.sort_order,t.id
  limit 1;

  if v_table_name is null then
    raise exception 'La mesa seleccionada no existe o está desactivada. Crea o activa la mesa en QR de Mesa.';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Agrega al menos un producto';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := greatest(1,least(99,coalesce((v_item->>'qty')::integer,1)));

    select * into v_product
    from public.restaurant_products
    where id=(v_item->>'product_id')::bigint
      and restaurant_id=p_restaurant_id
      and available=true;

    if not found then
      raise exception 'Producto no disponible';
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,
      'name',v_product.name,
      'qty',v_qty,
      'unit_price',v_product.price,
      'note',coalesce(v_item->>'note','')
    ));
    v_total := v_total + (v_product.price*v_qty);
  end loop;

  v_code := 'MESA-' || to_char(clock_timestamp(),'YYMMDDHH24MISS') || '-' ||
            lpad((floor(random()*1000))::int::text,3,'0');

  insert into public.restaurant_orders(
    order_code,restaurant_id,customer_name,order_type,payment_method,payment_status,
    status,items,total,notes,order_source,table_reference,created_by
  ) values (
    v_code,p_restaurant_id,trim(p_customer_name),'Retiro','Pendiente','internal',
    'recibido',v_items,v_total,nullif(trim(coalesce(p_notes,'')),''),
    'waiter',v_table_name,(select auth.uid())
  )
  returning * into v_order;

  return v_order;
end;
$$;


--
-- Name: current_account_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_account_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce(
    (
      select up.account_type
      from public.user_profiles up
      where up.user_id=auth.uid()
      limit 1
    ),
    case
      when exists(select 1 from public.admin_users a where a.user_id=auth.uid()) then 'admin'
      when exists(select 1 from public.restaurant_staff s where s.user_id=auth.uid() and s.active) then 'restaurant'
      when exists(select 1 from public.customer_profiles c where c.user_id=auth.uid()) then 'customer'
      else 'unassigned'
    end
  )
$$;


--
-- Name: enforce_customer_profile_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_customer_profile_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not exists(
    select 1 from public.user_profiles up
    where up.user_id=new.user_id and up.account_type='customer'
  ) then
    raise exception 'Esta cuenta no pertenece al grupo de clientes';
  end if;
  if exists(select 1 from public.admin_users a where a.user_id=new.user_id)
     or exists(select 1 from public.restaurant_staff s where s.user_id=new.user_id and s.active) then
    raise exception 'Esta cuenta pertenece a otro tipo de acceso';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_restaurant_creator_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_restaurant_creator_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return new; end if;
  if public.is_site_admin() then return new; end if;
  if public.current_account_role()<>'restaurant' then
    raise exception 'Esta cuenta no pertenece al grupo de negocios';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_restaurant_plan_business_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_restaurant_plan_business_type() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_type text;
begin
  if new.subscription_plan_id is null then return new; end if;
  select business_type into v_type from public.subscription_plans where id=new.subscription_plan_id;
  if v_type is null then raise exception 'Plan de suscripción no encontrado'; end if;
  if v_type<>coalesce(new.business_type,'restaurant') then
    raise exception 'El plan de suscripción no corresponde al tipo de negocio';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_restaurant_staff_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_restaurant_staff_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if exists(select 1 from public.admin_users a where a.user_id=new.user_id) then
    raise exception 'Una cuenta de administrador no puede asignarse como usuario de restaurante';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_subscription_payment_business_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_subscription_payment_business_type() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_plan_type text;v_business_type text;
begin
  select business_type into v_plan_type from public.subscription_plans where id=new.plan_id;
  select business_type into v_business_type from public.restaurants where id=new.restaurant_id;
  if v_plan_type is null or v_business_type is null then return new; end if;
  if v_plan_type<>v_business_type then
    raise exception 'El plan no corresponde al tipo de negocio';
  end if;
  return new;
end;
$$;


--
-- Name: finalize_professional_booking_payment_intent(bigint, numeric, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_professional_booking_payment_intent(p_intent_id bigint, p_paid_amount numeric, p_payment_method text, p_mp_payment_id text DEFAULT NULL::text, p_paid_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_i public.professional_booking_payment_intents%rowtype;
  v_rest public.restaurants%rowtype;
  v_appointment_id bigint;
  v_status text;
begin
  select * into v_i
  from public.professional_booking_payment_intents
  where id=p_intent_id
  for update;

  if v_i.id is null then raise exception 'Intento de pago no encontrado'; end if;
  if v_i.appointment_id is not null then
    return jsonb_build_object('appointment_id',v_i.appointment_id,'payment_status','approved','already_finalized',true);
  end if;
  if v_i.status in ('expired','cancelled','rejected') then raise exception 'Este intento de pago ya no está disponible'; end if;
  if p_paid_at>v_i.expires_at then raise exception 'El pago fue aprobado fuera del plazo de la reserva'; end if;
  if p_paid_amount is null or abs(p_paid_amount-v_i.amount_due)>0.01 then raise exception 'El monto pagado no coincide'; end if;

  perform pg_advisory_xact_lock(v_i.provider_id);

  select * into v_rest
  from public.restaurants
  where id=v_i.restaurant_id and business_type='professional' and active;
  if not found then raise exception 'Negocio profesional no disponible'; end if;

  if exists(
    select 1 from public.professional_appointments a
    where a.restaurant_id=v_i.restaurant_id
      and a.provider_id=v_i.provider_id
      and a.status in ('pending','confirmed','in_service')
      and tstzrange(a.starts_at,a.ends_at,'[)') &&
          tstzrange(v_i.starts_at,v_i.ends_at,'[)')
  ) then raise exception 'El horario ya no está disponible'; end if;

  v_status:=case when coalesce(v_rest.professional_booking_auto_confirm,true) then 'confirmed' else 'pending' end;

  insert into public.professional_appointments(
    restaurant_id,service_id,provider_id,customer_id,customer_name,
    customer_phone,customer_email,starts_at,ends_at,status,notes,
    payment_method,payment_status,deposit_amount,total_amount,
    payment_amount_due,paid_amount,created_by,paid_at,mp_payment_id
  ) values (
    v_i.restaurant_id,v_i.service_id,v_i.provider_id,v_i.customer_id,v_i.customer_name,
    v_i.customer_phone,v_i.customer_email,v_i.starts_at,v_i.ends_at,v_status,v_i.notes,
    nullif(btrim(coalesce(p_payment_method,'')),''),
    'approved',
    case when v_i.payment_mode='deposit' then v_i.amount_due else 0 end,
    v_i.total_amount,v_i.amount_due,p_paid_amount,v_i.customer_id,p_paid_at,p_mp_payment_id
  )
  returning id into v_appointment_id;

  update public.professional_booking_payment_intents
  set status='converted',
      payment_status='approved',
      payment_method=nullif(btrim(coalesce(p_payment_method,'')),''),
      paid_amount=p_paid_amount,
      mp_payment_id=p_mp_payment_id,
      paid_at=p_paid_at,
      appointment_id=v_appointment_id,
      updated_at=now()
  where id=v_i.id;

  return jsonb_build_object(
    'appointment_id',v_appointment_id,
    'payment_status','approved',
    'paid_amount',p_paid_amount,
    'status',v_status
  );
end;
$$;


--
-- Name: finalize_veripagos_subscription_payment(bigint, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_veripagos_subscription_payment(p_payment_id bigint, p_movement_id text, p_provider_data jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(approved boolean, restaurant_id bigint, expires_at timestamp with time zone, already_approved boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_payment public.subscription_payments%rowtype;
  v_plan public.subscription_plans%rowtype;
  v_restaurant public.restaurants%rowtype;
  v_tx public.veripagos_transactions%rowtype;
  v_now timestamptz := now();
  v_base timestamptz;
  v_exp timestamptz;
begin
  select * into v_payment
  from public.subscription_payments
  where id=p_payment_id and provider='veripagos'
  for update;

  if not found then raise exception 'Pago VeriPagos no encontrado'; end if;
  if coalesce(v_payment.provider_order_id,'')<>coalesce(p_movement_id,'') then
    raise exception 'Movimiento VeriPagos no coincide';
  end if;

  select * into v_tx
  from public.veripagos_transactions
  where scope='subscription'
    and subscription_payment_id=v_payment.id
    and movimiento_id=p_movement_id
  for update;

  if not found then raise exception 'Transacción VeriPagos no encontrada'; end if;

  select * into v_restaurant
  from public.restaurants
  where id=v_payment.restaurant_id
  for update;
  if not found then raise exception 'Restaurante no encontrado'; end if;

  if v_payment.status='approved' then
    return query select true,v_payment.restaurant_id,v_restaurant.subscription_expires_at,true;
    return;
  end if;

  select * into v_plan
  from public.subscription_plans
  where id=v_payment.plan_id;
  if not found then raise exception 'Plan no encontrado'; end if;

  if v_restaurant.subscription_plan_id=v_plan.id
     and v_restaurant.subscription_expires_at is not null
     and v_restaurant.subscription_expires_at>v_now then
    v_base:=v_restaurant.subscription_expires_at;
  else
    v_base:=v_now;
  end if;

  v_exp:=v_base + make_interval(days=>greatest(coalesce(v_payment.access_days,30),1));

  update public.subscription_payments
  set status='approved',
      paid_at=coalesce(paid_at,v_now),
      provider_meta=coalesce(provider_meta,'{}'::jsonb)
        || jsonb_build_object(
             'verified_at',v_now,
             'verification_source','veripagos',
             'provider_data',coalesce(p_provider_data,'{}'::jsonb)
           )
  where id=v_payment.id;

  update public.veripagos_transactions
  set status='approved',
      paid_at=coalesce(paid_at,v_now),
      updated_at=v_now,
      last_checked_at=v_now,
      next_check_at=null,
      check_count=check_count+1,
      last_provider_status='Completado',
      last_error=null,
      provider_data=coalesce(p_provider_data,'{}'::jsonb)
  where id=v_tx.id;

  update public.restaurants
  set subscription_status='active',
      subscription_plan_id=v_plan.id,
      subscription_plan=v_plan.name,
      subscription_price=v_payment.amount,
      subscription_started_at=v_now,
      subscription_expires_at=v_exp,
      subscription_billing_cycle=coalesce(v_payment.billing_cycle,'monthly'),
      subscription_bonus_months=coalesce(v_payment.bonus_months,0)
  where id=v_payment.restaurant_id;

  return query select true,v_payment.restaurant_id,v_exp,false;
end
$$;


--
-- Name: get_active_restaurant_tables_for_pos(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_restaurant_tables_for_pos(p_restaurant_id bigint) RETURNS TABLE(id bigint, name text, sort_order integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Sesión requerida';
  end if;

  if not public.is_site_admin()
     and not (
       public.has_restaurant_permission(p_restaurant_id,'pos')
       or public.has_restaurant_permission(p_restaurant_id,'table_qr')
     ) then
    raise exception 'No autorizado para consultar las mesas';
  end if;

  return query
  select t.id,t.name,t.sort_order
    from public.restaurant_tables t
   where t.restaurant_id=p_restaurant_id
     and t.active=true
   order by t.sort_order,t.id;
end;
$$;


--
-- Name: get_paid_restaurant_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_paid_restaurant_orders(p_restaurant_id bigint) RETURNS SETOF public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
 if auth.uid() is null then raise exception 'Sesión requerida'; end if;
 if not (public.is_site_admin() or exists(select 1 from public.restaurant_staff s where s.restaurant_id=p_restaurant_id and s.user_id=auth.uid() and s.active)) then
  raise exception 'Sin acceso al restaurante';
 end if;
 return query select o.* from public.restaurant_orders o
 where o.restaurant_id=p_restaurant_id and o.payment_method='Mercado Pago' and o.payment_status='approved'
 order by o.created_at desc limit 100;
end; $$;


--
-- Name: get_professional_available_slots(bigint, bigint, bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_professional_available_slots(p_restaurant_id bigint, p_service_id bigint, p_provider_id bigint, p_date date) RETURNS TABLE(slot_start timestamp with time zone, slot_end timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public.professional_release_expired_payment_appointments(p_restaurant_id);
  perform public.professional_release_expired_booking_payment_intents(p_restaurant_id);

  return query
  with ctx as (
    select
      r.id as restaurant_id,
      coalesce(nullif(r.timezone,''),'America/Santiago') as timezone,
      s.duration_minutes,
      s.buffer_minutes,
      coalesce(r.professional_booking_min_notice_hours,2) as min_notice_hours,
      coalesce(r.professional_booking_max_days,60) as max_days
    from public.restaurants r
    join public.professional_providers p
      on p.id=p_provider_id and p.restaurant_id=r.id and p.active
    join public.professional_services s
      on s.id=p_service_id and s.restaurant_id=r.id and s.active
    join public.professional_provider_services ps
      on ps.restaurant_id=r.id and ps.provider_id=p.id and ps.service_id=s.id
    where r.id=p_restaurant_id
      and r.business_type='professional'
      and r.active
      and r.subscription_status in ('trial','active')
      and (r.subscription_expires_at is null or r.subscription_expires_at>now())
  ),
  candidates as (
    select
      gs as slot_start,
      gs + make_interval(mins=>c.duration_minutes) as slot_end,
      c.buffer_minutes,
      c.min_notice_hours,
      c.max_days,
      c.timezone
    from ctx c
    join public.professional_availability a
      on a.restaurant_id=c.restaurant_id
     and a.provider_id=p_provider_id
     and a.active
     and a.weekday=extract(dow from p_date)::int
    cross join lateral generate_series(
      ((p_date+a.start_time)::timestamp at time zone c.timezone),
      (((p_date+a.end_time)::timestamp at time zone c.timezone)-make_interval(mins=>c.duration_minutes)),
      make_interval(mins=>greatest(a.slot_interval_minutes,5))
    ) gs
  )
  select c.slot_start,c.slot_end
  from candidates c
  where c.slot_start>=now()+make_interval(hours=>c.min_notice_hours)
    and p_date<=((now() at time zone c.timezone)::date+c.max_days)
    and not exists (
      select 1 from public.professional_time_off t
      where t.restaurant_id=p_restaurant_id
        and t.provider_id=p_provider_id
        and tstzrange(t.starts_at,t.ends_at,'[)') &&
            tstzrange(c.slot_start,c.slot_end+make_interval(mins=>c.buffer_minutes),'[)')
    )
    and not exists (
      select 1 from public.professional_appointments ap
      where ap.restaurant_id=p_restaurant_id
        and ap.provider_id=p_provider_id
        and ap.status in ('pending','confirmed','in_service')
        and tstzrange(ap.starts_at,ap.ends_at,'[)') &&
            tstzrange(c.slot_start,c.slot_end+make_interval(mins=>c.buffer_minutes),'[)')
    )
    and not exists (
      select 1 from public.professional_booking_payment_intents pi
      where pi.restaurant_id=p_restaurant_id
        and pi.provider_id=p_provider_id
        and pi.status in ('pending','processing')
        and pi.expires_at>now()
        and tstzrange(pi.starts_at,pi.block_ends_at,'[)') &&
            tstzrange(c.slot_start,c.slot_end+make_interval(mins=>c.buffer_minutes),'[)')
    )
  order by c.slot_start;
end;
$$;


--
-- Name: get_professional_public_catalog(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_professional_public_catalog(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v jsonb;
begin
  if not exists(
    select 1 from public.restaurants r
    where r.id=p_restaurant_id and r.business_type='professional' and r.active
      and r.subscription_status in ('trial','active')
      and (r.subscription_expires_at is null or r.subscription_expires_at > now())
  ) then
    raise exception 'Este profesional no está disponible';
  end if;

  select jsonb_build_object(
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'name',s.name,'description',s.description,'duration_minutes',s.duration_minutes,
        'buffer_minutes',s.buffer_minutes,'price',s.price,'image_url',s.image_url,'sort_order',s.sort_order
      ) order by s.sort_order,s.name)
      from public.professional_services s
      where s.restaurant_id=p_restaurant_id and s.active
    ),'[]'::jsonb),
    'providers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,'name',p.name,'specialty',p.specialty,'bio',p.bio,'photo_url',p.photo_url,'sort_order',p.sort_order,
        'service_ids',coalesce((select jsonb_agg(ps.service_id) from public.professional_provider_services ps where ps.provider_id=p.id),'[]'::jsonb)
      ) order by p.sort_order,p.name)
      from public.professional_providers p
      where p.restaurant_id=p_restaurant_id and p.active
    ),'[]'::jsonb),
    'booking', (
      select jsonb_build_object(
        'auto_confirm',r.professional_booking_auto_confirm,
        'min_notice_hours',r.professional_booking_min_notice_hours,
        'max_days',r.professional_booking_max_days,
        'payment_mode',coalesce(nullif(r.professional_booking_payment_mode,''),case when coalesce(r.professional_booking_deposit_required,false) then 'deposit' else 'full' end),
        'deposit_required',r.professional_booking_deposit_required,
        'deposit_amount',r.professional_booking_deposit_amount,
        'accept_bank_transfer',r.accept_bank_transfer,
        'accept_mercadopago',r.accept_mercadopago,
        'timezone',r.timezone,'currency_code',r.currency_code,'locale',r.locale
      )
      from public.restaurants r where r.id=p_restaurant_id
    )
  ) into v;
  return v;
end;
$$;


--
-- Name: get_public_professional_appointment_status(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_professional_appointment_status(p_appointment_id bigint, p_public_token uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object(
    'id',a.id,
    'status',a.status,
    'payment_status',a.payment_status,
    'payment_method',a.payment_method,
    'deposit_amount',a.deposit_amount,
    'payment_amount_due',a.payment_amount_due,
    'paid_amount',a.paid_amount,
    'total_amount',a.total_amount,
    'starts_at',a.starts_at,
    'ends_at',a.ends_at,
    'payment_expires_at',a.payment_expires_at,
    'paid_at',a.paid_at,
    'service_name',s.name,
    'provider_name',p.name,
    'restaurant_name',r.name,
    'currency_code',r.currency_code,
    'locale',r.locale,
    'timezone',r.timezone
  )
  from public.professional_appointments a
  join public.professional_services s on s.id=a.service_id and s.restaurant_id=a.restaurant_id
  join public.professional_providers p on p.id=a.provider_id and p.restaurant_id=a.restaurant_id
  join public.restaurants r on r.id=a.restaurant_id
  where a.id=p_appointment_id
    and a.public_token=p_public_token
    and r.business_type='professional';
$$;


--
-- Name: get_public_professional_booking_payment_status(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_professional_booking_payment_status(p_intent_id bigint, p_public_token uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object(
    'intent_id',i.id,
    'payment_status',i.payment_status,
    'status',i.status,
    'payment_method',i.payment_method,
    'amount_due',i.amount_due,
    'paid_amount',i.paid_amount,
    'total_amount',i.total_amount,
    'starts_at',i.starts_at,
    'ends_at',i.ends_at,
    'expires_at',i.expires_at,
    'paid_at',i.paid_at,
    'appointment_id',i.appointment_id,
    'service_name',s.name,
    'provider_name',p.name,
    'restaurant_name',r.name,
    'currency_code',r.currency_code,
    'locale',r.locale,
    'timezone',r.timezone
  )
  from public.professional_booking_payment_intents i
  join public.professional_services s on s.id=i.service_id and s.restaurant_id=i.restaurant_id
  join public.professional_providers p on p.id=i.provider_id and p.restaurant_id=i.restaurant_id
  join public.restaurants r on r.id=i.restaurant_id
  where i.id=p_intent_id
    and i.public_token=p_public_token
    and r.business_type='professional';
$$;


--
-- Name: get_public_professional_catalog(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_professional_catalog(p_slug text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
select jsonb_build_object(
  'restaurant', jsonb_build_object(
    'id',r.id,'name',r.name,'slug',r.slug,'logo_url',r.logo_url,
    'address',r.address,'whatsapp',r.whatsapp,'currency_code',r.currency_code,
    'locale',r.locale,'timezone',r.timezone,'country_code',r.country_code
  ),
  'services', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'description',s.description,
      'duration_minutes',s.duration_minutes,'buffer_minutes',s.buffer_minutes,
      'price',s.price,'image_url',s.image_url
    ) order by s.sort_order,s.name)
    from public.professional_services s
    where s.restaurant_id=r.id and s.active
  ),'[]'::jsonb),
  'providers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'specialty',p.specialty,'bio',p.bio,
      'photo_url',p.photo_url,
      'service_ids',coalesce((
        select jsonb_agg(ps.service_id order by ps.service_id)
        from public.professional_provider_services ps
        where ps.restaurant_id=r.id and ps.provider_id=p.id
      ),'[]'::jsonb)
    ) order by p.sort_order,p.name)
    from public.professional_providers p
    where p.restaurant_id=r.id and p.active
  ),'[]'::jsonb)
)
from public.restaurants r
where r.slug=p_slug
  and r.business_type='professional'
  and r.active
  and r.subscription_status in ('trial','active')
  and (r.subscription_expires_at is null or r.subscription_expires_at > now())
limit 1;
$$;


--
-- Name: get_public_retail_catalog(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_retail_catalog(p_restaurant_id bigint) RETURNS TABLE(id bigint, barcode text, sku text, name text, description text, category text, brand text, unit text, price numeric, current_stock numeric, minimum_stock numeric, image_url text, allow_fractional boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform public.retail_release_expired_online_orders();

  if not exists(
    select 1 from public.restaurants r
    where r.id=p_restaurant_id
      and r.active=true
      and r.business_type in ('supermarket','minimarket')
      and r.subscription_status in ('trial','active')
      and (r.subscription_expires_at is null or r.subscription_expires_at>now())
  ) then
    return;
  end if;

  return query
  select p.id,p.barcode,p.sku,p.name,p.description,p.category,p.brand,p.unit,p.price,
         p.current_stock,p.minimum_stock,p.image_url,p.allow_fractional
  from public.retail_products p
  where p.restaurant_id=p_restaurant_id and p.active=true
  order by coalesce(p.category,''),p.name;
end;
$$;


--
-- Name: get_ready_counter_qr_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_ready_counter_qr_orders(p_restaurant_id bigint) RETURNS TABLE(id bigint, order_code text, table_reference text, customer_name text, items jsonb, total numeric, payment_status text, payment_method text, created_at timestamp with time zone, ready_at timestamp with time zone, paid_online boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then raise exception 'Sesión requerida'; end if;
  if not public.is_site_admin()
     and not (
       public.has_restaurant_permission(p_restaurant_id,'cash')
       or public.has_restaurant_permission(p_restaurant_id,'pos')
     ) then
    raise exception 'No autorizado para ver retiros de mostrador';
  end if;

  return query
  select o.id,o.order_code,o.table_reference,o.customer_name,o.items,o.total,
         o.payment_status,o.payment_method,o.created_at,o.ready_at,
         (
           lower(trim(coalesce(o.payment_method,''))) in ('mercado pago','qr bolivia')
           and lower(trim(coalesce(o.payment_status,'')))='approved'
         ) as paid_online
  from public.restaurant_orders o
  where o.restaurant_id=p_restaurant_id
    and o.order_source='table_qr'
    and o.order_type='Retiro'
    and o.status='listo'
    and (
      lower(trim(coalesce(o.payment_method,''))) not in ('mercado pago','qr bolivia')
      or lower(trim(coalesce(o.payment_status,'')))='approved'
    )
  order by coalesce(o.ready_at,o.updated_at,o.created_at),o.id;
end
$$;


--
-- Name: get_ready_table_qr_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_ready_table_qr_orders(p_restaurant_id bigint) RETURNS TABLE(id bigint, order_code text, table_reference text, customer_name text, items jsonb, total numeric, payment_status text, payment_method text, created_at timestamp with time zone, ready_at timestamp with time zone, paid_online boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then raise exception 'Sesión requerida'; end if;
  if not public.is_site_admin()
     and not public.has_restaurant_permission(p_restaurant_id,'pos') then
    raise exception 'No autorizado para ver pedidos QR listos';
  end if;

  return query
  select o.id,o.order_code,o.table_reference,o.customer_name,o.items,o.total,
         o.payment_status,o.payment_method,o.created_at,o.ready_at,
         (
           lower(trim(coalesce(o.payment_method,''))) in ('mercado pago','qr bolivia')
           and lower(trim(coalesce(o.payment_status,'')))='approved'
         ) as paid_online
  from public.restaurant_orders o
  where o.restaurant_id=p_restaurant_id
    and o.order_source='table_qr'
    and o.order_type='Mesa'
    and o.status='listo'
    and (
      lower(trim(coalesce(o.payment_method,''))) not in ('mercado pago','qr bolivia')
      or lower(trim(coalesce(o.payment_status,'')))='approved'
    )
  order by coalesce(o.ready_at,o.updated_at,o.created_at),o.id;
end
$$;


--
-- Name: get_restaurant_paid_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_restaurant_paid_orders(p_restaurant_id bigint) RETURNS SETOF public.restaurant_orders
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select o.*
  from public.restaurant_orders o
  where o.restaurant_id = p_restaurant_id
    and o.payment_method = 'Mercado Pago'
    and o.payment_status = 'approved'
    and (
      public.is_site_admin()
      or exists (
        select 1 from public.restaurant_staff s
        where s.restaurant_id = p_restaurant_id
          and s.user_id = auth.uid()
          and s.active = true
      )
    )
  order by o.created_at desc
  limit 100
$$;


--
-- Name: get_restaurant_staff_directory(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_restaurant_staff_directory(p_restaurant_id bigint) RETURNS TABLE(user_id uuid, display_name text, role text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Sesión requerida';
  end if;

  if not public.is_site_admin()
     and not exists (
       select 1
       from public.restaurant_staff caller_staff
       where caller_staff.restaurant_id = p_restaurant_id
         and caller_staff.user_id = auth.uid()
         and caller_staff.active = true
     ) then
    raise exception 'No autorizado para consultar el personal de este restaurante';
  end if;

  return query
  select s.user_id,
         coalesce(nullif(trim(s.display_name),''), split_part(s.email,'@',1)) as display_name,
         s.role
    from public.restaurant_staff s
   where s.restaurant_id = p_restaurant_id
   order by coalesce(nullif(trim(s.display_name),''), split_part(s.email,'@',1));
end;
$$;


--
-- Name: get_restaurant_subscription_access(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_restaurant_subscription_access(p_restaurant_id bigint) RETURNS TABLE(restaurant_id bigint, subscription_usable boolean, subscription_status text, plan_id bigint, plan_name text, customized boolean, base_modules jsonb, effective_modules jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  r public.restaurants%rowtype;
  p public.subscription_plans%rowtype;
  v_base jsonb := '[]'::jsonb;
  v_effective jsonb := '[]'::jsonb;
  v_usable boolean := false;
  v_type text := 'restaurant';
begin
  if not (
    public.is_site_admin()
    or exists(
      select 1 from public.restaurant_staff s
      where s.restaurant_id=p_restaurant_id and s.user_id=auth.uid() and s.active=true
    )
  ) then raise exception 'No autorizado'; end if;

  select * into r from public.restaurants where id=p_restaurant_id;
  if not found then raise exception 'Restaurante no encontrado'; end if;
  v_type := lower(coalesce(r.business_type,'restaurant'));

  v_usable := r.active
    and lower(coalesce(r.subscription_status,'')) in ('trial','active')
    and (r.subscription_expires_at is null or r.subscription_expires_at > now());

  if r.subscription_plan_id is not null then
    select * into p
    from public.subscription_plans
    where id=r.subscription_plan_id
      and business_type=coalesce(r.business_type,'restaurant')
    limit 1;
  elsif lower(coalesce(r.subscription_status,''))='trial'
     or lower(coalesce(r.subscription_plan,'')) like '%prueba%' then
    select * into p
    from public.subscription_plans
    where is_default_trial=true
      and business_type=coalesce(r.business_type,'restaurant')
    limit 1;
  end if;

  v_base := public.normalize_module_array(coalesce(p.modules,'[]'::jsonb));

  if coalesce(r.is_demo,false) then
    if v_type in ('supermarket','minimarket') then
      v_effective := public.normalize_module_array(
        '["dashboard","cash","retail_orders","retail_pos","retail_products","retail_suppliers","retail_purchases","staff","qr","plans","settings"]'::jsonb
      );
    elsif v_type='professional' then
      v_effective := public.normalize_module_array(
        '["dashboard","appointments","services","professionals","clients","cash","staff","reports","qr","plans","settings"]'::jsonb
      );
    else
      v_effective := public.normalize_module_array(
        '["dashboard","orders","pos","kitchen","cash","products","categories","inventory","staff","promotions","reviews","table_qr","qr","plans","settings"]'::jsonb
      );
    end if;
    v_base := v_effective;
  elsif coalesce(r.subscription_modules_customized,false) then
    v_effective := public.normalize_module_array(coalesce(r.subscription_module_overrides,'[]'::jsonb));
  else
    v_effective := v_base;
  end if;

  if not v_usable then v_effective := '[]'::jsonb; end if;

  return query select
    r.id,v_usable,r.subscription_status,coalesce(r.subscription_plan_id,p.id),
    coalesce(p.name,r.subscription_plan),coalesce(r.subscription_modules_customized,false),
    v_base,v_effective;
end;
$$;


--
-- Name: get_table_qr_context(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_qr_context(p_table_token uuid) RETURNS TABLE(table_id bigint, restaurant_id bigint, table_name text, restaurant_slug text, restaurant_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select t.id, r.id, t.name, r.slug, r.name
  from public.restaurant_tables t
  join public.restaurants r on r.id=t.restaurant_id
  where t.token=p_table_token
    and t.active=true
    and public.restaurant_subscription_module_enabled(r.id,'table_qr')
  limit 1;
$$;


--
-- Name: get_table_qr_order_status(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_qr_order_status(p_order_id bigint, p_table_token uuid) RETURNS TABLE(order_id bigint, order_code text, status text, payment_status text, payment_method text, table_name text, total numeric, items jsonb, notes text, created_at timestamp with time zone, updated_at timestamp with time zone, ready_at timestamp with time zone, delivered_at timestamp with time zone, currency_code text, order_source text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select o.id,o.order_code,o.status,o.payment_status,o.payment_method,t.name,o.total,
         o.items,o.notes,o.created_at,o.updated_at,o.ready_at,o.delivered_at,o.currency_code,o.order_source
  from public.restaurant_orders o
  join public.restaurant_tables t on t.id=o.restaurant_table_id
  where o.id=p_order_id
    and o.order_source='table_qr'
    and t.token=p_table_token
  limit 1;
$$;


--
-- Name: get_table_qr_order_status_v2(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_qr_order_status_v2(p_order_id bigint, p_table_token uuid) RETURNS TABLE(order_id bigint, order_code text, status text, payment_status text, payment_method text, order_type text, table_name text, total numeric, items jsonb, notes text, created_at timestamp with time zone, updated_at timestamp with time zone, ready_at timestamp with time zone, delivered_at timestamp with time zone, currency_code text, order_source text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select o.id,o.order_code,o.status,o.payment_status,o.payment_method,o.order_type,t.name,o.total,
         o.items,o.notes,o.created_at,o.updated_at,o.ready_at,o.delivered_at,o.currency_code,o.order_source
  from public.restaurant_orders o
  join public.restaurant_tables t on t.id=o.restaurant_table_id
  where o.id=p_order_id
    and o.order_source='table_qr'
    and t.token=p_table_token
  limit 1
$$;


--
-- Name: get_waiter_paid_qr_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_waiter_paid_qr_orders(p_restaurant_id bigint) RETURNS TABLE(id bigint, order_code text, table_reference text, customer_name text, items jsonb, total numeric, payment_status text, payment_method text, status text, created_at timestamp with time zone, ready_at timestamp with time zone, kitchen_picked_up_at timestamp with time zone, delivered_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then raise exception 'Sesión requerida'; end if;
  if not public.is_site_admin()
     and not public.has_restaurant_permission(p_restaurant_id,'pos') then
    raise exception 'No autorizado para consultar pedidos QR';
  end if;

  return query
  select o.id,o.order_code,o.table_reference,o.customer_name,o.items,o.total,
         o.payment_status,o.payment_method,o.status,o.created_at,o.ready_at,
         o.kitchen_picked_up_at,o.delivered_at
  from public.restaurant_orders o
  where o.restaurant_id=p_restaurant_id
    and o.order_source='table_qr'
    and o.order_type='Mesa'
    and lower(trim(coalesce(o.payment_method,''))) in ('mercado pago','qr bolivia')
    and lower(trim(coalesce(o.payment_status,'')))='approved'
    and o.created_by=auth.uid()
    and o.status in ('retirado_mesa','entregado','cancelado')
  order by coalesce(o.kitchen_picked_up_at,o.updated_at,o.created_at) desc,o.id desc;
end
$$;


--
-- Name: handle_new_customer_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_customer_profile() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.customer_profiles(user_id,full_name,phone)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),new.raw_user_meta_data->>'phone')
  on conflict (user_id) do update set
    full_name=excluded.full_name,
    phone=coalesce(excluded.phone,public.customer_profiles.phone),
    updated_at=now();
  return new;
end;
$$;


--
-- Name: handle_site_admin_signup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_site_admin_signup() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if lower(new.email) = 'scuentas150@gmail.com' then
    insert into public.admin_users (user_id, email)
    values (new.id, new.email)
    on conflict (user_id) do update set email = excluded.email;
  end if;
  return new;
end;
$$;


--
-- Name: has_admin_client_preview(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_admin_client_preview(p_restaurant_id bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select
    auth.uid() is not null
    and public.is_site_admin()
    and exists(
      select 1
      from public.admin_client_preview_sessions s
      where s.session_id=(auth.jwt()->>'session_id')
        and s.user_id=auth.uid()
        and s.restaurant_id=p_restaurant_id
        and s.expires_at>now()
    );
$$;


--
-- Name: has_restaurant_permission(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_restaurant_permission(rid bigint, permission_name text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
  select public.is_site_admin() or exists(
    select 1 from public.restaurant_staff s
    where s.restaurant_id=rid
      and s.user_id=(select auth.uid())
      and s.active
      and (
        case
          when permission_name='pos' then s.role='waiter'
          when permission_name='kitchen' then s.role='kitchen'
          else (
            coalesce((s.permissions->>permission_name)::boolean,false)
            or s.role='restaurant'
            or (s.role='manager' and permission_name in ('dashboard','orders','menu','inventory','cash','payments','customers','promotions','reviews','delivery','reports','staff','table_qr','appointments','services','professionals','settings'))
            or (s.role='editor' and permission_name in ('orders','menu','inventory','promotions','services'))
            or (s.role='cashier' and permission_name in ('orders','cash','payments','customers','appointments'))
            or (s.role='kitchen' and permission_name in ('orders'))
            or (s.role='courier' and permission_name in ('orders','delivery'))
            or (s.role='professional' and permission_name in ('dashboard','appointments','services','customers'))
            or (s.role='receptionist' and permission_name in ('dashboard','appointments','customers','cash'))
          )
        end
      )
  );
$$;


--
-- Name: initialize_restaurant_trial(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initialize_restaurant_trial() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if new.subscription_started_at is null then new.subscription_started_at=now(); end if;
 if new.subscription_expires_at is null then new.subscription_expires_at=new.subscription_started_at + interval '30 days'; end if;
 return new;
end $$;


--
-- Name: is_site_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_site_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.admin_users
    where user_id = (select auth.uid())
      and lower(email) = lower(coalesce((select auth.jwt()->>'email'), ''))
  );
$$;


--
-- Name: is_system_manager(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_system_manager() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
 select public.is_site_admin() or exists(select 1 from public.restaurant_staff s where s.user_id=auth.uid() and s.active and s.role='manager');
$$;


--
-- Name: log_app_error(text, text, text, text, text, boolean, bigint, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_app_error(p_app_context text, p_category text DEFAULT 'system'::text, p_error_code text DEFAULT NULL::text, p_message text DEFAULT NULL::text, p_severity text DEFAULT 'error'::text, p_is_user_error boolean DEFAULT false, p_restaurant_id bigint DEFAULT NULL::bigint, p_session_id text DEFAULT NULL::text, p_route text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id bigint; v_severity text;
begin
  if p_app_context not in ('landing','restaurant','client','admin') then
    raise exception 'Contexto inválido';
  end if;
  v_severity:=case when p_severity in ('info','warning','error','critical') then p_severity else 'error' end;
  insert into public.app_errors(app_context,category,error_code,message,severity,is_user_error,restaurant_id,user_id,session_id,route,metadata)
  values(
    p_app_context,
    left(coalesce(nullif(trim(p_category),''),'system'),80),
    nullif(left(coalesce(trim(p_error_code),''),120),''),
    nullif(left(coalesce(trim(p_message),''),700),''),
    v_severity,
    coalesce(p_is_user_error,false),
    p_restaurant_id,
    auth.uid(),
    nullif(left(coalesce(trim(p_session_id),''),120),''),
    nullif(left(coalesce(trim(p_route),''),300),''),
    coalesce(p_metadata,'{}'::jsonb)
  )
  returning id into v_id;
  return v_id;
end
$$;


--
-- Name: log_app_event(text, text, text, bigint, bigint, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_app_event(p_app_context text, p_event_name text, p_module text DEFAULT NULL::text, p_restaurant_id bigint DEFAULT NULL::bigint, p_plan_id bigint DEFAULT NULL::bigint, p_session_id text DEFAULT NULL::text, p_route text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id bigint;
begin
  if p_app_context not in ('landing','restaurant','client','admin') then
    raise exception 'Contexto inválido';
  end if;
  if coalesce(trim(p_event_name),'')='' then
    raise exception 'Evento inválido';
  end if;
  insert into public.app_events(app_context,event_name,module,restaurant_id,user_id,plan_id,session_id,route,metadata)
  values(
    p_app_context,
    left(trim(p_event_name),120),
    nullif(left(coalesce(trim(p_module),''),80),''),
    p_restaurant_id,
    auth.uid(),
    p_plan_id,
    nullif(left(coalesce(trim(p_session_id),''),120),''),
    nullif(left(coalesce(trim(p_route),''),300),''),
    coalesce(p_metadata,'{}'::jsonb)
  )
  returning id into v_id;
  return v_id;
end
$$;


--
-- Name: mark_mp_credential_source_from_override(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_mp_credential_source_from_override() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_admin boolean:=false;
begin
  if new.mp_preference_id is not null
     and (tg_op='INSERT' or old.mp_preference_id is distinct from new.mp_preference_id) then
    select coalesce(enabled,false)
      into v_admin
    from public.business_payment_test_overrides
    where restaurant_id=new.restaurant_id;

    new.mp_credential_source:=case when coalesce(v_admin,false) then 'admin' else 'business' end;
  end if;
  return new;
end;
$$;


--
-- Name: my_customer_orders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_customer_orders() RETURNS SETOF public.restaurant_orders
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ select * from public.restaurant_orders where customer_id=auth.uid() order by created_at desc; $$;


--
-- Name: normalize_module_array(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_module_array(p_modules jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  select coalesce(jsonb_agg(x.value order by x.value),'[]'::jsonb)
  from (
    select distinct value
    from jsonb_array_elements_text(
      case when jsonb_typeof(coalesce(p_modules,'[]'::jsonb))='array'
           then coalesce(p_modules,'[]'::jsonb)
           else '[]'::jsonb end
    )
  ) x;
$$;


--
-- Name: notify_new_restaurant_by_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_new_restaurant_by_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.role = 'restaurant' and new.active = true then
    perform net.http_post(
      url := 'https://gulctljitzlwokqydigx.supabase.co/functions/v1/restaurant-email-notifications',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object(
        'restaurant_id', new.restaurant_id,
        'event_type', 'welcome',
        'event_key', 'welcome:' || new.restaurant_id::text
      )
    );
    perform net.http_post(
      url := 'https://gulctljitzlwokqydigx.supabase.co/functions/v1/restaurant-email-notifications',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object(
        'restaurant_id', new.restaurant_id,
        'event_type', 'trial_started',
        'event_key', 'trial-start:' || new.restaurant_id::text
      )
    );
  end if;
  return new;
end;
$$;


--
-- Name: pay_waiter_order(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pay_waiter_order(p_order_id bigint, p_payment_method text) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
  v_session public.restaurant_cash_sessions%rowtype;
  v_method text;
  v_is_pos boolean;
  v_is_cash boolean;
begin
  v_method := nullif(trim(coalesce(p_payment_method,'')),'');
  if v_method is null or char_length(v_method)>80 then
    raise exception 'Selecciona un método de pago válido';
  end if;

  select *
    into v_order
    from public.restaurant_orders
   where id = p_order_id
   for update;

  if not found or v_order.order_source not in ('waiter','table_qr') then
    raise exception 'Pedido no encontrado';
  end if;

  v_is_pos := public.has_restaurant_permission(v_order.restaurant_id, 'pos');
  v_is_cash := public.has_restaurant_permission(v_order.restaurant_id, 'cash');

  if not (v_is_pos or v_is_cash) then
    raise exception 'No autorizado para cobrar este pedido';
  end if;

  if v_order.order_source='waiter' then
    if v_order.status <> 'entregado' then
      raise exception 'Primero retira el pedido de cocina antes de cobrar la cuenta';
    end if;
  else
    if lower(trim(coalesce(v_order.payment_method,'')))='mercado pago'
       and lower(trim(coalesce(v_order.payment_status,'')))='approved' then
      return v_order;
    end if;
    if v_order.status not in ('retirado_mesa','entregado') then
      raise exception 'Primero retira el pedido QR de cocina antes de cobrar la cuenta';
    end if;
  end if;

  if v_is_pos and not v_is_cash and not public.is_site_admin()
     and v_order.created_by is distinct from auth.uid() then
    raise exception 'Solo puedes cobrar los pedidos que tú retiraste o creaste';
  end if;

  if v_order.payment_status = 'approved' then
    return v_order;
  end if;

  select *
    into v_session
    from public.restaurant_cash_sessions
   where restaurant_id = v_order.restaurant_id
     and status = 'open'
   order by opened_at desc
   limit 1;

  if not found then
    raise exception 'Primero debe abrirse la caja para cobrar la cuenta';
  end if;

  update public.restaurant_orders
     set payment_method = v_method,
         payment_status = 'approved',
         payment_verification_status = 'approved',
         paid_at = now(),
         status = case when order_source='table_qr' then 'entregado' else status end,
         delivered_at = case when order_source='table_qr' then coalesce(delivered_at,now()) else delivered_at end,
         updated_at = now()
   where id = p_order_id
   returning * into v_order;

  insert into public.restaurant_cash_movements(
    restaurant_id, session_id, order_id, movement_type,
    payment_method, amount, description, created_by
  )
  values (
    v_order.restaurant_id, v_session.id, v_order.id, 'sale',
    v_method, v_order.total, 'Pedido ' || v_order.order_code, auth.uid()
  );

  return v_order;
end
$$;


--
-- Name: process_subscription_email_reminders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_subscription_email_reminders() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  rec record;
  local_today date;
  local_expiry date;
  diff integer;
  event_type text;
begin
  for rec in
    select id, subscription_expires_at, coalesce(timezone,'America/Santiago') as tz, subscription_status
    from public.restaurants
    where subscription_expires_at is not null
      and coalesce(subscription_status,'') in ('trial','active')
  loop
    local_today := (now() at time zone rec.tz)::date;
    local_expiry := (rec.subscription_expires_at at time zone rec.tz)::date;
    diff := local_expiry - local_today;
    event_type := case when diff = 7 then 'expiring_7d' when diff = 1 then 'expiring_1d' when diff <= 0 then 'expired' else null end;
    if event_type is not null then
      perform net.http_post(
        url := 'https://gulctljitzlwokqydigx.supabase.co/functions/v1/restaurant-email-notifications',
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object(
          'restaurant_id', rec.id,
          'event_type', event_type,
          'event_key', event_type || ':' || rec.id::text || ':' || rec.subscription_expires_at::text
        )
      );
      if event_type = 'expired' then
        update public.restaurants set subscription_status='expired' where id=rec.id;
      end if;
    end if;
  end loop;
end;
$$;


--
-- Name: professional_release_expired_booking_payment_intents(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.professional_release_expired_booking_payment_intents(p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_count integer;
begin
  update public.professional_booking_payment_intents
  set status='expired', payment_status='expired', updated_at=now()
  where status in ('pending','processing')
    and expires_at<=now()
    and (p_restaurant_id is null or restaurant_id=p_restaurant_id);
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;


--
-- Name: professional_release_expired_payment_appointments(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.professional_release_expired_payment_appointments(p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_count integer;
begin
  update public.professional_appointments
  set status='cancelled',
      payment_status='expired',
      updated_at=now()
  where status in ('pending','confirmed')
    and payment_status='pending'
    and payment_expires_at is not null
    and payment_expires_at <= now()
    and (p_restaurant_id is null or restaurant_id=p_restaurant_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


--
-- Name: protect_default_trial_plan(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_default_trial_plan() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if tg_op='UPDATE' and old.is_default_trial then
    new.is_default_trial := true;
  end if;

  if new.is_default_trial then
    new.amount := 0;
    new.active := true;
  end if;

  return new;
end
$$;


--
-- Name: register_table_qr_push_subscription(bigint, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_table_qr_push_subscription(p_order_id bigint, p_table_token uuid, p_endpoint text, p_p256dh text, p_auth text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ok boolean;
begin
  select exists(
    select 1
    from public.restaurant_orders o
    join public.restaurant_tables t on t.id=o.restaurant_table_id
    where o.id=p_order_id
      and o.order_source='table_qr'
      and t.token=p_table_token
  ) into v_ok;
  if not v_ok then
    raise exception 'Pedido QR no válido para esta mesa';
  end if;
  if nullif(trim(coalesce(p_endpoint,'')),'') is null
     or nullif(trim(coalesce(p_p256dh,'')),'') is null
     or nullif(trim(coalesce(p_auth,'')),'') is null then
    raise exception 'Suscripción push inválida';
  end if;
  insert into public.table_qr_push_subscriptions(order_id,endpoint,p256dh,auth,enabled,updated_at)
  values(p_order_id,p_endpoint,p_p256dh,p_auth,true,now())
  on conflict(order_id,endpoint) do update
    set p256dh=excluded.p256dh,auth=excluded.auth,enabled=true,updated_at=now();
  return true;
end
$$;


--
-- Name: professional_appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_appointments (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    service_id bigint NOT NULL,
    provider_id bigint NOT NULL,
    customer_id uuid,
    customer_name text NOT NULL,
    customer_phone text DEFAULT ''::text NOT NULL,
    customer_email text,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    notes text,
    payment_method text,
    payment_status text DEFAULT 'not_required'::text NOT NULL,
    deposit_amount numeric DEFAULT 0 NOT NULL,
    total_amount numeric DEFAULT 0 NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    public_token uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_expires_at timestamp with time zone,
    mp_preference_id text,
    mp_payment_id text,
    paid_at timestamp with time zone,
    refund_status text DEFAULT 'none'::text NOT NULL,
    refund_amount numeric(12,2) DEFAULT 0 NOT NULL,
    refunded_at timestamp with time zone,
    mp_refund_id text,
    payment_amount_due numeric DEFAULT 0 NOT NULL,
    paid_amount numeric DEFAULT 0 NOT NULL,
    mp_credential_source text,
    CONSTRAINT professional_appointments_check CHECK ((ends_at > starts_at)),
    CONSTRAINT professional_appointments_deposit_amount_check CHECK ((deposit_amount >= (0)::numeric)),
    CONSTRAINT professional_appointments_mp_credential_source_check CHECK (((mp_credential_source IS NULL) OR (mp_credential_source = ANY (ARRAY['admin'::text, 'business'::text])))),
    CONSTRAINT professional_appointments_payment_status_check CHECK ((payment_status = ANY (ARRAY['not_required'::text, 'pending'::text, 'approved'::text, 'rejected'::text, 'refunded'::text, 'expired'::text, 'cancelled'::text]))),
    CONSTRAINT professional_appointments_refund_amount_check CHECK ((refund_amount >= (0)::numeric)),
    CONSTRAINT professional_appointments_refund_status_check CHECK ((refund_status = ANY (ARRAY['none'::text, 'pending'::text, 'refunded'::text, 'failed'::text]))),
    CONSTRAINT professional_appointments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'in_service'::text, 'completed'::text, 'cancelled'::text, 'no_show'::text]))),
    CONSTRAINT professional_appointments_total_amount_check CHECK ((total_amount >= (0)::numeric)),
    CONSTRAINT professional_appointments_valid_range CHECK ((ends_at > starts_at))
);


--
-- Name: reschedule_professional_appointment(bigint, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reschedule_professional_appointment(p_appointment_id bigint, p_starts_at timestamp with time zone) RETURNS public.professional_appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ap public.professional_appointments%rowtype;
  v_timezone text;
  v_duration interval;
  v_local_date date;
begin
  select ap.*
    into v_ap
  from public.professional_appointments ap
  where ap.id = p_appointment_id;

  if not found then
    raise exception 'Cita no encontrada';
  end if;

  if not exists (
    select 1
    from public.restaurants r
    where r.id = v_ap.restaurant_id
      and r.business_type = 'professional'
  ) then
    raise exception 'La cita no pertenece al rubro profesional';
  end if;

  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(v_ap.restaurant_id, 'appointments')
  ) then
    raise exception 'Sin permiso para reprogramar esta cita';
  end if;

  if v_ap.status not in ('pending','confirmed') then
    raise exception 'Solo se pueden reprogramar citas pendientes o confirmadas';
  end if;

  select coalesce(nullif(r.timezone,''),'America/Santiago')
    into v_timezone
  from public.restaurants r
  where r.id = v_ap.restaurant_id;

  v_duration := v_ap.ends_at - v_ap.starts_at;
  v_local_date := (p_starts_at at time zone v_timezone)::date;

  if not exists (
    select 1
    from public.get_professional_available_slots(
      v_ap.restaurant_id,
      v_ap.service_id,
      v_ap.provider_id,
      v_local_date
    ) s
    where s.slot_start = p_starts_at
  ) then
    raise exception 'El horario seleccionado ya no está disponible';
  end if;

  update public.professional_appointments
  set starts_at = p_starts_at,
      ends_at = p_starts_at + v_duration,
      updated_at = now()
  where id = v_ap.id
  returning * into v_ap;

  return v_ap;
end;
$$;


--
-- Name: restaurant_has_open_cash(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restaurant_has_open_cash(p_restaurant_id bigint) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if not (
    public.is_site_admin()
    or exists(
      select 1
      from public.restaurant_staff s
      where s.restaurant_id=p_restaurant_id
        and s.user_id=(select auth.uid())
        and s.active
    )
  ) then
    raise exception 'No autorizado para consultar la caja de este restaurante';
  end if;

  return exists(
    select 1
    from public.restaurant_cash_sessions cs
    where cs.restaurant_id=p_restaurant_id
      and cs.status='open'
  );
end;
$$;


--
-- Name: restaurant_mp_connection_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restaurant_mp_connection_status(rid bigint) RETURNS TABLE(configured boolean, mp_user_id text, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
 select
   case
     when coalesce(o.enabled,false) then exists(
       select 1 from public.subscription_payment_settings s
       where nullif(trim(coalesce(s.public_key,'')),'') is not null
         and nullif(trim(coalesce(s.access_token,'')),'') is not null
     )
     else (
       nullif(trim(coalesce(r.mercadopago_public_key,'')),'') is not null
       and c.access_token is not null and length(c.access_token)>10
     )
   end as configured,
   case when coalesce(o.enabled,false) then null else c.mp_user_id end,
   coalesce(o.updated_at,c.updated_at,r.updated_at)
 from public.restaurants r
 left join public.restaurant_payment_connections c on c.restaurant_id=r.id
 left join public.business_payment_test_overrides o on o.restaurant_id=r.id
 where r.id=rid
   and exists(select 1 from public.admin_users a where a.user_id=auth.uid());
$$;


--
-- Name: restaurant_mp_public_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restaurant_mp_public_status(rid bigint) RETURNS TABLE(configured boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists(
    select 1
    from public.restaurants r
    join public.restaurant_payment_connections c
      on c.restaurant_id=r.id
    join public.platform_countries pc
      on pc.code=r.country_code
    where r.id=rid
      and r.active
      and coalesce(r.accept_mercadopago,true)
      and pc.active
      and pc.mercadopago_enabled
      and upper(coalesce(r.currency_code,''))=upper(coalesce(pc.currency_code,''))
      and length(trim(coalesce(r.mercadopago_public_key,'')))>5
      and length(trim(coalesce(c.access_token,'')))>10
  ) as configured;
$$;


--
-- Name: restaurant_subscription_module_enabled(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restaurant_subscription_module_enabled(rid bigint, module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists(
    select 1
    from public.restaurants r
    left join public.subscription_plans assigned on assigned.id=r.subscription_plan_id
    left join public.subscription_plans trial on trial.is_default_trial=true
    where r.id=rid
      and r.active=true
      and lower(coalesce(r.subscription_status,'')) in ('trial','active')
      and (r.subscription_expires_at is null or r.subscription_expires_at > now())
      and (
        case
          when coalesce(r.subscription_modules_customized,false) then
            coalesce(r.subscription_module_overrides,'[]'::jsonb) ? module_key
          else
            coalesce(
              case
                when r.subscription_plan_id is not null then assigned.modules
                when lower(coalesce(r.subscription_status,''))='trial'
                  or lower(coalesce(r.subscription_plan,'')) like '%prueba%' then trial.modules
                else '[]'::jsonb
              end,
              '[]'::jsonb
            ) ? module_key
        end
      )
  );
$$;


--
-- Name: retail_adjust_stock(bigint, bigint, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_adjust_stock(p_restaurant_id bigint, p_product_id bigint, p_new_stock numeric, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_product public.retail_products%rowtype;
  v_delta numeric;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not (public.is_site_admin() or public.has_restaurant_permission(p_restaurant_id,'inventory')) then
    raise exception 'No autorizado';
  end if;
  if p_new_stock<0 then raise exception 'El stock no puede ser negativo'; end if;

  select * into v_product
  from public.retail_products
  where id=p_product_id and restaurant_id=p_restaurant_id
  for update;
  if not found then raise exception 'Producto inválido'; end if;
  if not v_product.allow_fractional and p_new_stock<>trunc(p_new_stock) then
    raise exception 'El producto no admite cantidades fraccionadas';
  end if;

  v_delta:=p_new_stock-v_product.current_stock;
  update public.retail_products set current_stock=p_new_stock,updated_at=now() where id=p_product_id;
  insert into public.retail_stock_movements(
    restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
    reference_type,note,created_by
  ) values(
    p_restaurant_id,p_product_id,'adjustment',v_delta,p_new_stock,v_product.cost,
    'manual',nullif(btrim(coalesce(p_note,'')),''),auth.uid()
  );
  return jsonb_build_object('product_id',p_product_id,'old_stock',v_product.current_stock,'new_stock',p_new_stock,'delta',v_delta);
end;
$$;


--
-- Name: retail_business_type_valid(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_business_type_valid(p_restaurant_id bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists(
    select 1 from public.restaurants r
    where r.id=p_restaurant_id
      and r.active=true
      and r.business_type in ('supermarket','minimarket')
  );
$$;


--
-- Name: retail_cancel_online_order(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_cancel_online_order(p_order_id bigint, p_tracking_token uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_order public.retail_online_orders%rowtype;
  v_item public.retail_online_order_items%rowtype;
  v_stock numeric;
begin
  select * into v_order
  from public.retail_online_orders
  where id=p_order_id and tracking_token=p_tracking_token
  for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if v_order.status='cancelled' then return true; end if;
  if v_order.payment_status='approved' then raise exception 'Un pago aprobado debe ser devuelto por el negocio'; end if;
  if v_order.status not in ('pending_payment','received') then raise exception 'El pedido ya está en preparación y no puede cancelarse desde el cliente'; end if;

  for v_item in select * from public.retail_online_order_items where order_id=p_order_id order by id
  loop
    update public.retail_products
    set current_stock=current_stock+v_item.quantity,updated_at=now()
    where id=v_item.product_id and restaurant_id=v_order.restaurant_id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      v_order.restaurant_id,v_item.product_id,'online_release',v_item.quantity,v_stock,v_item.unit_cost,
      'online_order',p_order_id,'Cancelado por cliente',auth.uid()
    );
  end loop;

  update public.retail_online_orders
  set status='cancelled',payment_status='cancelled',reservation_expires_at=null,updated_at=now()
  where id=p_order_id;
  return true;
end;
$$;


--
-- Name: retail_complete_sale(bigint, bigint, text, numeric, numeric, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_complete_sale(p_restaurant_id bigint, p_cash_session_id bigint, p_payment_method text, p_discount numeric DEFAULT 0, p_amount_received numeric DEFAULT NULL::numeric, p_customer_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_sale_id bigint;
  v_sale_code text;
  v_item jsonb;
  v_product public.retail_products%rowtype;
  v_qty numeric;
  v_subtotal numeric:=0;
  v_discount numeric:=greatest(coalesce(p_discount,0),0);
  v_total numeric;
  v_change numeric:=0;
  v_line numeric;
  v_stock numeric;
  v_method text:=coalesce(nullif(btrim(p_payment_method),''),'Efectivo');
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not public.retail_business_type_valid(p_restaurant_id) then raise exception 'El negocio no está configurado como supermercado o minimarket'; end if;
  if not (public.is_site_admin() or public.has_restaurant_permission(p_restaurant_id,'cash')) then
    raise exception 'No autorizado';
  end if;
  if not exists(
    select 1 from public.restaurant_cash_sessions c
    where c.id=p_cash_session_id and c.restaurant_id=p_restaurant_id and c.status='open'
  ) then raise exception 'Debes tener una caja abierta para registrar la venta'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then
    raise exception 'Agrega al menos un producto';
  end if;

  -- Validate and lock all products before creating the sale.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Cantidad inválida'; end if;

    select * into v_product
    from public.retail_products
    where id=(v_item->>'product_id')::bigint and restaurant_id=p_restaurant_id
    for update;
    if not found or not v_product.active then raise exception 'Producto inválido o inactivo'; end if;
    if not v_product.allow_fractional and v_qty<>trunc(v_qty) then
      raise exception 'El producto % no admite cantidades fraccionadas', v_product.name;
    end if;
    if v_product.current_stock < v_qty then
      raise exception 'Stock insuficiente para % (disponible: %)', v_product.name, v_product.current_stock;
    end if;
    v_subtotal:=v_subtotal+round(v_qty*v_product.price,4);
  end loop;

  v_discount:=least(v_discount,v_subtotal);
  v_total:=round(v_subtotal-v_discount,4);
  if lower(v_method)='efectivo' and p_amount_received is not null then
    if p_amount_received < v_total then raise exception 'El monto recibido es menor al total'; end if;
    v_change:=round(p_amount_received-v_total,4);
  end if;

  insert into public.retail_sales(
    restaurant_id,cash_session_id,status,payment_method,subtotal,discount,total,
    amount_received,change_amount,customer_name,notes,created_by
  ) values(
    p_restaurant_id,p_cash_session_id,'completed',v_method,v_subtotal,v_discount,v_total,
    p_amount_received,v_change,nullif(btrim(coalesce(p_customer_name,'')),''),nullif(btrim(coalesce(p_notes,'')),''),auth.uid()
  ) returning id into v_sale_id;

  v_sale_code:='V-'||to_char(now(),'YYYYMMDD')||'-'||lpad(v_sale_id::text,6,'0');
  update public.retail_sales set sale_code=v_sale_code where id=v_sale_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    select * into v_product
    from public.retail_products
    where id=(v_item->>'product_id')::bigint and restaurant_id=p_restaurant_id
    for update;

    v_line:=round(v_qty*v_product.price,4);
    insert into public.retail_sale_items(
      sale_id,product_id,barcode_snapshot,name_snapshot,quantity,unit_price,unit_cost,line_total
    ) values(
      v_sale_id,v_product.id,v_product.barcode,v_product.name,v_qty,v_product.price,v_product.cost,v_line
    );

    update public.retail_products
    set current_stock=current_stock-v_qty,updated_at=now()
    where id=v_product.id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      p_restaurant_id,v_product.id,'sale',-v_qty,v_stock,v_product.cost,
      'sale',v_sale_id,p_notes,auth.uid()
    );
  end loop;

  insert into public.restaurant_cash_movements(
    restaurant_id,session_id,order_id,movement_type,payment_method,amount,description,created_by,retail_sale_id
  ) values(
    p_restaurant_id,p_cash_session_id,null,'sale',v_method,v_total,
    'Venta retail '||v_sale_code,auth.uid(),v_sale_id
  );

  return jsonb_build_object(
    'sale_id',v_sale_id,
    'sale_code',v_sale_code,
    'subtotal',v_subtotal,
    'discount',v_discount,
    'total',v_total,
    'change',v_change
  );
end;
$$;


--
-- Name: retail_create_online_order(bigint, text, text, text, text, text, double precision, double precision, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_create_online_order(p_restaurant_id bigint, p_customer_name text, p_customer_phone text DEFAULT ''::text, p_customer_email text DEFAULT NULL::text, p_order_type text DEFAULT 'Retiro'::text, p_delivery_address text DEFAULT NULL::text, p_delivery_latitude double precision DEFAULT NULL::double precision, p_delivery_longitude double precision DEFAULT NULL::double precision, p_payment_method text DEFAULT 'Efectivo'::text, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_r public.restaurants%rowtype;
  v_order_id bigint;
  v_order_code text;
  v_token uuid;
  v_item jsonb;
  v_product public.retail_products%rowtype;
  v_qty numeric;
  v_subtotal numeric:=0;
  v_delivery numeric:=0;
  v_total numeric;
  v_stock numeric;
  v_status text;
  v_payment_status text:='pending';
  v_expiry timestamptz;
  v_method text:=coalesce(nullif(btrim(p_payment_method),''),'Efectivo');
  v_type text:=case when lower(coalesce(p_order_type,''))='delivery' then 'Delivery' else 'Retiro' end;
  v_distance numeric;
  v_zone jsonb;
begin
  perform public.retail_release_expired_online_orders();

  select * into v_r
  from public.restaurants
  where id=p_restaurant_id
    and active=true
    and business_type in ('supermarket','minimarket')
    and subscription_status in ('trial','active')
    and (subscription_expires_at is null or subscription_expires_at>now())
  for share;
  if not found then raise exception 'La tienda no está disponible'; end if;
  if coalesce(btrim(p_customer_name),'')='' then raise exception 'Escribe tu nombre'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then
    raise exception 'Agrega productos al carrito';
  end if;

  if v_type='Delivery' then
    if coalesce(btrim(p_delivery_address),'')='' then raise exception 'Escribe la dirección de entrega'; end if;
    if v_r.delivery_pricing_mode='fixed' then
      v_delivery:=greatest(coalesce(v_r.delivery_fixed_price,0),0);
    elsif v_r.latitude is not null and v_r.longitude is not null
          and p_delivery_latitude is not null and p_delivery_longitude is not null then
      v_distance:=6371*2*asin(sqrt(
        power(sin(radians(p_delivery_latitude-v_r.latitude)/2),2)
        +cos(radians(v_r.latitude))*cos(radians(p_delivery_latitude))
        *power(sin(radians(p_delivery_longitude-v_r.longitude)/2),2)
      ));
      select z into v_zone
      from jsonb_array_elements(coalesce(v_r.delivery_zones,'[]'::jsonb)) z
      where (z->>'max_km')::numeric >= v_distance
      order by (z->>'max_km')::numeric
      limit 1;
      if v_zone is null then raise exception 'La dirección está fuera de la zona de delivery'; end if;
      v_delivery:=greatest(coalesce((v_zone->>'price')::numeric,0),0);
    else
      v_delivery:=greatest(coalesce(v_r.delivery_fixed_price,0),0);
    end if;
  end if;

  v_status:=case when lower(v_method)='mercado pago' then 'pending_payment' else 'received' end;
  v_expiry:=case when lower(v_method)='mercado pago' then now()+interval '30 minutes' else null end;

  insert into public.retail_online_orders(
    restaurant_id,customer_id,customer_name,customer_phone,customer_email,
    order_type,delivery_address,delivery_latitude,delivery_longitude,delivery_fee,
    subtotal,discount,total,currency_code,payment_method,payment_status,status,
    notes,reservation_expires_at
  ) values(
    p_restaurant_id,auth.uid(),btrim(p_customer_name),coalesce(btrim(p_customer_phone),''),
    nullif(btrim(coalesce(p_customer_email,'')),''),
    v_type,case when v_type='Delivery' then btrim(p_delivery_address) else null end,
    case when v_type='Delivery' then p_delivery_latitude else null end,
    case when v_type='Delivery' then p_delivery_longitude else null end,
    v_delivery,0,0,0,v_r.currency_code,v_method,v_payment_status,v_status,
    nullif(btrim(coalesce(p_notes,'')),''),v_expiry
  ) returning id,tracking_token into v_order_id,v_token;

  v_order_code:='WEB-'||to_char(now(),'YYMMDD')||'-'||lpad(v_order_id::text,6,'0');
  update public.retail_online_orders set order_code=v_order_code where id=v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Cantidad inválida'; end if;

    select * into v_product
    from public.retail_products
    where id=(v_item->>'product_id')::bigint
      and restaurant_id=p_restaurant_id
      and active=true
    for update;
    if not found then raise exception 'Uno de los productos ya no está disponible'; end if;
    if not v_product.allow_fractional and v_qty<>trunc(v_qty) then
      raise exception 'El producto % no admite cantidades fraccionadas',v_product.name;
    end if;
    if v_product.current_stock<v_qty then
      raise exception 'Stock insuficiente para %',v_product.name;
    end if;

    insert into public.retail_online_order_items(
      order_id,product_id,barcode_snapshot,name_snapshot,quantity,unit_price,unit_cost,line_total
    ) values(
      v_order_id,v_product.id,v_product.barcode,v_product.name,v_qty,v_product.price,v_product.cost,
      round(v_qty*v_product.price,4)
    );

    update public.retail_products
    set current_stock=current_stock-v_qty,updated_at=now()
    where id=v_product.id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      p_restaurant_id,v_product.id,'online_order',-v_qty,v_stock,v_product.cost,
      'online_order',v_order_id,'Reserva/venta tienda online',auth.uid()
    );

    v_subtotal:=v_subtotal+round(v_qty*v_product.price,4);
  end loop;

  v_total:=round(v_subtotal+v_delivery,4);
  update public.retail_online_orders
  set subtotal=v_subtotal,total=v_total,updated_at=now()
  where id=v_order_id;

  return jsonb_build_object(
    'order_id',v_order_id,
    'order_code',v_order_code,
    'tracking_token',v_token,
    'subtotal',v_subtotal,
    'delivery_fee',v_delivery,
    'total',v_total,
    'currency_code',v_r.currency_code,
    'payment_method',v_method,
    'payment_status',v_payment_status,
    'status',v_status,
    'reservation_expires_at',v_expiry
  );
end;
$$;


--
-- Name: retail_get_my_online_orders(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_get_my_online_orders(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_rows jsonb;
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  perform public.retail_release_expired_online_orders();

  select coalesce(jsonb_agg(row_data order by (row_data->>'created_at')::timestamptz desc),'[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id',o.id,'order_id',o.id,'order_code',o.order_code,'restaurant_id',o.restaurant_id,
      'status',o.status,'payment_status',o.payment_status,'payment_method',o.payment_method,
      'order_type',o.order_type,'delivery_address',o.delivery_address,
      'subtotal',o.subtotal,'delivery_fee',o.delivery_fee,'total',o.total,
      'currency_code',o.currency_code,'created_at',o.created_at,
      'reservation_expires_at',o.reservation_expires_at,'order_source','retail_online',
      'items',coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id',i.product_id,'name',i.name_snapshot,'qty',i.quantity,
          'unit_price',i.unit_price,'line_total',i.line_total
        ) order by i.id)
        from public.retail_online_order_items i where i.order_id=o.id
      ),'[]'::jsonb)
    ) row_data
    from public.retail_online_orders o
    where o.restaurant_id=p_restaurant_id and o.customer_id=auth.uid()
    order by o.created_at desc
    limit 50
  ) q;
  return v_rows;
end;
$$;


--
-- Name: retail_get_online_order_status(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_get_online_order_status(p_order_id bigint, p_tracking_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_order public.retail_online_orders%rowtype;
  v_items jsonb;
begin
  perform public.retail_release_expired_online_orders();
  select * into v_order
  from public.retail_online_orders
  where id=p_order_id and tracking_token=p_tracking_token;
  if not found then return null; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id',i.product_id,
    'name',i.name_snapshot,
    'qty',i.quantity,
    'unit_price',i.unit_price,
    'line_total',i.line_total
  ) order by i.id),'[]'::jsonb)
  into v_items
  from public.retail_online_order_items i
  where i.order_id=v_order.id;

  return jsonb_build_object(
    'id',v_order.id,
    'order_id',v_order.id,
    'order_code',v_order.order_code,
    'restaurant_id',v_order.restaurant_id,
    'status',v_order.status,
    'payment_status',v_order.payment_status,
    'payment_method',v_order.payment_method,
    'order_type',v_order.order_type,
    'delivery_address',v_order.delivery_address,
    'subtotal',v_order.subtotal,
    'delivery_fee',v_order.delivery_fee,
    'total',v_order.total,
    'currency_code',v_order.currency_code,
    'created_at',v_order.created_at,
    'reservation_expires_at',v_order.reservation_expires_at,
    'items',v_items,
    'order_source','retail_online'
  );
end;
$$;


--
-- Name: retail_mark_online_order_paid(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_mark_online_order_paid(p_restaurant_id bigint, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_order public.retail_online_orders%rowtype;
  v_method text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(p_restaurant_id,'cash')
    or public.has_restaurant_permission(p_restaurant_id,'inventory')
  ) then raise exception 'No autorizado'; end if;

  select * into v_order
  from public.retail_online_orders
  where id=p_order_id and restaurant_id=p_restaurant_id
  for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if v_order.status='cancelled' then raise exception 'El pedido está cancelado'; end if;
  if v_order.payment_status='approved' then
    return jsonb_build_object('order_id',v_order.id,'payment_status','approved','already_paid',true);
  end if;

  v_method:=lower(btrim(coalesce(v_order.payment_method,'')));
  if v_method in ('mercado pago','qr bolivia','veripagos','veripagos qr') then
    raise exception 'Este medio de pago se confirma automáticamente con el proveedor';
  end if;

  update public.retail_online_orders
  set payment_status='approved',paid_at=now(),updated_at=now()
  where id=p_order_id;

  return jsonb_build_object('order_id',p_order_id,'payment_status','approved');
end;
$$;


--
-- Name: retail_receive_purchase(bigint, bigint, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_receive_purchase(p_restaurant_id bigint, p_supplier_id bigint DEFAULT NULL::bigint, p_document_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_purchase_id bigint;
  v_item jsonb;
  v_product public.retail_products%rowtype;
  v_qty numeric;
  v_cost numeric;
  v_subtotal numeric:=0;
  v_stock numeric;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not public.retail_business_type_valid(p_restaurant_id) then raise exception 'El negocio no está configurado como supermercado o minimarket'; end if;
  if not (public.is_site_admin() or public.has_restaurant_permission(p_restaurant_id,'inventory')) then
    raise exception 'No autorizado';
  end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then
    raise exception 'Agrega al menos un producto';
  end if;
  if p_supplier_id is not null and not exists(
    select 1 from public.retail_suppliers s where s.id=p_supplier_id and s.restaurant_id=p_restaurant_id
  ) then raise exception 'Proveedor inválido'; end if;

  insert into public.retail_purchases(restaurant_id,supplier_id,document_number,status,notes,received_at,created_by)
  values(p_restaurant_id,p_supplier_id,nullif(btrim(coalesce(p_document_number,'')),''),'received',nullif(btrim(coalesce(p_notes,'')),''),now(),auth.uid())
  returning id into v_purchase_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    v_cost:=coalesce((v_item->>'unit_cost')::numeric,0);
    if v_qty<=0 or v_cost<0 then raise exception 'Cantidad o costo inválido'; end if;

    select * into v_product
    from public.retail_products
    where id=(v_item->>'product_id')::bigint and restaurant_id=p_restaurant_id
    for update;
    if not found then raise exception 'Producto inválido'; end if;
    if not v_product.allow_fractional and v_qty<>trunc(v_qty) then
      raise exception 'El producto % no admite cantidades fraccionadas', v_product.name;
    end if;

    insert into public.retail_purchase_items(purchase_id,product_id,quantity,unit_cost,line_total)
    values(v_purchase_id,v_product.id,v_qty,v_cost,round(v_qty*v_cost,4));

    update public.retail_products
    set current_stock=current_stock+v_qty,
        cost=v_cost,
        updated_at=now()
    where id=v_product.id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      p_restaurant_id,v_product.id,'purchase',v_qty,v_stock,v_cost,
      'purchase',v_purchase_id,p_notes,auth.uid()
    );

    v_subtotal:=v_subtotal+round(v_qty*v_cost,4);
  end loop;

  update public.retail_purchases
  set subtotal=v_subtotal,total=v_subtotal,updated_at=now()
  where id=v_purchase_id;

  return jsonb_build_object('purchase_id',v_purchase_id,'total',v_subtotal);
exception when others then
  raise;
end;
$$;


--
-- Name: retail_release_expired_online_orders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_release_expired_online_orders() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_id bigint;
  v_count integer:=0;
  v_item public.retail_online_order_items%rowtype;
  v_order public.retail_online_orders%rowtype;
  v_stock numeric;
begin
  for v_id in
    select id from public.retail_online_orders
    where status='pending_payment'
      and payment_status='pending'
      and reservation_expires_at is not null
      and reservation_expires_at < now()
    order by id
    for update skip locked
  loop
    select * into v_order from public.retail_online_orders where id=v_id;
    for v_item in select * from public.retail_online_order_items where order_id=v_id order by id
    loop
      update public.retail_products
      set current_stock=current_stock+v_item.quantity,updated_at=now()
      where id=v_item.product_id and restaurant_id=v_order.restaurant_id
      returning current_stock into v_stock;

      insert into public.retail_stock_movements(
        restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
        reference_type,reference_id,note,created_by
      ) values(
        v_order.restaurant_id,v_item.product_id,'online_release',v_item.quantity,v_stock,v_item.unit_cost,
        'online_order',v_id,'Reserva de pago online vencida',null
      );
    end loop;

    update public.retail_online_orders
    set status='cancelled',payment_status='cancelled',reservation_expires_at=null,updated_at=now()
    where id=v_id;
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;


--
-- Name: retail_release_online_order_internal(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_release_online_order_internal(p_order_id bigint, p_payment_status text DEFAULT 'cancelled'::text, p_reason text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_order public.retail_online_orders%rowtype;
  v_item public.retail_online_order_items%rowtype;
  v_stock numeric;
begin
  select * into v_order from public.retail_online_orders where id=p_order_id for update;
  if not found then return false; end if;
  if v_order.status='cancelled' then return true; end if;
  if v_order.status='delivered' then raise exception 'No se puede liberar un pedido entregado'; end if;

  for v_item in
    select * from public.retail_online_order_items where order_id=p_order_id order by id
  loop
    update public.retail_products
      set current_stock=current_stock+v_item.quantity,updated_at=now()
    where id=v_item.product_id and restaurant_id=v_order.restaurant_id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      v_order.restaurant_id,v_item.product_id,'online_release',v_item.quantity,v_stock,v_item.unit_cost,
      'online_order',p_order_id,coalesce(p_reason,'Pedido online cancelado/liberado'),null
    );
  end loop;

  update public.retail_online_orders
  set status='cancelled',
      payment_status=case when payment_status='approved' then payment_status else p_payment_status end,
      reservation_expires_at=null,
      updated_at=now()
  where id=p_order_id;
  return true;
end;
$$;


--
-- Name: retail_return_sale_items(bigint, bigint, bigint, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_return_sale_items(p_restaurant_id bigint, p_sale_id bigint, p_cash_session_id bigint, p_refund_method text DEFAULT 'Efectivo'::text, p_reason text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_sale public.retail_sales%rowtype;
  v_item jsonb;
  v_sale_item public.retail_sale_items%rowtype;
  v_product public.retail_products%rowtype;
  v_qty numeric;
  v_already numeric;
  v_gross numeric:=0;
  v_refund numeric;
  v_ratio numeric;
  v_remaining_refundable numeric;
  v_return_id bigint;
  v_stock numeric;
  v_line_refund numeric;
  v_method text:=coalesce(nullif(btrim(p_refund_method),''),'Efectivo');
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not public.retail_business_type_valid(p_restaurant_id) then
    raise exception 'El negocio no está configurado como supermercado o minimarket';
  end if;
  if not (public.is_site_admin() or public.has_restaurant_permission(p_restaurant_id,'cash')) then
    raise exception 'No autorizado';
  end if;

  select * into v_sale
  from public.retail_sales
  where id=p_sale_id and restaurant_id=p_restaurant_id
  for update;
  if not found then raise exception 'Venta no encontrada'; end if;
  if v_sale.refund_status='full' then raise exception 'La venta ya fue devuelta por completo'; end if;

  if not exists(
    select 1 from public.restaurant_cash_sessions c
    where c.id=p_cash_session_id and c.restaurant_id=p_restaurant_id and c.status='open'
  ) then raise exception 'Debes tener una caja abierta para registrar la devolución'; end if;

  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then
    raise exception 'Selecciona al menos un producto para devolver';
  end if;

  -- Validate return quantities first.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Cantidad de devolución inválida'; end if;

    select * into v_sale_item
    from public.retail_sale_items
    where id=(v_item->>'sale_item_id')::bigint and sale_id=p_sale_id;
    if not found then raise exception 'Producto de venta inválido'; end if;

    select coalesce(sum(ri.quantity),0) into v_already
    from public.retail_return_items ri
    join public.retail_returns rr on rr.id=ri.return_id
    where ri.sale_item_id=v_sale_item.id and rr.status='completed';

    if v_already+v_qty > v_sale_item.quantity then
      raise exception 'La cantidad a devolver supera la cantidad vendida de %', v_sale_item.name_snapshot;
    end if;

    v_gross:=v_gross + round(v_qty*v_sale_item.unit_price,4);
  end loop;

  if v_gross<=0 then raise exception 'El total a devolver debe ser mayor que cero'; end if;

  v_remaining_refundable:=greatest(v_sale.total-v_sale.refunded_amount,0);
  v_ratio:=case when v_sale.subtotal>0 then v_sale.total/v_sale.subtotal else 1 end;
  v_refund:=least(round(v_gross*v_ratio,4),v_remaining_refundable);
  if v_refund<=0 then raise exception 'La venta no tiene saldo reembolsable'; end if;

  insert into public.retail_returns(
    restaurant_id,sale_id,cash_session_id,refund_method,total,reason,status,created_by
  ) values(
    p_restaurant_id,p_sale_id,p_cash_session_id,v_method,v_refund,
    nullif(btrim(coalesce(p_reason,'')),''),'completed',auth.uid()
  ) returning id into v_return_id;

  -- Restore stock and record each returned line.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    select * into v_sale_item
    from public.retail_sale_items
    where id=(v_item->>'sale_item_id')::bigint and sale_id=p_sale_id;

    select * into v_product
    from public.retail_products
    where id=v_sale_item.product_id and restaurant_id=p_restaurant_id
    for update;
    if not found then raise exception 'Producto de inventario no encontrado'; end if;

    v_line_refund:=round(v_qty*v_sale_item.unit_price*v_ratio,4);

    insert into public.retail_return_items(
      return_id,sale_item_id,product_id,quantity,unit_refund,line_total
    ) values(
      v_return_id,v_sale_item.id,v_sale_item.product_id,v_qty,
      round(v_sale_item.unit_price*v_ratio,4),v_line_refund
    );

    update public.retail_products
    set current_stock=current_stock+v_qty,updated_at=now()
    where id=v_sale_item.product_id
    returning current_stock into v_stock;

    insert into public.retail_stock_movements(
      restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
      reference_type,reference_id,note,created_by
    ) values(
      p_restaurant_id,v_sale_item.product_id,'return',v_qty,v_stock,v_sale_item.unit_cost,
      'return',v_return_id,p_reason,auth.uid()
    );
  end loop;

  update public.retail_sales
  set refunded_amount=least(total,refunded_amount+v_refund),
      refund_status=case
        when refunded_amount+v_refund >= total-0.0001 then 'full'
        else 'partial'
      end,
      status=case
        when refunded_amount+v_refund >= total-0.0001 then 'voided'
        else status
      end,
      voided_at=case
        when refunded_amount+v_refund >= total-0.0001 then now()
        else voided_at
      end,
      voided_by=case
        when refunded_amount+v_refund >= total-0.0001 then auth.uid()
        else voided_by
      end
  where id=p_sale_id;

  insert into public.restaurant_cash_movements(
    restaurant_id,session_id,order_id,movement_type,payment_method,amount,
    description,created_by,retail_sale_id,retail_return_id
  ) values(
    p_restaurant_id,p_cash_session_id,null,'refund',v_method,-v_refund,
    'Devolución venta '||coalesce(v_sale.sale_code,p_sale_id::text),auth.uid(),p_sale_id,v_return_id
  );

  return jsonb_build_object(
    'return_id',v_return_id,
    'sale_id',p_sale_id,
    'refund_total',v_refund,
    'refund_status',case when v_sale.refunded_amount+v_refund >= v_sale.total-0.0001 then 'full' else 'partial' end
  );
end;
$$;


--
-- Name: retail_save_product(bigint, bigint, text, text, text, text, text, text, text, numeric, numeric, numeric, numeric, boolean, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_save_product(p_restaurant_id bigint, p_product_id bigint DEFAULT NULL::bigint, p_barcode text DEFAULT NULL::text, p_sku text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_description text DEFAULT ''::text, p_category text DEFAULT NULL::text, p_brand text DEFAULT NULL::text, p_unit text DEFAULT 'unidad'::text, p_cost numeric DEFAULT 0, p_price numeric DEFAULT 0, p_initial_stock numeric DEFAULT 0, p_minimum_stock numeric DEFAULT 0, p_allow_fractional boolean DEFAULT false, p_image_url text DEFAULT NULL::text, p_active boolean DEFAULT true) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_id bigint;
  v_stock numeric;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not public.retail_business_type_valid(p_restaurant_id) then
    raise exception 'El negocio no está configurado como supermercado o minimarket';
  end if;
  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(p_restaurant_id,'products')
    or public.has_restaurant_permission(p_restaurant_id,'inventory')
  ) then raise exception 'No autorizado'; end if;

  if coalesce(btrim(p_name),'')='' then raise exception 'El nombre es obligatorio'; end if;
  if coalesce(p_cost,0)<0 or coalesce(p_price,0)<0 or coalesce(p_minimum_stock,0)<0 then
    raise exception 'Costo, precio o stock mínimo inválido';
  end if;

  if p_product_id is null then
    if coalesce(p_initial_stock,0)<0 then raise exception 'El stock inicial no puede ser negativo'; end if;
    if not coalesce(p_allow_fractional,false) and coalesce(p_initial_stock,0)<>trunc(coalesce(p_initial_stock,0)) then
      raise exception 'Este producto no admite stock fraccionado';
    end if;

    insert into public.retail_products(
      restaurant_id,barcode,sku,name,description,category,brand,unit,cost,price,
      current_stock,minimum_stock,allow_fractional,image_url,active,created_by
    ) values(
      p_restaurant_id,
      nullif(btrim(coalesce(p_barcode,'')),''),
      nullif(btrim(coalesce(p_sku,'')),''),
      btrim(p_name),coalesce(p_description,''),
      nullif(btrim(coalesce(p_category,'')),''),
      nullif(btrim(coalesce(p_brand,'')),''),
      coalesce(nullif(btrim(coalesce(p_unit,'')),''),'unidad'),
      coalesce(p_cost,0),coalesce(p_price,0),coalesce(p_initial_stock,0),
      coalesce(p_minimum_stock,0),coalesce(p_allow_fractional,false),
      nullif(btrim(coalesce(p_image_url,'')),''),
      coalesce(p_active,true),auth.uid()
    ) returning id,current_stock into v_id,v_stock;

    if v_stock<>0 then
      insert into public.retail_stock_movements(
        restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
        reference_type,note,created_by
      ) values(
        p_restaurant_id,v_id,'initial',v_stock,v_stock,coalesce(p_cost,0),
        'product_create','Stock inicial',auth.uid()
      );
    end if;
  else
    update public.retail_products
    set barcode=nullif(btrim(coalesce(p_barcode,'')),''),
        sku=nullif(btrim(coalesce(p_sku,'')),''),
        name=btrim(p_name),
        description=coalesce(p_description,''),
        category=nullif(btrim(coalesce(p_category,'')),''),
        brand=nullif(btrim(coalesce(p_brand,'')),''),
        unit=coalesce(nullif(btrim(coalesce(p_unit,'')),''),'unidad'),
        cost=coalesce(p_cost,0),
        price=coalesce(p_price,0),
        minimum_stock=coalesce(p_minimum_stock,0),
        allow_fractional=coalesce(p_allow_fractional,false),
        image_url=nullif(btrim(coalesce(p_image_url,'')),''),
        active=coalesce(p_active,true),
        updated_at=now()
    where id=p_product_id and restaurant_id=p_restaurant_id
    returning id into v_id;
    if v_id is null then raise exception 'Producto no encontrado'; end if;
  end if;

  return v_id;
end;
$$;


--
-- Name: retail_update_online_order_status(bigint, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_update_online_order_status(p_restaurant_id bigint, p_order_id bigint, p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_order public.retail_online_orders%rowtype;
  v_item public.retail_online_order_items%rowtype;
  v_stock numeric;
  v_new text:=lower(btrim(coalesce(p_status,'')));
  v_cash bigint;
  v_method text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not (
    public.is_site_admin()
    or public.has_restaurant_permission(p_restaurant_id,'cash')
    or public.has_restaurant_permission(p_restaurant_id,'inventory')
  ) then raise exception 'No autorizado'; end if;
  if v_new not in ('received','preparing','ready','delivered','cancelled') then
    raise exception 'Estado inválido';
  end if;

  select * into v_order
  from public.retail_online_orders
  where id=p_order_id and restaurant_id=p_restaurant_id
  for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  v_method:=lower(btrim(coalesce(v_order.payment_method,'')));

  if v_new='cancelled' then
    if v_order.payment_status='approved' then
      raise exception 'El pedido tiene un pago aprobado. Gestiona primero el reembolso correspondiente.';
    end if;
    if v_order.status<>'cancelled' then
      for v_item in select * from public.retail_online_order_items where order_id=p_order_id order by id
      loop
        update public.retail_products
        set current_stock=current_stock+v_item.quantity,updated_at=now()
        where id=v_item.product_id and restaurant_id=p_restaurant_id
        returning current_stock into v_stock;
        insert into public.retail_stock_movements(
          restaurant_id,product_id,movement_type,quantity_delta,stock_after,unit_cost,
          reference_type,reference_id,note,created_by
        ) values(
          p_restaurant_id,v_item.product_id,'online_release',v_item.quantity,v_stock,v_item.unit_cost,
          'online_order',p_order_id,'Cancelado por el negocio',auth.uid()
        );
      end loop;
    end if;
    update public.retail_online_orders
    set status='cancelled',payment_status=case when payment_status='approved' then payment_status else 'cancelled' end,
        reservation_expires_at=null,updated_at=now()
    where id=p_order_id;
  else
    if v_order.status='cancelled' then raise exception 'No puedes reactivar un pedido cancelado'; end if;
    if v_order.status='pending_payment' and v_order.payment_status<>'approved' then
      raise exception 'El pago todavía no está aprobado';
    end if;

    if v_new='delivered' and v_method='efectivo' and v_order.cash_recorded_at is null then
      select id into v_cash
      from public.restaurant_cash_sessions
      where restaurant_id=p_restaurant_id and status='open'
      order by opened_at desc
      limit 1;
      if v_cash is null then raise exception 'Abre una caja antes de marcar como entregado un pedido pagado en efectivo'; end if;

      insert into public.restaurant_cash_movements(
        restaurant_id,session_id,order_id,movement_type,payment_method,amount,
        description,created_by,retail_online_order_id
      ) values(
        p_restaurant_id,v_cash,null,'sale','Efectivo',v_order.total,
        'Pedido online retail '||coalesce(v_order.order_code,p_order_id::text),auth.uid(),p_order_id
      );

      update public.retail_online_orders
      set cash_session_id=v_cash,cash_recorded_at=now(),
          payment_status='approved',paid_at=coalesce(paid_at,now())
      where id=p_order_id;
    elsif v_new='delivered'
          and v_order.payment_status<>'approved'
          and v_method not in ('mercado pago','qr bolivia','veripagos','veripagos qr') then
      update public.retail_online_orders
      set payment_status='approved',paid_at=coalesce(paid_at,now())
      where id=p_order_id;
    end if;

    update public.retail_online_orders
    set status=v_new,reservation_expires_at=null,updated_at=now()
    where id=p_order_id;
  end if;

  return jsonb_build_object('order_id',p_order_id,'status',v_new);
end;
$$;


--
-- Name: retail_void_sale(bigint, bigint, bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retail_void_sale(p_restaurant_id bigint, p_sale_id bigint, p_cash_session_id bigint, p_refund_method text DEFAULT 'Efectivo'::text, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_items jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;

  select jsonb_agg(
    jsonb_build_object(
      'sale_item_id',si.id,
      'quantity',greatest(
        si.quantity-coalesce((
          select sum(ri.quantity)
          from public.retail_return_items ri
          join public.retail_returns rr on rr.id=ri.return_id
          where ri.sale_item_id=si.id and rr.status='completed'
        ),0),
        0
      )
    )
  )
  into v_items
  from public.retail_sale_items si
  where si.sale_id=p_sale_id
    and si.quantity-coalesce((
      select sum(ri.quantity)
      from public.retail_return_items ri
      join public.retail_returns rr on rr.id=ri.return_id
      where ri.sale_item_id=si.id and rr.status='completed'
    ),0)>0;

  if v_items is null or jsonb_array_length(v_items)=0 then
    raise exception 'La venta ya no tiene productos pendientes de devolver';
  end if;

  return public.retail_return_sale_items(
    p_restaurant_id,p_sale_id,p_cash_session_id,p_refund_method,p_reason,v_items
  );
end;
$$;


--
-- Name: select_professional_appointment_payment_method(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.select_professional_appointment_payment_method(p_appointment_id bigint, p_method_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid:=auth.uid();
  v_restaurant_id bigint;
  v_method public.restaurant_payment_methods%rowtype;
begin
  if v_uid is null then raise exception 'Inicia sesión para seleccionar un método de pago'; end if;

  select restaurant_id into v_restaurant_id
  from public.professional_appointments
  where id=p_appointment_id
    and customer_id=v_uid
    and payment_status='pending'
    and status in ('pending','confirmed')
  for update;

  if v_restaurant_id is null then raise exception 'Reserva no disponible para pago'; end if;

  select * into v_method
  from public.restaurant_payment_methods
  where id=p_method_id
    and restaurant_id=v_restaurant_id
    and active;

  if v_method.id is null then raise exception 'Método de pago no disponible'; end if;

  update public.professional_appointments
  set payment_method=v_method.label,
      updated_at=now()
  where id=p_appointment_id and customer_id=v_uid;

  return jsonb_build_object(
    'id',v_method.id,
    'method_type',v_method.method_type,
    'label',v_method.label,
    'account_holder',v_method.account_holder,
    'account_identifier',v_method.account_identifier,
    'institution',v_method.institution,
    'qr_image_url',v_method.qr_image_url,
    'instructions',v_method.instructions,
    'requires_proof',v_method.requires_proof,
    'document_id',v_method.document_id,
    'account_type',v_method.account_type,
    'logo_url',v_method.logo_url
  );
end;
$$;


--
-- Name: select_professional_booking_payment_method(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.select_professional_booking_payment_method(p_intent_id bigint, p_method_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid:=auth.uid();
  v_i public.professional_booking_payment_intents%rowtype;
  v_method public.restaurant_payment_methods%rowtype;
begin
  select * into v_i
  from public.professional_booking_payment_intents
  where id=p_intent_id and customer_id=v_uid
  for update;

  if v_i.id is null then raise exception 'Pago pendiente no encontrado'; end if;
  if v_i.status not in ('pending','processing') or v_i.expires_at<=now() then
    raise exception 'El tiempo para pagar este horario venció';
  end if;

  select * into v_method
  from public.restaurant_payment_methods
  where id=p_method_id and restaurant_id=v_i.restaurant_id and active;
  if v_method.id is null then raise exception 'Método de pago no disponible'; end if;

  update public.professional_booking_payment_intents
  set payment_method_id=v_method.id,
      payment_method=v_method.label,
      status='processing',
      expires_at=greatest(expires_at,now()+interval '30 minutes'),
      updated_at=now()
  where id=v_i.id;

  return jsonb_build_object(
    'id',v_method.id,
    'method_type',v_method.method_type,
    'label',v_method.label,
    'account_holder',v_method.account_holder,
    'account_identifier',v_method.account_identifier,
    'institution',v_method.institution,
    'qr_image_url',v_method.qr_image_url,
    'instructions',v_method.instructions,
    'requires_proof',v_method.requires_proof,
    'document_id',v_method.document_id,
    'account_type',v_method.account_type,
    'logo_url',v_method.logo_url
  );
end;
$$;


--
-- Name: set_demo_business_api_inheritance(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_demo_business_api_inheritance(p_restaurant_id bigint, p_enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null or not public.is_site_admin() then
    raise exception 'Solo el administrador general puede cambiar APIs de demos';
  end if;

  if not exists(
    select 1 from public.restaurants
    where id=p_restaurant_id and is_demo
  ) then
    raise exception 'Este negocio no está marcado como demo';
  end if;

  update public.restaurants
  set use_demo_api_defaults=coalesce(p_enabled,false),
      updated_at=now()
  where id=p_restaurant_id;

  if coalesce(p_enabled,false) then
    perform public.sync_demo_business_api_defaults(p_restaurant_id);
  end if;

  return (
    select jsonb_build_object(
      'restaurant_id',id,
      'is_demo',is_demo,
      'use_demo_api_defaults',use_demo_api_defaults,
      'demo_api_synced_at',demo_api_synced_at
    )
    from public.restaurants
    where id=p_restaurant_id
  );
end;
$$;


--
-- Name: streaming_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_orders (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    customer_user_id uuid NOT NULL,
    order_code text,
    buyer_name text DEFAULT ''::text NOT NULL,
    buyer_phone text DEFAULT ''::text NOT NULL,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric DEFAULT 0 NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    status text DEFAULT 'pending_payment'::text NOT NULL,
    payment_status text DEFAULT 'pending'::text NOT NULL,
    payment_method text DEFAULT 'Mercado Pago'::text NOT NULL,
    mp_preference_id text,
    mp_payment_id text,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    mp_credential_source text,
    CONSTRAINT streaming_orders_mp_credential_source_check CHECK (((mp_credential_source IS NULL) OR (mp_credential_source = ANY (ARRAY['admin'::text, 'business'::text])))),
    CONSTRAINT streaming_orders_payment_status_check CHECK ((payment_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text, 'refunded'::text]))),
    CONSTRAINT streaming_orders_status_check CHECK ((status = ANY (ARRAY['pending_payment'::text, 'processing'::text, 'ready'::text, 'delivered'::text, 'cancelled'::text, 'payment_failed'::text]))),
    CONSTRAINT streaming_orders_total_check CHECK ((total >= (0)::numeric))
);


--
-- Name: streaming_create_order(bigint, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_create_order(p_restaurant_id bigint, p_items jsonb, p_customer_name text DEFAULT ''::text, p_customer_phone text DEFAULT ''::text) RETURNS public.streaming_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_account_type text;
  v_restaurant public.restaurants%rowtype;
  v_item jsonb;
  v_platform public.streaming_platforms%rowtype;
  v_platform_id bigint;
  v_qty integer;
  v_free integer;
  v_pending integer;
  v_total numeric := 0;
  v_normalized jsonb := '[]'::jsonb;
  v_order public.streaming_orders%rowtype;
  v_catalog jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesión para comprar'; end if;

  select account_type into v_account_type
  from public.user_profiles where user_id = v_uid;

  if coalesce(v_account_type,'customer') <> 'customer'
     and not public.has_admin_client_preview(p_restaurant_id) then
    raise exception 'Esta cuenta no corresponde a un cliente';
  end if;

  select * into v_restaurant
  from public.restaurants
  where id = p_restaurant_id
    and business_type = 'streaming'
    and active is distinct from false
    and coalesce(subscription_status,'trial') in ('trial','active')
    and (subscription_expires_at is null or subscription_expires_at > now());
  if not found then raise exception 'Negocio Streaming no disponible'; end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío';
  end if;

  v_catalog := public.streaming_public_catalog(p_restaurant_id);

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_platform_id := nullif(v_item->>'platform_id','')::bigint;
    v_qty := greatest(1, least(10, coalesce(nullif(v_item->>'qty','')::integer,1)));

    select * into v_platform
    from public.streaming_platforms
    where id=v_platform_id and restaurant_id=p_restaurant_id and active is distinct from false;
    if not found then raise exception 'Una plataforma del carrito ya no está disponible'; end if;
    if coalesce(v_platform.sale_price,0) <= 0 then raise exception 'Una plataforma no tiene precio de venta configurado'; end if;

    select coalesce((x->>'free_slots')::integer,0) into v_free
    from jsonb_array_elements(coalesce(v_catalog->'products','[]'::jsonb)) x
    where (x->>'id')::bigint = v_platform_id
    limit 1;
    v_free := coalesce(v_free,0);

    select coalesce(sum(greatest(1,coalesce(nullif(i->>'qty','')::integer,1))),0)::integer
      into v_pending
    from public.streaming_orders o
    cross join lateral jsonb_array_elements(o.items) i
    where o.restaurant_id=p_restaurant_id
      and o.status='pending_payment'
      and o.payment_status='pending'
      and o.created_at > now() - interval '30 minutes'
      and (i->>'platform_id')::bigint = v_platform_id;

    if v_qty > greatest(0, v_free - coalesce(v_pending,0)) then
      raise exception 'No quedan cupos suficientes para %', v_platform.name;
    end if;

    v_total := v_total + (v_platform.sale_price * v_qty);
    v_normalized := v_normalized || jsonb_build_array(jsonb_build_object(
      'platform_id',v_platform.id,
      'name',v_platform.name,
      'qty',v_qty,
      'unit_price',v_platform.sale_price,
      'duration_days',v_platform.default_duration_days
    ));
  end loop;

  insert into public.streaming_orders(
    restaurant_id,customer_user_id,buyer_name,buyer_phone,items,total,currency_code
  ) values (
    p_restaurant_id,v_uid,trim(coalesce(p_customer_name,'')),trim(coalesce(p_customer_phone,'')),
    v_normalized,v_total,coalesce(v_restaurant.currency_code,'CLP')
  ) returning * into v_order;

  update public.streaming_orders
  set order_code='STR-'||lpad(v_order.id::text,6,'0')
  where id=v_order.id
  returning * into v_order;

  return v_order;
end;
$$;


--
-- Name: streaming_finalize_paid_order(bigint, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_finalize_paid_order(p_order_id bigint, p_mp_payment_id text, p_paid_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.streaming_orders%rowtype;
  v_customer_id bigint;
  v_profile public.customer_profiles%rowtype;
  v_email text;
  v_item jsonb;
  v_i integer;
  v_qty integer;
  v_platform_id bigint;
  v_duration integer;
  v_unit_price numeric;
begin
  select * into v_order from public.streaming_orders where id=p_order_id for update;
  if not found then raise exception 'Pedido Streaming no encontrado'; end if;
  if v_order.payment_status='approved' then return; end if;

  select * into v_profile from public.customer_profiles where user_id=v_order.customer_user_id;
  select email into v_email from public.user_profiles where user_id=v_order.customer_user_id;

  select id into v_customer_id
  from public.streaming_customers
  where restaurant_id=v_order.restaurant_id and created_by=v_order.customer_user_id
  order by id limit 1;

  if v_customer_id is null then
    insert into public.streaming_customers(
      restaurant_id,full_name,phone,email,notes,active,created_by
    ) values (
      v_order.restaurant_id,
      coalesce(nullif(v_order.buyer_name,''),nullif(v_profile.full_name,''),'Cliente online'),
      coalesce(nullif(v_order.buyer_phone,''),v_profile.phone,''),
      nullif(v_email,''),
      'Cliente creado desde compra online '||coalesce(v_order.order_code,''),
      true,
      v_order.customer_user_id
    ) returning id into v_customer_id;
  end if;

  update public.streaming_orders
  set payment_status='approved',status='processing',mp_payment_id=p_mp_payment_id,
      paid_at=coalesce(p_paid_at,now()),updated_at=now()
  where id=v_order.id;

  for v_item in select value from jsonb_array_elements(v_order.items)
  loop
    v_qty := greatest(1,coalesce((v_item->>'qty')::integer,1));
    v_platform_id := (v_item->>'platform_id')::bigint;
    v_duration := greatest(1,coalesce((v_item->>'duration_days')::integer,30));
    v_unit_price := greatest(0,coalesce((v_item->>'unit_price')::numeric,0));
    for v_i in 1..v_qty loop
      insert into public.streaming_subscriptions(
        restaurant_id,customer_id,platform_id,account_id,profile_label,
        starts_at,expires_at,status,price,currency_code,auto_renew,notes,
        payment_status,paid_amount,payment_method,paid_at,delivery_status,order_id
      ) values (
        v_order.restaurant_id,v_customer_id,v_platform_id,null,'',
        coalesce(v_order.paid_at,now()),coalesce(v_order.paid_at,now()) + make_interval(days=>v_duration),
        'active',v_unit_price,v_order.currency_code,false,
        'Compra online '||coalesce(v_order.order_code,''),
        'paid',v_unit_price,'Mercado Pago',coalesce(v_order.paid_at,now()),'pending',v_order.id
      );
    end loop;
  end loop;
end;
$$;


--
-- Name: streaming_public_catalog(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_public_catalog(p_restaurant_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select jsonb_build_object(
    'business',
      jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'is_demo', coalesce(r.is_demo,false),
        'effective_demo', coalesce(r.is_demo,false) and not coalesce(o.enabled,false),
        'logo_url', r.logo_url,
        'whatsapp', r.whatsapp,
        'currency_code', coalesce(r.currency_code,'CLP'),
        'locale', coalesce(r.locale,'es-CL'),
        'country_code', coalesce(r.country_code,'CL'),
        'theme_primary_color', r.theme_primary_color,
        'theme_secondary_color', r.theme_secondary_color,
        'accept_mercadopago', coalesce(r.accept_mercadopago,true),
        'payment_online_ready',
          coalesce(r.accept_mercadopago,true)
          and nullif(trim(coalesce(r.mercadopago_public_key,'')),'') is not null
          and exists (
            select 1 from public.restaurant_payment_connections pc
            where pc.restaurant_id=r.id
              and nullif(trim(coalesce(pc.access_token,'')),'') is not null
          )
      ),
    'products',
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'name', p.name,
            'default_duration_days', p.default_duration_days,
            'sale_price', p.sale_price,
            'free_slots', greatest(
              coalesce((
                select sum(
                  greatest(
                    coalesce(a.max_slots,1)::bigint -
                    (
                      select count(*)
                      from public.streaming_subscriptions s
                      where s.restaurant_id = r.id
                        and s.account_id = a.id
                        and s.status = 'active'
                        and coalesce(s.starts_at, now()) <= now()
                        and s.expires_at > now()
                    ),
                    0
                  )
                )
                from public.streaming_accounts a
                where a.restaurant_id = r.id
                  and a.platform_id = p.id
                  and a.active is distinct from false
              ),0)
              -
              coalesce((
                select sum(greatest(1,coalesce(nullif(i->>'qty','')::integer,1)))
                from public.streaming_orders so
                cross join lateral jsonb_array_elements(so.items) i
                where so.restaurant_id=r.id
                  and so.status='pending_payment'
                  and so.payment_status='pending'
                  and so.created_at > now() - interval '30 minutes'
                  and (i->>'platform_id')::bigint=p.id
              ),0),
              0
            )
          )
          order by p.sort_order nulls last, p.name
        )
        from public.streaming_platforms p
        where p.restaurant_id = r.id
          and p.active is distinct from false
      ), '[]'::jsonb)
  )
  from public.restaurants r
  left join public.business_payment_test_overrides o on o.restaurant_id=r.id
  where r.id = p_restaurant_id
    and r.business_type = 'streaming'
    and r.active is distinct from false
    and coalesce(r.subscription_status,'trial') in ('trial','active')
    and (r.subscription_expires_at is null or r.subscription_expires_at > now());
$$;


--
-- Name: streaming_public_catalog(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_public_catalog(p_ref text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_business public.restaurants%rowtype;
  v_items jsonb;
begin
  select r.*
    into v_business
  from public.restaurants r
  where r.active = true
    and r.business_type = 'streaming'
    and (
      r.slug = nullif(btrim(coalesce(p_ref,'')),'')
      or r.id::text = nullif(btrim(coalesce(p_ref,'')),'')
    )
  limit 1;

  if v_business.id is null then
    return jsonb_build_object('ok',false,'error','not_found');
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'duration_days', p.default_duration_days,
      'price', p.sale_price,
      'available_slots', coalesce(cap.available_slots,0),
      'active', p.active
    )
    order by p.sort_order asc, p.name asc
  ), '[]'::jsonb)
  into v_items
  from public.streaming_platforms p
  left join lateral (
    select greatest(
      coalesce(sum(a.max_slots),0)
      - coalesce(count(s.id) filter (
          where coalesce(s.status,'active') not in ('cancelled','paused')
            and (s.expires_at is null or s.expires_at > now())
        ),0),
      0
    )::int as available_slots
    from public.streaming_accounts a
    left join public.streaming_subscriptions s
      on s.account_id = a.id
     and s.restaurant_id = a.restaurant_id
    where a.restaurant_id = v_business.id
      and a.platform_id = p.id
      and a.active = true
  ) cap on true
  where p.restaurant_id = v_business.id
    and p.active = true;

  return jsonb_build_object(
    'ok',true,
    'business',jsonb_build_object(
      'id',v_business.id,
      'name',v_business.name,
      'slug',v_business.slug,
      'whatsapp',coalesce(v_business.whatsapp,''),
      'currency_code',coalesce(v_business.currency_code,'CLP'),
      'locale',coalesce(v_business.locale,'es-CL'),
      'country_code',coalesce(v_business.country_code,'CL')
    ),
    'items',v_items
  );
end
$$;


--
-- Name: streaming_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_subscriptions (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    platform_id bigint NOT NULL,
    account_id bigint,
    profile_label text DEFAULT ''::text NOT NULL,
    starts_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    price numeric DEFAULT 0 NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    auto_renew boolean DEFAULT false NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    payment_status text DEFAULT 'pending'::text NOT NULL,
    paid_amount numeric DEFAULT 0 NOT NULL,
    payment_method text DEFAULT ''::text NOT NULL,
    paid_at timestamp with time zone,
    delivery_status text DEFAULT 'pending'::text NOT NULL,
    delivered_at timestamp with time zone,
    order_id bigint,
    CONSTRAINT streaming_subscriptions_check CHECK ((expires_at > starts_at)),
    CONSTRAINT streaming_subscriptions_currency_code_check CHECK ((currency_code ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT streaming_subscriptions_delivery_status_check CHECK ((delivery_status = ANY (ARRAY['pending'::text, 'delivered'::text]))),
    CONSTRAINT streaming_subscriptions_payment_status_check CHECK ((payment_status = ANY (ARRAY['pending'::text, 'paid'::text]))),
    CONSTRAINT streaming_subscriptions_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT streaming_subscriptions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'paused'::text, 'expired'::text, 'cancelled'::text])))
);


--
-- Name: streaming_renew_subscription(bigint, integer, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_renew_subscription(p_subscription_id bigint, p_days integer, p_amount numeric DEFAULT 0, p_payment_method text DEFAULT ''::text, p_notes text DEFAULT ''::text) RETURNS public.streaming_subscriptions
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_sub public.streaming_subscriptions;
  v_previous timestamptz;
  v_new timestamptz;
begin
  if p_days is null or p_days < 1 or p_days > 3650 then
    raise exception 'La duración de renovación debe estar entre 1 y 3650 días';
  end if;
  if coalesce(p_amount,0) < 0 then
    raise exception 'El monto no puede ser negativo';
  end if;

  select * into v_sub
  from public.streaming_subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception 'Suscripción no encontrada';
  end if;

  v_previous := greatest(v_sub.expires_at, now());
  v_new := v_previous + make_interval(days => p_days);

  insert into public.streaming_renewals(
    restaurant_id, subscription_id, previous_expires_at, new_expires_at,
    amount, currency_code, payment_method, notes
  ) values (
    v_sub.restaurant_id, v_sub.id, v_previous, v_new,
    coalesce(p_amount,0), v_sub.currency_code, coalesce(p_payment_method,''), coalesce(p_notes,'')
  );

  update public.streaming_subscriptions
  set expires_at = v_new,
      status = 'active',
      payment_status = case when coalesce(p_amount,0) > 0 then 'paid' else 'pending' end,
      paid_amount = coalesce(p_amount,0),
      payment_method = coalesce(p_payment_method,''),
      paid_at = case when coalesce(p_amount,0) > 0 then now() else null end,
      updated_at = now()
  where id = v_sub.id
  returning * into v_sub;

  return v_sub;
end;
$$;


--
-- Name: streaming_sync_order_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_sync_order_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_total integer;
  v_delivered integer;
  v_assigned integer;
begin
  if new.order_id is null then return new; end if;
  select count(*),
         count(*) filter (where delivery_status='delivered'),
         count(*) filter (where account_id is not null)
  into v_total,v_delivered,v_assigned
  from public.streaming_subscriptions
  where order_id=new.order_id and status <> 'cancelled';

  update public.streaming_orders
  set status=case
    when v_total>0 and v_delivered=v_total then 'delivered'
    when v_total>0 and v_assigned=v_total then 'ready'
    else 'processing'
  end,
  updated_at=now()
  where id=new.order_id and payment_status='approved';

  return new;
end;
$$;


--
-- Name: streaming_validate_subscription_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_validate_subscription_assignment() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_account public.streaming_accounts;
  v_overlap_count integer;
begin
  if new.account_id is null then
    return new;
  end if;

  select * into v_account
  from public.streaming_accounts
  where id = new.account_id and restaurant_id = new.restaurant_id;

  if not found then
    raise exception 'La cuenta seleccionada no pertenece a este negocio';
  end if;
  if v_account.platform_id <> new.platform_id then
    raise exception 'La cuenta seleccionada pertenece a otra plataforma';
  end if;
  if not v_account.active then
    raise exception 'La cuenta seleccionada está desactivada';
  end if;

  if new.status = 'active' then
    select count(*) into v_overlap_count
    from public.streaming_subscriptions s
    where s.account_id = new.account_id
      and s.restaurant_id = new.restaurant_id
      and s.status = 'active'
      and s.id is distinct from new.id
      and tstzrange(s.starts_at,s.expires_at,'[)') && tstzrange(new.starts_at,new.expires_at,'[)');

    if v_overlap_count >= v_account.max_slots then
      raise exception 'No quedan cupos disponibles en esta cuenta para ese periodo';
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: streaming_verify_cron_token(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.streaming_verify_cron_token(p_token text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists(
    select 1
    from vault.decrypted_secrets s
    where s.name='streaming_reminder_cron_token'
      and s.decrypted_secret=p_token
  );
$$;


--
-- Name: submit_issue_report(text, text, text, bigint, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_issue_report(p_app_context text, p_title text, p_description text, p_restaurant_id bigint DEFAULT NULL::bigint, p_route text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id bigint;
begin
  if p_app_context not in ('restaurant','client') then raise exception 'Contexto inválido'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_description),'')='' then raise exception 'Completa título y descripción'; end if;
  insert into public.user_issue_reports(app_context,restaurant_id,user_id,title,description,route,metadata)
  values(
    p_app_context,p_restaurant_id,auth.uid(),
    left(trim(p_title),160),left(trim(p_description),2500),
    nullif(left(coalesce(trim(p_route),''),300),''),
    coalesce(p_metadata,'{}'::jsonb)
  )
  returning id into v_id;
  return v_id;
end
$$;


--
-- Name: sync_account_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_account_identity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_requested text := lower(trim(coalesce(new.raw_user_meta_data->>'account_type','')));
  v_type text;
begin
  if lower(coalesce(new.email,''))='scuentas150@gmail.com' then
    v_type := 'admin';
  elsif v_requested='restaurant' then
    v_type := 'restaurant';
  else
    v_type := 'customer';
  end if;

  insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
  values(new.id,coalesce(new.email,''),v_type,now(),now())
  on conflict(user_id) do update
    set email=excluded.email,
        account_type=excluded.account_type,
        updated_at=now();

  if v_type='customer' then
    insert into public.customer_profiles(user_id,full_name,phone)
    values(
      new.id,
      coalesce(new.raw_user_meta_data->>'full_name',''),
      nullif(new.raw_user_meta_data->>'phone','')
    )
    on conflict(user_id) do update set
      full_name=excluded.full_name,
      phone=coalesce(excluded.phone,public.customer_profiles.phone),
      updated_at=now();
  end if;

  return new;
end;
$$;


--
-- Name: sync_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 insert into public.user_profiles(user_id,email,account_type)
 values(new.id,coalesce(new.email,''),'customer')
 on conflict(user_id) do nothing;
 return new;
end $$;


--
-- Name: sync_admin_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_admin_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid;
  v_email text;
begin
  if tg_op='DELETE' then
    v_uid:=old.user_id;
    select coalesce(u.email,'') into v_email from auth.users u where u.id=v_uid;
    if exists(select 1 from public.restaurant_staff s where s.user_id=v_uid and s.active) then
      insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
      values(v_uid,coalesce(v_email,''),'restaurant',now(),now())
      on conflict(user_id) do update set account_type='restaurant',email=excluded.email,updated_at=now();
    else
      insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
      values(v_uid,coalesce(v_email,''),'customer',now(),now())
      on conflict(user_id) do update set account_type='customer',email=excluded.email,updated_at=now();
      insert into public.customer_profiles(user_id,full_name)
      values(v_uid,'')
      on conflict(user_id) do nothing;
    end if;
    return old;
  end if;

  v_uid:=new.user_id;
  insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
  values(v_uid,coalesce(new.email,''),'admin',now(),now())
  on conflict(user_id) do update set account_type='admin',email=excluded.email,updated_at=now();

  delete from public.customer_profiles where user_id=v_uid;
  return new;
end;
$$;


--
-- Name: sync_demo_api_defaults_after_global_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_demo_api_defaults_after_global_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public.sync_demo_business_api_defaults(null);
  return new;
end;
$$;


--
-- Name: sync_demo_api_defaults_on_business_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_demo_api_defaults_on_business_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.is_demo and new.use_demo_api_defaults then
    perform public.sync_demo_business_api_defaults(new.id);
  end if;
  return new;
end;
$$;


--
-- Name: sync_demo_business_api_defaults(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_demo_business_api_defaults(p_restaurant_id bigint DEFAULT NULL::bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_settings public.subscription_payment_settings%rowtype;
  v_count integer:=0;
begin
  select * into v_settings
  from public.subscription_payment_settings
  order by id
  limit 1;

  if v_settings.id is null then return 0; end if;

  update public.restaurants r
  set demo_api_synced_at=now(),
      updated_at=now()
  where r.is_demo
    and r.use_demo_api_defaults
    and (p_restaurant_id is null or r.id=p_restaurant_id);

  insert into public.restaurant_veripagos_connections(
    restaurant_id,basic_username,basic_password,secret_key,enabled,vigencia,updated_at
  )
  select r.id,
         v_settings.veripagos_basic_username,
         v_settings.veripagos_basic_password,
         v_settings.veripagos_secret_key,
         coalesce(v_settings.veripagos_enabled,false),
         coalesce(nullif(v_settings.veripagos_vigencia,''),'0/00:15'),
         now()
  from public.restaurants r
  where r.is_demo
    and r.use_demo_api_defaults
    and r.country_code='BO'
    and nullif(v_settings.veripagos_basic_username,'') is not null
    and nullif(v_settings.veripagos_basic_password,'') is not null
    and nullif(v_settings.veripagos_secret_key,'') is not null
    and (p_restaurant_id is null or r.id=p_restaurant_id)
  on conflict (restaurant_id) do update
  set basic_username=excluded.basic_username,
      basic_password=excluded.basic_password,
      secret_key=excluded.secret_key,
      enabled=excluded.enabled,
      vigencia=excluded.vigencia,
      updated_at=now();

  select count(*) into v_count
  from public.restaurants r
  where r.is_demo
    and r.use_demo_api_defaults
    and (p_restaurant_id is null or r.id=p_restaurant_id);

  return v_count;
end;
$$;


--
-- Name: sync_staff_account_type(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_staff_account_type() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid;
  v_email text;
begin
  v_uid:=case when tg_op='DELETE' then old.user_id else new.user_id end;
  select coalesce(u.email,'') into v_email from auth.users u where u.id=v_uid;

  if exists(select 1 from public.admin_users a where a.user_id=v_uid) then
    insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
    values(v_uid,coalesce(v_email,''),'admin',now(),now())
    on conflict(user_id) do update set account_type='admin',email=excluded.email,updated_at=now();
    delete from public.customer_profiles where user_id=v_uid;
    return case when tg_op='DELETE' then old else new end;
  end if;

  if tg_op<>'DELETE' or exists(select 1 from public.restaurant_staff s where s.user_id=v_uid and s.active) then
    insert into public.user_profiles(user_id,email,account_type,created_at,updated_at)
    values(v_uid,coalesce(v_email,''),'restaurant',now(),now())
    on conflict(user_id) do update set account_type='restaurant',email=excluded.email,updated_at=now();
    delete from public.customer_profiles where user_id=v_uid;
  end if;

  return case when tg_op='DELETE' then old else new end;
end;
$$;


--
-- Name: update_waiter_order(bigint, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_waiter_order(p_order_id bigint, p_customer_name text, p_table_reference text, p_notes text, p_items jsonb) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
  v_item jsonb;
  v_old_item jsonb;
  v_product public.restaurant_products%rowtype;
  v_qty integer;
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_table_name text;
  v_old_pid bigint;
  v_old_qty integer;
  v_new_qty integer;
  v_delta integer;
  v_ingredient record;
begin
  select * into v_order
  from public.restaurant_orders
  where id=p_order_id
  for update;

  if not found or v_order.order_source not in ('waiter','table_qr') then
    raise exception 'Pedido no encontrado';
  end if;

  if not public.has_restaurant_permission(v_order.restaurant_id,'pos') then
    raise exception 'No autorizado para editar este pedido';
  end if;

  if not public.is_site_admin()
     and v_order.created_by is distinct from auth.uid() then
    raise exception 'Solo puedes editar los pedidos que tú creaste o retiraste';
  end if;

  if v_order.order_source='table_qr'
     and lower(trim(coalesce(v_order.payment_method,'')))='mercado pago'
     and lower(trim(coalesce(v_order.payment_status,'')))='approved' then
    raise exception 'Los pedidos QR pagados en línea no se editan desde pedidos normales';
  end if;

  if v_order.payment_status = 'approved' then
    raise exception 'Un pedido pagado no se puede editar';
  end if;

  if v_order.status = 'cancelado' then
    raise exception 'Un pedido cancelado no se puede editar';
  end if;

  if v_order.status = 'listo' then
    raise exception 'Primero retira el pedido de cocina; después podrás agregar productos antes de cobrar';
  end if;

  if nullif(trim(p_customer_name),'') is null then
    raise exception 'El nombre del cliente es obligatorio';
  end if;

  if nullif(trim(coalesce(p_table_reference,'')),'') is null then
    if nullif(trim(coalesce(v_order.table_reference,'')),'') is null then
      v_table_name := null;
    else
      raise exception 'Selecciona una mesa';
    end if;
  elsif lower(trim(p_table_reference)) = lower(trim(coalesce(v_order.table_reference,''))) then
    v_table_name := v_order.table_reference;
  else
    select t.name into v_table_name
    from public.restaurant_tables t
    where t.restaurant_id=v_order.restaurant_id
      and t.active=true
      and lower(trim(t.name))=lower(trim(p_table_reference))
    order by t.sort_order,t.id
    limit 1;

    if v_table_name is null then
      raise exception 'La mesa seleccionada no existe o está desactivada';
    end if;
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Agrega al menos un producto';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := greatest(1,least(99,coalesce((v_item->>'qty')::integer,1)));
    select * into v_product
    from public.restaurant_products
    where id=(v_item->>'product_id')::bigint
      and restaurant_id=v_order.restaurant_id
      and available=true;

    if not found then
      raise exception 'Producto no disponible';
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,
      'name',v_product.name,
      'qty',v_qty,
      'unit_price',v_product.price,
      'note',coalesce(v_item->>'note','')
    ));
    v_total := v_total + (v_product.price*v_qty);
  end loop;

  if v_order.status in ('entregado','retirado_mesa') then
    for v_old_item in
      select value from jsonb_array_elements(coalesce(v_order.items,'[]'::jsonb))
    loop
      v_old_pid := nullif(v_old_item->>'product_id','')::bigint;
      v_old_qty := greatest(1,coalesce(nullif(v_old_item->>'qty','')::integer,1));
      if v_old_pid is not null then
        select coalesce(sum(greatest(1,coalesce(nullif(x->>'qty','')::integer,1))),0)::integer
          into v_new_qty
        from jsonb_array_elements(v_items) x
        where nullif(x->>'product_id','')::bigint=v_old_pid;

        if v_new_qty < v_old_qty then
          raise exception 'Después de retirar el pedido solo puedes agregar productos o aumentar cantidades; no quitar lo ya entregado';
        end if;
      end if;
    end loop;

    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_old_pid := nullif(v_item->>'product_id','')::bigint;
      v_new_qty := greatest(1,coalesce(nullif(v_item->>'qty','')::integer,1));

      select coalesce(sum(greatest(1,coalesce(nullif(x->>'qty','')::integer,1))),0)::integer
        into v_old_qty
      from jsonb_array_elements(coalesce(v_order.items,'[]'::jsonb)) x
      where nullif(x->>'product_id','')::bigint=v_old_pid;

      v_delta := greatest(v_new_qty-v_old_qty,0);
      if v_delta>0 then
        for v_ingredient in
          select inventory_item_id,quantity_per_unit
          from public.restaurant_product_ingredients
          where restaurant_id=v_order.restaurant_id
            and product_id=v_old_pid
        loop
          insert into public.restaurant_inventory_movements(
            restaurant_id,inventory_item_id,movement_type,quantity_delta,note,created_by
          ) values (
            v_order.restaurant_id,
            v_ingredient.inventory_item_id,
            'consumo',
            -(v_ingredient.quantity_per_unit*v_delta),
            'Adición posterior · Pedido '||v_order.order_code,
            auth.uid()
          );
        end loop;
      end if;
    end loop;
  end if;

  update public.restaurant_orders set
    customer_name=trim(p_customer_name),
    table_reference=v_table_name,
    notes=nullif(trim(coalesce(p_notes,'')),''),
    items=v_items,
    total=v_total,
    updated_at=now()
  where id=p_order_id
  returning * into v_order;

  return v_order;
end
$$;


--
-- Name: withdraw_table_qr_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.withdraw_table_qr_order(p_order_id bigint) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
begin
  select * into v_order
  from public.restaurant_orders
  where id=p_order_id
  for update;

  if not found or v_order.order_source<>'table_qr' or v_order.order_type<>'Mesa' then
    raise exception 'Pedido QR de mesa no encontrado';
  end if;

  if auth.uid() is null
     or (not public.is_site_admin() and not public.has_restaurant_permission(v_order.restaurant_id,'pos')) then
    raise exception 'No autorizado para retirar este pedido QR';
  end if;

  if v_order.status='retirado_mesa' then
    if v_order.created_by is distinct from auth.uid() and not public.is_site_admin() then
      raise exception 'Este pedido ya fue retirado por otro mesero';
    end if;
    return v_order;
  end if;

  if v_order.status='entregado' then return v_order; end if;
  if v_order.status<>'listo' then raise exception 'El pedido debe estar Listo antes de retirarlo de cocina'; end if;

  update public.restaurant_orders
  set status='retirado_mesa',
      created_by=auth.uid(),
      kitchen_picked_up_at=now(),
      updated_at=now()
  where id=p_order_id
  returning * into v_order;

  return v_order;
end
$$;


--
-- Name: withdraw_waiter_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.withdraw_waiter_order(p_order_id bigint) RETURNS public.restaurant_orders
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_order public.restaurant_orders%rowtype;
begin
  select *
    into v_order
    from public.restaurant_orders
   where id=p_order_id
   for update;

  if not found or v_order.order_source <> 'waiter' then
    raise exception 'Pedido no encontrado';
  end if;

  if not public.has_restaurant_permission(v_order.restaurant_id,'pos') then
    raise exception 'No autorizado para retirar este pedido';
  end if;

  if not public.is_site_admin()
     and v_order.created_by is distinct from (select auth.uid()) then
    raise exception 'Solo puedes retirar tus propios pedidos';
  end if;

  if v_order.status='entregado' then
    return v_order;
  end if;

  if v_order.status <> 'listo' then
    raise exception 'El pedido debe estar Listo antes de retirarlo de cocina';
  end if;

  update public.restaurant_orders
     set status='entregado',
         updated_at=now()
   where id=p_order_id
   returning * into v_order;

  return v_order;
end;
$$;


--
-- Name: account_profile_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_profile_archive (
    user_id uuid NOT NULL,
    full_name text,
    phone text,
    default_address text,
    original_account_type text NOT NULL,
    archived_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_reason text DEFAULT 'account_type_separation'::text NOT NULL
);


--
-- Name: admin_client_preview_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_client_preview_sessions (
    session_id text NOT NULL,
    user_id uuid NOT NULL,
    restaurant_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '02:00:00'::interval) NOT NULL
);


--
-- Name: admin_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_users (
    user_id uuid NOT NULL,
    email text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_errors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_errors (
    id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    app_context text NOT NULL,
    category text DEFAULT 'system'::text NOT NULL,
    error_code text,
    message text,
    severity text DEFAULT 'error'::text NOT NULL,
    is_user_error boolean DEFAULT false NOT NULL,
    restaurant_id bigint,
    user_id uuid,
    session_id text,
    route text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    resolved_at timestamp with time zone,
    resolution_note text,
    CONSTRAINT app_errors_app_context_check CHECK ((app_context = ANY (ARRAY['landing'::text, 'restaurant'::text, 'client'::text, 'admin'::text]))),
    CONSTRAINT app_errors_severity_check CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'error'::text, 'critical'::text])))
);


--
-- Name: app_errors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.app_errors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_errors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.app_errors_id_seq OWNED BY public.app_errors.id;


--
-- Name: app_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_events (
    id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    app_context text NOT NULL,
    event_name text NOT NULL,
    module text,
    restaurant_id bigint,
    user_id uuid,
    plan_id bigint,
    session_id text,
    route text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT app_events_app_context_check CHECK ((app_context = ANY (ARRAY['landing'::text, 'restaurant'::text, 'client'::text, 'admin'::text])))
);


--
-- Name: app_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.app_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.app_events_id_seq OWNED BY public.app_events.id;


--
-- Name: business_payment_test_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_payment_test_overrides (
    restaurant_id bigint NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    business_public_key_backup text,
    business_access_token_backup text,
    business_mp_user_id_backup text,
    business_connection_existed boolean DEFAULT false NOT NULL,
    backup_taken_at timestamp with time zone
);


--
-- Name: customer_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_profiles (
    user_id uuid NOT NULL,
    full_name text DEFAULT ''::text NOT NULL,
    phone text,
    default_address text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_signup_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_signup_attempts (
    id bigint NOT NULL,
    fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_signup_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customer_signup_attempts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.customer_signup_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: observability_alert_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.observability_alert_log (
    id bigint NOT NULL,
    alert_key text NOT NULL,
    alert_type text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    recipient_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: observability_alert_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.observability_alert_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: observability_alert_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.observability_alert_log_id_seq OWNED BY public.observability_alert_log.id;


--
-- Name: payment_proofs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_proofs (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_id bigint,
    customer_id uuid,
    method_id bigint,
    reference text DEFAULT ''::text NOT NULL,
    proof_path text,
    amount numeric NOT NULL,
    currency_code text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    review_notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payment_proofs_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT payment_proofs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text])))
);


--
-- Name: payment_proofs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment_proofs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_proofs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: platform_countries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_countries (
    code text NOT NULL,
    name text NOT NULL,
    currency_code text NOT NULL,
    currency_symbol text NOT NULL,
    locale text NOT NULL,
    timezone text NOT NULL,
    phone_prefix text DEFAULT ''::text NOT NULL,
    mercadopago_enabled boolean DEFAULT false NOT NULL,
    alternative_payments jsonb DEFAULT '[]'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_countries_code_check CHECK ((code ~ '^[A-Z]{2}$'::text)),
    CONSTRAINT platform_countries_currency_code_check CHECK ((currency_code ~ '^[A-Z]{3}$'::text))
);


--
-- Name: professional_appointments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_appointments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_appointments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_availability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_availability (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    provider_id bigint NOT NULL,
    weekday smallint NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    slot_interval_minutes integer DEFAULT 15 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT professional_availability_check CHECK ((end_time > start_time)),
    CONSTRAINT professional_availability_slot_interval_minutes_check CHECK (((slot_interval_minutes >= 5) AND (slot_interval_minutes <= 240))),
    CONSTRAINT professional_availability_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6)))
);


--
-- Name: professional_availability_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_availability ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_availability_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_booking_payment_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_booking_payment_intents (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    service_id bigint NOT NULL,
    provider_id bigint NOT NULL,
    customer_id uuid NOT NULL,
    customer_name text NOT NULL,
    customer_phone text DEFAULT ''::text NOT NULL,
    customer_email text,
    notes text,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    block_ends_at timestamp with time zone NOT NULL,
    payment_mode text NOT NULL,
    total_amount numeric DEFAULT 0 NOT NULL,
    amount_due numeric DEFAULT 0 NOT NULL,
    paid_amount numeric DEFAULT 0 NOT NULL,
    payment_status text DEFAULT 'pending'::text NOT NULL,
    payment_method_id bigint,
    payment_method text,
    status text DEFAULT 'pending'::text NOT NULL,
    public_token uuid DEFAULT gen_random_uuid() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:20:00'::interval) NOT NULL,
    mp_preference_id text,
    mp_payment_id text,
    paid_at timestamp with time zone,
    appointment_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    mp_credential_source text,
    CONSTRAINT professional_booking_payment_intents_amounts_check CHECK (((total_amount >= (0)::numeric) AND (amount_due > (0)::numeric) AND (paid_amount >= (0)::numeric))),
    CONSTRAINT professional_booking_payment_intents_mode_check CHECK ((payment_mode = ANY (ARRAY['deposit'::text, 'full'::text]))),
    CONSTRAINT professional_booking_payment_intents_payment_status_check CHECK ((payment_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'expired'::text, 'cancelled'::text]))),
    CONSTRAINT professional_booking_payment_intents_range_check CHECK (((ends_at > starts_at) AND (block_ends_at >= ends_at))),
    CONSTRAINT professional_booking_payment_intents_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'converted'::text, 'expired'::text, 'cancelled'::text, 'rejected'::text]))),
    CONSTRAINT professional_intents_mp_credential_source_check CHECK (((mp_credential_source IS NULL) OR (mp_credential_source = ANY (ARRAY['admin'::text, 'business'::text]))))
);


--
-- Name: professional_booking_payment_intents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_booking_payment_intents ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_booking_payment_intents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_provider_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_provider_services (
    restaurant_id bigint NOT NULL,
    provider_id bigint NOT NULL,
    service_id bigint NOT NULL
);


--
-- Name: professional_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_providers (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    user_id uuid,
    name text NOT NULL,
    specialty text DEFAULT ''::text NOT NULL,
    bio text DEFAULT ''::text NOT NULL,
    phone text,
    email text,
    photo_url text,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: professional_providers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_providers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_providers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_services (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    duration_minutes integer DEFAULT 30 NOT NULL,
    buffer_minutes integer DEFAULT 0 NOT NULL,
    price numeric DEFAULT 0 NOT NULL,
    image_url text,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT professional_services_buffer_minutes_check CHECK (((buffer_minutes >= 0) AND (buffer_minutes <= 240))),
    CONSTRAINT professional_services_duration_minutes_check CHECK (((duration_minutes >= 5) AND (duration_minutes <= 1440))),
    CONSTRAINT professional_services_price_check CHECK ((price >= (0)::numeric))
);


--
-- Name: professional_services_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_services ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_services_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_time_off; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_time_off (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    provider_id bigint NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT professional_time_off_check CHECK ((ends_at > starts_at))
);


--
-- Name: professional_time_off_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_time_off ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_time_off_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: push_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_campaigns (
    id bigint NOT NULL,
    created_by uuid NOT NULL,
    audience text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    target_url text,
    country_code text,
    city text,
    business_type text,
    restaurant_id bigint,
    target_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    failed_count integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'sending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    failure_summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT push_campaigns_audience_check CHECK ((audience = ANY (ARRAY['customer'::text, 'restaurant'::text, 'admin'::text, 'all'::text]))),
    CONSTRAINT push_campaigns_status_check CHECK ((status = ANY (ARRAY['sending'::text, 'completed'::text, 'partial'::text, 'failed'::text])))
);


--
-- Name: push_campaigns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.push_campaigns ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.push_campaigns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: push_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_config (
    id boolean DEFAULT true NOT NULL,
    vapid_public_key text NOT NULL,
    vapid_private_key text NOT NULL,
    subject text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT push_config_id_check CHECK (id)
);


--
-- Name: push_notification_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_notification_log (
    event_key text NOT NULL,
    order_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: push_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_subscriptions (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    restaurant_id bigint,
    audience text NOT NULL,
    endpoint text NOT NULL,
    p256dh text NOT NULL,
    auth text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    country_code text,
    city text,
    business_type text,
    context_restaurant_id bigint,
    CONSTRAINT push_subscriptions_audience_check CHECK ((audience = ANY (ARRAY['customer'::text, 'restaurant'::text, 'admin'::text])))
);


--
-- Name: push_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.push_subscriptions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.push_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_cash_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_cash_movements (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    session_id bigint NOT NULL,
    order_id bigint,
    movement_type text NOT NULL,
    payment_method text DEFAULT 'Efectivo'::text NOT NULL,
    amount numeric(12,2) NOT NULL,
    description text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    retail_sale_id bigint,
    retail_return_id bigint,
    retail_online_order_id bigint,
    CONSTRAINT restaurant_cash_movements_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT restaurant_cash_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['sale'::text, 'income'::text, 'expense'::text, 'withdrawal'::text, 'refund'::text])))
);


--
-- Name: restaurant_cash_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_cash_movements ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_cash_movements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_cash_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_cash_sessions (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    opened_by uuid,
    closed_by uuid,
    status text DEFAULT 'open'::text NOT NULL,
    opening_amount numeric(12,2) DEFAULT 0 NOT NULL,
    expected_cash numeric(12,2),
    closing_amount numeric(12,2),
    difference numeric(12,2),
    notes text,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    CONSTRAINT restaurant_cash_sessions_opening_amount_check CHECK ((opening_amount >= (0)::numeric)),
    CONSTRAINT restaurant_cash_sessions_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])))
);


--
-- Name: restaurant_cash_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_cash_sessions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_cash_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    restaurant_id bigint,
    is_demo boolean DEFAULT false NOT NULL
);


--
-- Name: restaurant_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_email_notification_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_email_notification_log (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    event_type text NOT NULL,
    event_key text NOT NULL,
    recipient_email text NOT NULL,
    provider_message_id text,
    status text DEFAULT 'sent'::text NOT NULL,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurant_email_notification_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_email_notification_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_email_notification_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_inventory_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_inventory_items (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    unit text DEFAULT 'unidad'::text NOT NULL,
    current_stock numeric(14,3) DEFAULT 0 NOT NULL,
    minimum_stock numeric(14,3) DEFAULT 0 NOT NULL,
    unit_cost numeric(14,2) DEFAULT 0 NOT NULL,
    supplier text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    image_url text,
    CONSTRAINT restaurant_inventory_items_current_stock_check CHECK ((current_stock >= (0)::numeric)),
    CONSTRAINT restaurant_inventory_items_minimum_stock_check CHECK ((minimum_stock >= (0)::numeric)),
    CONSTRAINT restaurant_inventory_items_name_check CHECK (((length(TRIM(BOTH FROM name)) >= 1) AND (length(TRIM(BOTH FROM name)) <= 120))),
    CONSTRAINT restaurant_inventory_items_unit_check CHECK ((unit = ANY (ARRAY['unidad'::text, 'kg'::text, 'g'::text, 'l'::text, 'ml'::text, 'porción'::text, 'caja'::text, 'paquete'::text]))),
    CONSTRAINT restaurant_inventory_items_unit_cost_check CHECK ((unit_cost >= (0)::numeric))
);


--
-- Name: restaurant_inventory_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_inventory_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_inventory_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_inventory_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_inventory_movements (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    inventory_item_id bigint NOT NULL,
    movement_type text NOT NULL,
    quantity_delta numeric(14,3) NOT NULL,
    note text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_inventory_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['entrada'::text, 'salida'::text, 'ajuste'::text, 'consumo'::text]))),
    CONSTRAINT restaurant_inventory_movements_quantity_delta_check CHECK ((quantity_delta <> (0)::numeric))
);


--
-- Name: restaurant_inventory_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_inventory_movements ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_inventory_movements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_order_status_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_order_status_events (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_id bigint NOT NULL,
    previous_status text,
    new_status text NOT NULL,
    changed_by uuid,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurant_order_status_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_order_status_events ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_order_status_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_payment_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_payment_connections (
    restaurant_id bigint NOT NULL,
    provider text DEFAULT 'mercadopago'::text NOT NULL,
    mp_user_id text,
    access_token text,
    refresh_token text,
    token_expires_at timestamp with time zone,
    connected_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurant_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_payment_methods (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    method_type text NOT NULL,
    label text NOT NULL,
    account_holder text DEFAULT ''::text NOT NULL,
    account_identifier text DEFAULT ''::text NOT NULL,
    institution text DEFAULT ''::text NOT NULL,
    qr_image_url text,
    instructions text DEFAULT ''::text NOT NULL,
    requires_proof boolean DEFAULT true NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    document_id text,
    account_type text,
    logo_url text,
    CONSTRAINT restaurant_payment_methods_method_type_check CHECK ((method_type = ANY (ARRAY['mercadopago'::text, 'qr_bank'::text, 'bank_transfer'::text, 'yape'::text, 'plin'::text, 'pix'::text, 'yappy'::text, 'sinpe'::text, 'mobile_payment'::text, 'cash'::text])))
);


--
-- Name: restaurant_payment_methods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_payment_methods ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_payment_methods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_payments (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_id bigint NOT NULL,
    method text NOT NULL,
    provider text,
    status text DEFAULT 'pending'::text NOT NULL,
    amount numeric(12,2) NOT NULL,
    provider_payment_id text,
    reference text,
    paid_at timestamp with time zone,
    refunded_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    CONSTRAINT restaurant_payments_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT restaurant_payments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'refunded'::text, 'partially_refunded'::text])))
);


--
-- Name: restaurant_payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_payments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_product_ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_product_ingredients (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    product_id bigint NOT NULL,
    inventory_item_id bigint NOT NULL,
    quantity_per_unit numeric(14,3) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_product_ingredients_quantity_per_unit_check CHECK ((quantity_per_unit > (0)::numeric))
);


--
-- Name: restaurant_product_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_ingredients ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_product_ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_product_option_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_product_option_groups (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    product_id bigint NOT NULL,
    name text NOT NULL,
    selection_type text DEFAULT 'single'::text NOT NULL,
    required boolean DEFAULT false NOT NULL,
    min_select integer DEFAULT 0 NOT NULL,
    max_select integer,
    sort_order integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_product_option_groups_max_select_check CHECK (((max_select IS NULL) OR (max_select >= 1))),
    CONSTRAINT restaurant_product_option_groups_min_select_check CHECK ((min_select >= 0)),
    CONSTRAINT restaurant_product_option_groups_selection_type_check CHECK ((selection_type = ANY (ARRAY['single'::text, 'multiple'::text])))
);


--
-- Name: restaurant_product_option_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_option_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_product_option_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_product_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_product_options (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    group_id bigint NOT NULL,
    name text NOT NULL,
    price_delta numeric(12,2) DEFAULT 0 NOT NULL,
    available boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_product_options_price_delta_check CHECK ((price_delta >= (0)::numeric))
);


--
-- Name: restaurant_product_options_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_options ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_product_options_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_products (
    id bigint NOT NULL,
    category_id bigint,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    price numeric(12,2) NOT NULL,
    compare_price numeric(12,2),
    image_url text,
    badge text,
    featured boolean DEFAULT false NOT NULL,
    available boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    restaurant_id bigint,
    is_demo boolean DEFAULT false NOT NULL,
    CONSTRAINT restaurant_products_compare_price_check CHECK (((compare_price IS NULL) OR (compare_price >= (0)::numeric))),
    CONSTRAINT restaurant_products_price_check CHECK ((price >= (0)::numeric))
);


--
-- Name: restaurant_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_products ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_promotion_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_promotion_products (
    promotion_id bigint NOT NULL,
    product_id bigint NOT NULL,
    restaurant_id bigint NOT NULL
);


--
-- Name: restaurant_promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_promotions (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    code text,
    promotion_type text NOT NULL,
    value numeric(12,2) DEFAULT 0 NOT NULL,
    minimum_order numeric(12,2) DEFAULT 0 NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    first_order_only boolean DEFAULT false NOT NULL,
    usage_limit integer,
    usage_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_promotions_minimum_order_check CHECK ((minimum_order >= (0)::numeric)),
    CONSTRAINT restaurant_promotions_promotion_type_check CHECK ((promotion_type = ANY (ARRAY['percentage'::text, 'fixed'::text, 'two_for_one'::text]))),
    CONSTRAINT restaurant_promotions_usage_count_check CHECK ((usage_count >= 0)),
    CONSTRAINT restaurant_promotions_usage_limit_check CHECK (((usage_limit IS NULL) OR (usage_limit >= 1))),
    CONSTRAINT restaurant_promotions_value_check CHECK ((value >= (0)::numeric))
);


--
-- Name: restaurant_promotions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_promotions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_promotions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_reviews (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_id bigint NOT NULL,
    customer_id uuid NOT NULL,
    food_rating smallint NOT NULL,
    service_rating smallint NOT NULL,
    delivery_rating smallint,
    comment text,
    response text,
    responded_at timestamp with time zone,
    published boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_reviews_delivery_rating_check CHECK (((delivery_rating >= 1) AND (delivery_rating <= 5))),
    CONSTRAINT restaurant_reviews_food_rating_check CHECK (((food_rating >= 1) AND (food_rating <= 5))),
    CONSTRAINT restaurant_reviews_service_rating_check CHECK (((service_rating >= 1) AND (service_rating <= 5)))
);


--
-- Name: restaurant_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_reviews ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_settings (
    id bigint DEFAULT 1 NOT NULL,
    business_name text DEFAULT 'Hamburguesería Demo'::text NOT NULL,
    whatsapp text DEFAULT ''::text NOT NULL,
    address text DEFAULT ''::text NOT NULL,
    open_time time without time zone DEFAULT '20:30:00'::time without time zone NOT NULL,
    close_time time without time zone DEFAULT '23:30:00'::time without time zone NOT NULL,
    instagram text DEFAULT ''::text NOT NULL,
    pickup_eta text DEFAULT '20–30 min'::text NOT NULL,
    delivery_eta text DEFAULT '35–50 min'::text NOT NULL,
    delivery_note text DEFAULT 'Envío a confirmar'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_settings_id_check CHECK ((id = 1))
);


--
-- Name: restaurant_staff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_staff (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    user_id uuid NOT NULL,
    email text NOT NULL,
    role text DEFAULT 'manager'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    permissions jsonb DEFAULT '{"orders": true, "business": false, "products": true, "categories": true}'::jsonb NOT NULL,
    display_name text,
    CONSTRAINT restaurant_staff_role_check CHECK ((role = ANY (ARRAY['restaurant'::text, 'manager'::text, 'editor'::text, 'cashier'::text, 'kitchen'::text, 'courier'::text, 'waiter'::text, 'professional'::text, 'receptionist'::text])))
);


--
-- Name: restaurant_staff_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_staff ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_staff_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_subscription_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_subscription_history (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    action text NOT NULL,
    previous_status text,
    new_status text,
    previous_expires_at timestamp with time zone,
    new_expires_at timestamp with time zone,
    amount numeric(12,2),
    notes text DEFAULT ''::text NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurant_subscription_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_subscription_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_subscription_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_tables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_tables (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    token uuid DEFAULT gen_random_uuid() NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_tables_name_check CHECK (((char_length(TRIM(BOTH FROM name)) >= 1) AND (char_length(TRIM(BOTH FROM name)) <= 80)))
);


--
-- Name: restaurant_tables_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_tables ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_tables_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurant_veripagos_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_veripagos_connections (
    restaurant_id bigint NOT NULL,
    basic_username text NOT NULL,
    basic_password text NOT NULL,
    secret_key text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    vigencia text DEFAULT '0/00:15'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: restaurant_whatsapp_automations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_whatsapp_automations (
    restaurant_id bigint NOT NULL,
    menu_reply_enabled boolean DEFAULT true NOT NULL,
    menu_keywords text[] DEFAULT ARRAY['menu'::text, 'menú'::text, 'carta'::text, 'ver menu'::text, 'ver menú'::text] NOT NULL,
    order_received_enabled boolean DEFAULT true NOT NULL,
    order_preparation_enabled boolean DEFAULT true NOT NULL,
    order_ready_enabled boolean DEFAULT true NOT NULL,
    order_on_the_way_enabled boolean DEFAULT true NOT NULL,
    order_delivered_enabled boolean DEFAULT true NOT NULL,
    messages jsonb DEFAULT '{"menu": "¡Hola! 👋 Puedes ver nuestro menú y realizar tu pedido aquí: {{menu_url}}", "listo": "✅ Tu pedido {{order_code}} está listo.", "recibido": "✅ Recibimos tu pedido {{order_code}}. Gracias por tu compra.", "en_camino": "🛵 Tu pedido {{order_code}} está en camino.", "entregado": "🎉 Tu pedido {{order_code}} fue entregado. ¡Gracias por preferirnos!", "preparacion": "👨‍🍳 Tu pedido {{order_code}} está en preparación."}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_whatsapp_automations_messages_check CHECK ((jsonb_typeof(messages) = 'object'::text))
);


--
-- Name: restaurant_whatsapp_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_whatsapp_connections (
    restaurant_id bigint NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    status text DEFAULT 'disconnected'::text NOT NULL,
    provider text DEFAULT 'meta_cloud_api'::text NOT NULL,
    coexistence_enabled boolean DEFAULT true NOT NULL,
    waba_id text,
    phone_number_id text,
    display_phone_number text,
    verified_name text,
    credential_ref text,
    last_connected_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_whatsapp_connections_status_check CHECK ((status = ANY (ARRAY['disconnected'::text, 'pending'::text, 'connected'::text, 'error'::text])))
);


--
-- Name: restaurant_whatsapp_message_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_whatsapp_message_log (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_id bigint,
    direction text NOT NULL,
    trigger_type text,
    customer_phone text,
    message_preview text,
    provider_message_id text,
    status text DEFAULT 'pending'::text NOT NULL,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT restaurant_whatsapp_message_log_direction_check CHECK ((direction = ANY (ARRAY['inbound'::text, 'outbound'::text]))),
    CONSTRAINT restaurant_whatsapp_message_log_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'delivered'::text, 'read'::text, 'failed'::text, 'received'::text, 'skipped'::text])))
);


--
-- Name: restaurant_whatsapp_message_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_whatsapp_message_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurant_whatsapp_message_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: restaurants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.restaurants ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.restaurants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_online_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_online_order_items (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    barcode_snapshot text,
    name_snapshot text NOT NULL,
    quantity numeric(14,4) NOT NULL,
    unit_price numeric(14,4) NOT NULL,
    unit_cost numeric(14,4) DEFAULT 0 NOT NULL,
    line_total numeric(14,4) NOT NULL,
    CONSTRAINT retail_online_order_items_line_total_check CHECK ((line_total >= (0)::numeric)),
    CONSTRAINT retail_online_order_items_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT retail_online_order_items_unit_cost_check CHECK ((unit_cost >= (0)::numeric)),
    CONSTRAINT retail_online_order_items_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


--
-- Name: retail_online_order_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_online_order_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_online_order_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_online_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_online_orders (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    order_code text,
    tracking_token uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid,
    customer_name text NOT NULL,
    customer_phone text DEFAULT ''::text NOT NULL,
    customer_email text,
    order_type text DEFAULT 'Retiro'::text NOT NULL,
    delivery_address text,
    delivery_latitude double precision,
    delivery_longitude double precision,
    delivery_fee numeric(14,4) DEFAULT 0 NOT NULL,
    subtotal numeric(14,4) DEFAULT 0 NOT NULL,
    discount numeric(14,4) DEFAULT 0 NOT NULL,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    payment_method text DEFAULT 'Efectivo'::text NOT NULL,
    payment_status text DEFAULT 'pending'::text NOT NULL,
    status text DEFAULT 'received'::text NOT NULL,
    notes text,
    reservation_expires_at timestamp with time zone,
    mp_preference_id text,
    mp_payment_id text,
    paid_at timestamp with time zone,
    refund_status text DEFAULT 'none'::text NOT NULL,
    refunded_at timestamp with time zone,
    mp_refund_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    cash_session_id bigint,
    cash_recorded_at timestamp with time zone,
    mp_credential_source text,
    CONSTRAINT retail_online_orders_delivery_fee_check CHECK ((delivery_fee >= (0)::numeric)),
    CONSTRAINT retail_online_orders_discount_check CHECK ((discount >= (0)::numeric)),
    CONSTRAINT retail_online_orders_mp_credential_source_check CHECK (((mp_credential_source IS NULL) OR (mp_credential_source = ANY (ARRAY['admin'::text, 'business'::text])))),
    CONSTRAINT retail_online_orders_order_type_check CHECK ((order_type = ANY (ARRAY['Retiro'::text, 'Delivery'::text]))),
    CONSTRAINT retail_online_orders_payment_status_check CHECK ((payment_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text, 'refunded'::text]))),
    CONSTRAINT retail_online_orders_refund_status_check CHECK ((refund_status = ANY (ARRAY['none'::text, 'refunded'::text]))),
    CONSTRAINT retail_online_orders_status_check CHECK ((status = ANY (ARRAY['pending_payment'::text, 'received'::text, 'preparing'::text, 'ready'::text, 'delivered'::text, 'cancelled'::text]))),
    CONSTRAINT retail_online_orders_subtotal_check CHECK ((subtotal >= (0)::numeric)),
    CONSTRAINT retail_online_orders_total_check CHECK ((total >= (0)::numeric))
);


--
-- Name: retail_online_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_online_orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_online_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_products (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    barcode text,
    sku text,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    category text,
    brand text,
    unit text DEFAULT 'unidad'::text NOT NULL,
    cost numeric(14,4) DEFAULT 0 NOT NULL,
    price numeric(14,4) DEFAULT 0 NOT NULL,
    current_stock numeric(14,4) DEFAULT 0 NOT NULL,
    minimum_stock numeric(14,4) DEFAULT 0 NOT NULL,
    allow_fractional boolean DEFAULT false NOT NULL,
    image_url text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retail_products_cost_check CHECK ((cost >= (0)::numeric)),
    CONSTRAINT retail_products_current_stock_check CHECK ((current_stock >= (0)::numeric)),
    CONSTRAINT retail_products_minimum_stock_check CHECK ((minimum_stock >= (0)::numeric)),
    CONSTRAINT retail_products_price_check CHECK ((price >= (0)::numeric))
);


--
-- Name: retail_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_products ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_purchase_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_purchase_items (
    id bigint NOT NULL,
    purchase_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity numeric(14,4) NOT NULL,
    unit_cost numeric(14,4) NOT NULL,
    line_total numeric(14,4) NOT NULL,
    CONSTRAINT retail_purchase_items_line_total_check CHECK ((line_total >= (0)::numeric)),
    CONSTRAINT retail_purchase_items_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT retail_purchase_items_unit_cost_check CHECK ((unit_cost >= (0)::numeric))
);


--
-- Name: retail_purchase_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_purchase_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_purchase_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_purchases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_purchases (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    supplier_id bigint,
    document_number text,
    status text DEFAULT 'received'::text NOT NULL,
    subtotal numeric(14,4) DEFAULT 0 NOT NULL,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    notes text,
    received_at timestamp with time zone,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retail_purchases_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'received'::text, 'cancelled'::text]))),
    CONSTRAINT retail_purchases_subtotal_check CHECK ((subtotal >= (0)::numeric)),
    CONSTRAINT retail_purchases_total_check CHECK ((total >= (0)::numeric))
);


--
-- Name: retail_purchases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_purchases ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_purchases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_return_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_return_items (
    id bigint NOT NULL,
    return_id bigint NOT NULL,
    sale_item_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity numeric(14,4) NOT NULL,
    unit_refund numeric(14,4) NOT NULL,
    line_total numeric(14,4) NOT NULL,
    CONSTRAINT retail_return_items_line_total_check CHECK ((line_total >= (0)::numeric)),
    CONSTRAINT retail_return_items_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT retail_return_items_unit_refund_check CHECK ((unit_refund >= (0)::numeric))
);


--
-- Name: retail_return_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_return_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_return_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_returns (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    sale_id bigint NOT NULL,
    cash_session_id bigint,
    refund_method text DEFAULT 'Efectivo'::text NOT NULL,
    total numeric(14,4) NOT NULL,
    reason text,
    status text DEFAULT 'completed'::text NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retail_returns_status_check CHECK ((status = ANY (ARRAY['completed'::text, 'cancelled'::text]))),
    CONSTRAINT retail_returns_total_check CHECK ((total >= (0)::numeric))
);


--
-- Name: retail_returns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_returns ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_returns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_sale_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_sale_items (
    id bigint NOT NULL,
    sale_id bigint NOT NULL,
    product_id bigint NOT NULL,
    barcode_snapshot text,
    name_snapshot text NOT NULL,
    quantity numeric(14,4) NOT NULL,
    unit_price numeric(14,4) NOT NULL,
    unit_cost numeric(14,4) DEFAULT 0 NOT NULL,
    line_total numeric(14,4) NOT NULL,
    CONSTRAINT retail_sale_items_line_total_check CHECK ((line_total >= (0)::numeric)),
    CONSTRAINT retail_sale_items_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT retail_sale_items_unit_cost_check CHECK ((unit_cost >= (0)::numeric)),
    CONSTRAINT retail_sale_items_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


--
-- Name: retail_sale_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_sale_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_sale_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_sales (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    cash_session_id bigint,
    sale_code text,
    status text DEFAULT 'completed'::text NOT NULL,
    payment_method text DEFAULT 'Efectivo'::text NOT NULL,
    subtotal numeric(14,4) DEFAULT 0 NOT NULL,
    discount numeric(14,4) DEFAULT 0 NOT NULL,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    amount_received numeric(14,4),
    change_amount numeric(14,4) DEFAULT 0 NOT NULL,
    customer_name text,
    notes text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    voided_at timestamp with time zone,
    voided_by uuid,
    refunded_amount numeric(14,4) DEFAULT 0 NOT NULL,
    refund_status text DEFAULT 'none'::text NOT NULL,
    CONSTRAINT retail_sales_change_amount_check CHECK ((change_amount >= (0)::numeric)),
    CONSTRAINT retail_sales_discount_check CHECK ((discount >= (0)::numeric)),
    CONSTRAINT retail_sales_refund_status_check CHECK ((refund_status = ANY (ARRAY['none'::text, 'partial'::text, 'full'::text]))),
    CONSTRAINT retail_sales_refunded_amount_check CHECK (((refunded_amount >= (0)::numeric) AND (refunded_amount <= total))),
    CONSTRAINT retail_sales_status_check CHECK ((status = ANY (ARRAY['completed'::text, 'voided'::text]))),
    CONSTRAINT retail_sales_subtotal_check CHECK ((subtotal >= (0)::numeric)),
    CONSTRAINT retail_sales_total_check CHECK ((total >= (0)::numeric))
);


--
-- Name: retail_sales_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_sales ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_sales_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_stock_movements (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    product_id bigint NOT NULL,
    movement_type text NOT NULL,
    quantity_delta numeric(14,4) NOT NULL,
    stock_after numeric(14,4) NOT NULL,
    unit_cost numeric(14,4),
    reference_type text,
    reference_id bigint,
    note text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retail_stock_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['initial'::text, 'purchase'::text, 'sale'::text, 'return'::text, 'adjustment'::text, 'waste'::text, 'void_sale'::text, 'online_order'::text, 'online_release'::text]))),
    CONSTRAINT retail_stock_movements_stock_after_check CHECK ((stock_after >= (0)::numeric))
);


--
-- Name: retail_stock_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_stock_movements ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_stock_movements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: retail_suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retail_suppliers (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    tax_id text,
    phone text,
    email text,
    address text,
    notes text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: retail_suppliers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.retail_suppliers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.retail_suppliers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: site_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_links (
    key text NOT NULL,
    label text NOT NULL,
    url text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT site_links_key_check CHECK ((key ~ '^[a-z0-9_]+$'::text))
);


--
-- Name: streaming_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_accounts (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    platform_id bigint NOT NULL,
    label text NOT NULL,
    login_identifier text DEFAULT ''::text NOT NULL,
    max_slots integer DEFAULT 1 NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT streaming_accounts_label_check CHECK (((char_length(TRIM(BOTH FROM label)) >= 1) AND (char_length(TRIM(BOTH FROM label)) <= 120))),
    CONSTRAINT streaming_accounts_max_slots_check CHECK (((max_slots >= 1) AND (max_slots <= 100)))
);


--
-- Name: streaming_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_accounts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_customers (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    full_name text NOT NULL,
    phone text DEFAULT ''::text NOT NULL,
    email text,
    notes text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT streaming_customers_full_name_check CHECK (((char_length(TRIM(BOTH FROM full_name)) >= 1) AND (char_length(TRIM(BOTH FROM full_name)) <= 120)))
);


--
-- Name: streaming_customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_customers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_platforms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_platforms (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    name text NOT NULL,
    default_duration_days integer DEFAULT 30 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sale_price numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT streaming_platforms_default_duration_days_check CHECK (((default_duration_days >= 1) AND (default_duration_days <= 3650))),
    CONSTRAINT streaming_platforms_name_check CHECK (((char_length(TRIM(BOTH FROM name)) >= 1) AND (char_length(TRIM(BOTH FROM name)) <= 80)))
);


--
-- Name: streaming_platforms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_platforms ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_platforms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_reminder_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_reminder_logs (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    subscription_id bigint NOT NULL,
    reminder_type text NOT NULL,
    channel text DEFAULT 'whatsapp'::text NOT NULL,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    opened_date date DEFAULT ((now() AT TIME ZONE 'America/Santiago'::text))::date NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    CONSTRAINT streaming_reminder_logs_channel_check CHECK ((channel = 'whatsapp'::text)),
    CONSTRAINT streaming_reminder_logs_reminder_type_check CHECK ((reminder_type = ANY (ARRAY['payment'::text, 'delivery'::text, 'urgent'::text, 'expired'::text])))
);


--
-- Name: streaming_reminder_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_reminder_logs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_reminder_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_renewals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streaming_renewals (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    subscription_id bigint NOT NULL,
    previous_expires_at timestamp with time zone NOT NULL,
    new_expires_at timestamp with time zone NOT NULL,
    amount numeric DEFAULT 0 NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    payment_method text DEFAULT ''::text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    renewed_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT streaming_renewals_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT streaming_renewals_check CHECK ((new_expires_at > previous_expires_at)),
    CONSTRAINT streaming_renewals_currency_code_check CHECK ((currency_code ~ '^[A-Z]{3}$'::text))
);


--
-- Name: streaming_renewals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_renewals ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_renewals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: streaming_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.streaming_subscriptions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.streaming_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: subscription_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_payment_methods (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    user_id uuid NOT NULL,
    mp_subscription_id text NOT NULL,
    payment_method_id text,
    last_four_digits text,
    cardholder_name text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscription_payment_methods_last4_check CHECK (((last_four_digits IS NULL) OR (last_four_digits ~ '^[0-9]{4}$'::text)))
);


--
-- Name: subscription_payment_methods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payment_methods ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.subscription_payment_methods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: subscription_payment_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_payment_providers (
    provider text NOT NULL,
    label text NOT NULL,
    active boolean DEFAULT false NOT NULL,
    supported_countries text[] DEFAULT '{}'::text[] NOT NULL,
    settlement_currency text,
    public_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscription_payment_providers_provider_check CHECK ((provider = ANY (ARRAY['mercadopago'::text, 'binance_pay'::text, 'bank_transfer'::text])))
);


--
-- Name: subscription_payment_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_payment_settings (
    id integer DEFAULT 1 NOT NULL,
    public_key text,
    access_token text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    flow_api_key text,
    flow_secret_key text,
    flow_environment text DEFAULT 'sandbox'::text NOT NULL,
    flow_enabled boolean DEFAULT false NOT NULL,
    veripagos_basic_username text,
    veripagos_basic_password text,
    veripagos_secret_key text,
    veripagos_enabled boolean DEFAULT false NOT NULL,
    veripagos_vigencia text DEFAULT '0/00:15'::text NOT NULL,
    veripagos_cron_token text,
    CONSTRAINT subscription_payment_settings_flow_environment_check CHECK ((flow_environment = ANY (ARRAY['sandbox'::text, 'production'::text]))),
    CONSTRAINT subscription_payment_settings_id_check CHECK ((id = 1))
);


--
-- Name: subscription_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_payments (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    plan_id bigint NOT NULL,
    user_id uuid NOT NULL,
    mp_preference_id text,
    mp_payment_id text,
    amount numeric(12,2) NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    paid_at timestamp with time zone,
    mp_subscription_id text,
    payment_type text DEFAULT 'one_time'::text NOT NULL,
    provider text DEFAULT 'mercadopago'::text NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    provider_order_id text,
    provider_token text,
    checkout_url text,
    provider_customer_id text,
    provider_subscription_id text,
    provider_plan_id text,
    provider_meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    billing_cycle text DEFAULT 'monthly'::text NOT NULL,
    access_days integer,
    bonus_months integer DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    CONSTRAINT subscription_payments_billing_cycle_check CHECK ((billing_cycle = ANY (ARRAY['monthly'::text, 'annual'::text])))
);


--
-- Name: subscription_payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.subscription_payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: subscription_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_plans (
    id bigint NOT NULL,
    name text NOT NULL,
    amount numeric(12,2) DEFAULT 0 NOT NULL,
    days integer NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    modules jsonb DEFAULT '[]'::jsonb NOT NULL,
    currency_code text DEFAULT 'CLP'::text NOT NULL,
    country_prices jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_default_trial boolean DEFAULT false NOT NULL,
    annual_enabled boolean DEFAULT false NOT NULL,
    annual_amount numeric,
    annual_bonus_months integer DEFAULT 0 NOT NULL,
    annual_days integer DEFAULT 365 NOT NULL,
    business_type text DEFAULT 'restaurant'::text NOT NULL,
    CONSTRAINT subscription_plans_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT subscription_plans_annual_amount_check CHECK (((annual_amount IS NULL) OR (annual_amount >= (0)::numeric))),
    CONSTRAINT subscription_plans_annual_bonus_months_check CHECK (((annual_bonus_months >= 0) AND (annual_bonus_months <= 11))),
    CONSTRAINT subscription_plans_annual_days_check CHECK ((annual_days >= 1)),
    CONSTRAINT subscription_plans_business_type_check CHECK ((business_type = ANY (ARRAY['restaurant'::text, 'supermarket'::text, 'minimarket'::text, 'professional'::text, 'streaming'::text]))),
    CONSTRAINT subscription_plans_days_check CHECK ((days > 0)),
    CONSTRAINT subscription_plans_modules_is_array CHECK ((jsonb_typeof(modules) = 'array'::text))
);


--
-- Name: subscription_plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.subscription_plans ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.subscription_plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: table_qr_push_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.table_qr_push_subscriptions (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    endpoint text NOT NULL,
    p256dh text NOT NULL,
    auth text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: table_qr_push_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.table_qr_push_subscriptions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.table_qr_push_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_issue_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_issue_reports (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    app_context text NOT NULL,
    restaurant_id bigint,
    user_id uuid,
    title text NOT NULL,
    description text NOT NULL,
    route text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    resolved_at timestamp with time zone,
    resolution_note text,
    CONSTRAINT user_issue_reports_app_context_check CHECK ((app_context = ANY (ARRAY['restaurant'::text, 'client'::text]))),
    CONSTRAINT user_issue_reports_status_check CHECK ((status = ANY (ARRAY['open'::text, 'reviewing'::text, 'resolved'::text, 'dismissed'::text])))
);


--
-- Name: user_issue_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_issue_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_issue_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_issue_reports_id_seq OWNED BY public.user_issue_reports.id;


--
-- Name: user_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profiles (
    user_id uuid NOT NULL,
    email text DEFAULT ''::text NOT NULL,
    account_type text DEFAULT 'customer'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_profiles_account_type_check CHECK ((account_type = ANY (ARRAY['customer'::text, 'restaurant'::text, 'admin'::text])))
);


--
-- Name: veripagos_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.veripagos_transactions (
    id bigint NOT NULL,
    scope text NOT NULL,
    restaurant_id bigint NOT NULL,
    subscription_payment_id bigint,
    order_id bigint,
    movimiento_id text NOT NULL,
    amount numeric NOT NULL,
    currency_code text DEFAULT 'BOB'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    qr_base64 text,
    provider_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    paid_at timestamp with time zone,
    last_checked_at timestamp with time zone,
    next_check_at timestamp with time zone,
    check_count integer DEFAULT 0 NOT NULL,
    last_provider_status text,
    last_error text,
    expires_at timestamp with time zone,
    retail_order_id bigint,
    CONSTRAINT veripagos_transactions_scope_check CHECK ((scope = ANY (ARRAY['subscription'::text, 'restaurant_order'::text, 'retail_order'::text])))
);


--
-- Name: veripagos_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.veripagos_transactions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.veripagos_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: whatsapp_webhook_diagnostic_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.whatsapp_webhook_diagnostic_log (
    id bigint NOT NULL,
    event_type text DEFAULT 'webhook'::text NOT NULL,
    phone_number_id text,
    matched_connection boolean DEFAULT false NOT NULL,
    message_count integer DEFAULT 0 NOT NULL,
    status_count integer DEFAULT 0 NOT NULL,
    source text DEFAULT 'meta'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE whatsapp_webhook_diagnostic_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.whatsapp_webhook_diagnostic_log IS 'Technical diagnostics for valid Meta WhatsApp webhook events. No message bodies or customer phone numbers are stored.';


--
-- Name: whatsapp_webhook_diagnostic_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.whatsapp_webhook_diagnostic_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.whatsapp_webhook_diagnostic_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: app_errors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_errors ALTER COLUMN id SET DEFAULT nextval('public.app_errors_id_seq'::regclass);


--
-- Name: app_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_events ALTER COLUMN id SET DEFAULT nextval('public.app_events_id_seq'::regclass);


--
-- Name: observability_alert_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_alert_log ALTER COLUMN id SET DEFAULT nextval('public.observability_alert_log_id_seq'::regclass);


--
-- Name: user_issue_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_issue_reports ALTER COLUMN id SET DEFAULT nextval('public.user_issue_reports_id_seq'::regclass);


--
-- Name: account_profile_archive account_profile_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_profile_archive
    ADD CONSTRAINT account_profile_archive_pkey PRIMARY KEY (user_id);


--
-- Name: admin_client_preview_sessions admin_client_preview_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_client_preview_sessions
    ADD CONSTRAINT admin_client_preview_sessions_pkey PRIMARY KEY (session_id);


--
-- Name: admin_users admin_users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users
    ADD CONSTRAINT admin_users_email_key UNIQUE (email);


--
-- Name: admin_users admin_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users
    ADD CONSTRAINT admin_users_pkey PRIMARY KEY (user_id);


--
-- Name: app_errors app_errors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_errors
    ADD CONSTRAINT app_errors_pkey PRIMARY KEY (id);


--
-- Name: app_events app_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_events
    ADD CONSTRAINT app_events_pkey PRIMARY KEY (id);


--
-- Name: business_payment_test_overrides business_payment_test_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_payment_test_overrides
    ADD CONSTRAINT business_payment_test_overrides_pkey PRIMARY KEY (restaurant_id);


--
-- Name: customer_profiles customer_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_profiles
    ADD CONSTRAINT customer_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: customer_signup_attempts customer_signup_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_signup_attempts
    ADD CONSTRAINT customer_signup_attempts_pkey PRIMARY KEY (id);


--
-- Name: observability_alert_log observability_alert_log_alert_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_alert_log
    ADD CONSTRAINT observability_alert_log_alert_key_key UNIQUE (alert_key);


--
-- Name: observability_alert_log observability_alert_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_alert_log
    ADD CONSTRAINT observability_alert_log_pkey PRIMARY KEY (id);


--
-- Name: payment_proofs payment_proofs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_pkey PRIMARY KEY (id);


--
-- Name: platform_countries platform_countries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_countries
    ADD CONSTRAINT platform_countries_pkey PRIMARY KEY (code);


--
-- Name: professional_appointments professional_appointments_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_no_overlap EXCLUDE USING gist (provider_id WITH =, tstzrange(starts_at, ends_at, '[)'::text) WITH &&) WHERE ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'in_service'::text])));


--
-- Name: professional_appointments professional_appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_pkey PRIMARY KEY (id);


--
-- Name: professional_availability professional_availability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_availability
    ADD CONSTRAINT professional_availability_pkey PRIMARY KEY (id);


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_appointment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_appointment_id_key UNIQUE (appointment_id);


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_no_overlap EXCLUDE USING gist (provider_id WITH =, tstzrange(starts_at, block_ends_at, '[)'::text) WITH &&) WHERE ((status = ANY (ARRAY['pending'::text, 'processing'::text])));


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_pkey PRIMARY KEY (id);


--
-- Name: professional_provider_services professional_provider_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_provider_services
    ADD CONSTRAINT professional_provider_services_pkey PRIMARY KEY (provider_id, service_id);


--
-- Name: professional_providers professional_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_providers
    ADD CONSTRAINT professional_providers_pkey PRIMARY KEY (id);


--
-- Name: professional_services professional_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_services
    ADD CONSTRAINT professional_services_pkey PRIMARY KEY (id);


--
-- Name: professional_time_off professional_time_off_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_time_off
    ADD CONSTRAINT professional_time_off_pkey PRIMARY KEY (id);


--
-- Name: push_campaigns push_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_campaigns
    ADD CONSTRAINT push_campaigns_pkey PRIMARY KEY (id);


--
-- Name: push_config push_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_config
    ADD CONSTRAINT push_config_pkey PRIMARY KEY (id);


--
-- Name: push_notification_log push_notification_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_notification_log
    ADD CONSTRAINT push_notification_log_pkey PRIMARY KEY (event_key);


--
-- Name: push_subscriptions push_subscriptions_endpoint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_endpoint_key UNIQUE (endpoint);


--
-- Name: push_subscriptions push_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: restaurant_cash_movements restaurant_cash_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_pkey PRIMARY KEY (id);


--
-- Name: restaurant_cash_sessions restaurant_cash_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_sessions
    ADD CONSTRAINT restaurant_cash_sessions_pkey PRIMARY KEY (id);


--
-- Name: restaurant_categories restaurant_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_categories
    ADD CONSTRAINT restaurant_categories_pkey PRIMARY KEY (id);


--
-- Name: restaurant_email_notification_log restaurant_email_notification_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_email_notification_log
    ADD CONSTRAINT restaurant_email_notification_log_pkey PRIMARY KEY (id);


--
-- Name: restaurant_email_notification_log restaurant_email_notification_log_restaurant_id_event_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_email_notification_log
    ADD CONSTRAINT restaurant_email_notification_log_restaurant_id_event_key_key UNIQUE (restaurant_id, event_key);


--
-- Name: restaurant_inventory_items restaurant_inventory_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_items
    ADD CONSTRAINT restaurant_inventory_items_pkey PRIMARY KEY (id);


--
-- Name: restaurant_inventory_items restaurant_inventory_items_restaurant_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_items
    ADD CONSTRAINT restaurant_inventory_items_restaurant_id_name_key UNIQUE (restaurant_id, name);


--
-- Name: restaurant_inventory_movements restaurant_inventory_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_movements
    ADD CONSTRAINT restaurant_inventory_movements_pkey PRIMARY KEY (id);


--
-- Name: restaurant_order_status_events restaurant_order_status_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_order_status_events
    ADD CONSTRAINT restaurant_order_status_events_pkey PRIMARY KEY (id);


--
-- Name: restaurant_orders restaurant_orders_order_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_order_code_key UNIQUE (order_code);


--
-- Name: restaurant_orders restaurant_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_pkey PRIMARY KEY (id);


--
-- Name: restaurant_payment_connections restaurant_payment_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payment_connections
    ADD CONSTRAINT restaurant_payment_connections_pkey PRIMARY KEY (restaurant_id);


--
-- Name: restaurant_payment_methods restaurant_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payment_methods
    ADD CONSTRAINT restaurant_payment_methods_pkey PRIMARY KEY (id);


--
-- Name: restaurant_payments restaurant_payments_order_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payments
    ADD CONSTRAINT restaurant_payments_order_id_key UNIQUE (order_id);


--
-- Name: restaurant_payments restaurant_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payments
    ADD CONSTRAINT restaurant_payments_pkey PRIMARY KEY (id);


--
-- Name: restaurant_product_ingredients restaurant_product_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_ingredients
    ADD CONSTRAINT restaurant_product_ingredients_pkey PRIMARY KEY (id);


--
-- Name: restaurant_product_ingredients restaurant_product_ingredients_product_id_inventory_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_ingredients
    ADD CONSTRAINT restaurant_product_ingredients_product_id_inventory_item_id_key UNIQUE (product_id, inventory_item_id);


--
-- Name: restaurant_product_option_groups restaurant_product_option_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_option_groups
    ADD CONSTRAINT restaurant_product_option_groups_pkey PRIMARY KEY (id);


--
-- Name: restaurant_product_option_groups restaurant_product_option_groups_product_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_option_groups
    ADD CONSTRAINT restaurant_product_option_groups_product_id_name_key UNIQUE (product_id, name);


--
-- Name: restaurant_product_options restaurant_product_options_group_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_options
    ADD CONSTRAINT restaurant_product_options_group_id_name_key UNIQUE (group_id, name);


--
-- Name: restaurant_product_options restaurant_product_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_options
    ADD CONSTRAINT restaurant_product_options_pkey PRIMARY KEY (id);


--
-- Name: restaurant_products restaurant_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_products
    ADD CONSTRAINT restaurant_products_pkey PRIMARY KEY (id);


--
-- Name: restaurant_promotion_products restaurant_promotion_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotion_products
    ADD CONSTRAINT restaurant_promotion_products_pkey PRIMARY KEY (promotion_id, product_id);


--
-- Name: restaurant_promotions restaurant_promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotions
    ADD CONSTRAINT restaurant_promotions_pkey PRIMARY KEY (id);


--
-- Name: restaurant_reviews restaurant_reviews_order_id_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_reviews
    ADD CONSTRAINT restaurant_reviews_order_id_customer_id_key UNIQUE (order_id, customer_id);


--
-- Name: restaurant_reviews restaurant_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_reviews
    ADD CONSTRAINT restaurant_reviews_pkey PRIMARY KEY (id);


--
-- Name: restaurant_settings restaurant_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_settings
    ADD CONSTRAINT restaurant_settings_pkey PRIMARY KEY (id);


--
-- Name: restaurant_staff restaurant_staff_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_staff
    ADD CONSTRAINT restaurant_staff_pkey PRIMARY KEY (id);


--
-- Name: restaurant_staff restaurant_staff_restaurant_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_staff
    ADD CONSTRAINT restaurant_staff_restaurant_id_user_id_key UNIQUE (restaurant_id, user_id);


--
-- Name: restaurant_subscription_history restaurant_subscription_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_subscription_history
    ADD CONSTRAINT restaurant_subscription_history_pkey PRIMARY KEY (id);


--
-- Name: restaurant_tables restaurant_tables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_tables
    ADD CONSTRAINT restaurant_tables_pkey PRIMARY KEY (id);


--
-- Name: restaurant_tables restaurant_tables_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_tables
    ADD CONSTRAINT restaurant_tables_token_key UNIQUE (token);


--
-- Name: restaurant_veripagos_connections restaurant_veripagos_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_veripagos_connections
    ADD CONSTRAINT restaurant_veripagos_connections_pkey PRIMARY KEY (restaurant_id);


--
-- Name: restaurant_whatsapp_automations restaurant_whatsapp_automations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_automations
    ADD CONSTRAINT restaurant_whatsapp_automations_pkey PRIMARY KEY (restaurant_id);


--
-- Name: restaurant_whatsapp_connections restaurant_whatsapp_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_connections
    ADD CONSTRAINT restaurant_whatsapp_connections_pkey PRIMARY KEY (restaurant_id);


--
-- Name: restaurant_whatsapp_message_log restaurant_whatsapp_message_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_message_log
    ADD CONSTRAINT restaurant_whatsapp_message_log_pkey PRIMARY KEY (id);


--
-- Name: restaurants restaurants_custom_domain_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_custom_domain_key UNIQUE (custom_domain);


--
-- Name: restaurants restaurants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_pkey PRIMARY KEY (id);


--
-- Name: restaurants restaurants_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_slug_key UNIQUE (slug);


--
-- Name: retail_online_order_items retail_online_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_order_items
    ADD CONSTRAINT retail_online_order_items_pkey PRIMARY KEY (id);


--
-- Name: retail_online_orders retail_online_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_orders
    ADD CONSTRAINT retail_online_orders_pkey PRIMARY KEY (id);


--
-- Name: retail_products retail_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_products
    ADD CONSTRAINT retail_products_pkey PRIMARY KEY (id);


--
-- Name: retail_purchase_items retail_purchase_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchase_items
    ADD CONSTRAINT retail_purchase_items_pkey PRIMARY KEY (id);


--
-- Name: retail_purchases retail_purchases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchases
    ADD CONSTRAINT retail_purchases_pkey PRIMARY KEY (id);


--
-- Name: retail_return_items retail_return_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_return_items
    ADD CONSTRAINT retail_return_items_pkey PRIMARY KEY (id);


--
-- Name: retail_returns retail_returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_returns
    ADD CONSTRAINT retail_returns_pkey PRIMARY KEY (id);


--
-- Name: retail_sale_items retail_sale_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sale_items
    ADD CONSTRAINT retail_sale_items_pkey PRIMARY KEY (id);


--
-- Name: retail_sales retail_sales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sales
    ADD CONSTRAINT retail_sales_pkey PRIMARY KEY (id);


--
-- Name: retail_stock_movements retail_stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_stock_movements
    ADD CONSTRAINT retail_stock_movements_pkey PRIMARY KEY (id);


--
-- Name: retail_suppliers retail_suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_suppliers
    ADD CONSTRAINT retail_suppliers_pkey PRIMARY KEY (id);


--
-- Name: site_links site_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_links
    ADD CONSTRAINT site_links_pkey PRIMARY KEY (key);


--
-- Name: streaming_accounts streaming_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_pkey PRIMARY KEY (id);


--
-- Name: streaming_accounts streaming_accounts_restaurant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_restaurant_id_id_key UNIQUE (restaurant_id, id);


--
-- Name: streaming_accounts streaming_accounts_restaurant_id_platform_id_label_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_restaurant_id_platform_id_label_key UNIQUE (restaurant_id, platform_id, label);


--
-- Name: streaming_accounts streaming_accounts_restaurant_platform_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_restaurant_platform_id_uq UNIQUE (restaurant_id, platform_id, id);


--
-- Name: streaming_customers streaming_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_customers
    ADD CONSTRAINT streaming_customers_pkey PRIMARY KEY (id);


--
-- Name: streaming_customers streaming_customers_restaurant_id_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_customers
    ADD CONSTRAINT streaming_customers_restaurant_id_id_uq UNIQUE (restaurant_id, id);


--
-- Name: streaming_orders streaming_orders_order_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_orders
    ADD CONSTRAINT streaming_orders_order_code_key UNIQUE (order_code);


--
-- Name: streaming_orders streaming_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_orders
    ADD CONSTRAINT streaming_orders_pkey PRIMARY KEY (id);


--
-- Name: streaming_platforms streaming_platforms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_platforms
    ADD CONSTRAINT streaming_platforms_pkey PRIMARY KEY (id);


--
-- Name: streaming_platforms streaming_platforms_restaurant_id_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_platforms
    ADD CONSTRAINT streaming_platforms_restaurant_id_id_uq UNIQUE (restaurant_id, id);


--
-- Name: streaming_reminder_logs streaming_reminder_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_reminder_logs
    ADD CONSTRAINT streaming_reminder_logs_pkey PRIMARY KEY (id);


--
-- Name: streaming_renewals streaming_renewals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_renewals
    ADD CONSTRAINT streaming_renewals_pkey PRIMARY KEY (id);


--
-- Name: streaming_subscriptions streaming_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: streaming_subscriptions streaming_subscriptions_restaurant_id_id_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_restaurant_id_id_uq UNIQUE (restaurant_id, id);


--
-- Name: subscription_payment_methods subscription_payment_methods_mp_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_methods
    ADD CONSTRAINT subscription_payment_methods_mp_subscription_id_key UNIQUE (mp_subscription_id);


--
-- Name: subscription_payment_methods subscription_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_methods
    ADD CONSTRAINT subscription_payment_methods_pkey PRIMARY KEY (id);


--
-- Name: subscription_payment_providers subscription_payment_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_providers
    ADD CONSTRAINT subscription_payment_providers_pkey PRIMARY KEY (provider);


--
-- Name: subscription_payment_settings subscription_payment_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_settings
    ADD CONSTRAINT subscription_payment_settings_pkey PRIMARY KEY (id);


--
-- Name: subscription_payments subscription_payments_mp_payment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_mp_payment_id_key UNIQUE (mp_payment_id);


--
-- Name: subscription_payments subscription_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_pkey PRIMARY KEY (id);


--
-- Name: subscription_plans subscription_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_plans
    ADD CONSTRAINT subscription_plans_pkey PRIMARY KEY (id);


--
-- Name: table_qr_push_subscriptions table_qr_push_subscriptions_order_id_endpoint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.table_qr_push_subscriptions
    ADD CONSTRAINT table_qr_push_subscriptions_order_id_endpoint_key UNIQUE (order_id, endpoint);


--
-- Name: table_qr_push_subscriptions table_qr_push_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.table_qr_push_subscriptions
    ADD CONSTRAINT table_qr_push_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: user_issue_reports user_issue_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_issue_reports
    ADD CONSTRAINT user_issue_reports_pkey PRIMARY KEY (id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: veripagos_transactions veripagos_transactions_movimiento_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_movimiento_id_key UNIQUE (movimiento_id);


--
-- Name: veripagos_transactions veripagos_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_pkey PRIMARY KEY (id);


--
-- Name: whatsapp_webhook_diagnostic_log whatsapp_webhook_diagnostic_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_webhook_diagnostic_log
    ADD CONSTRAINT whatsapp_webhook_diagnostic_log_pkey PRIMARY KEY (id);


--
-- Name: admin_client_preview_sessions_user_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_client_preview_sessions_user_restaurant_idx ON public.admin_client_preview_sessions USING btree (user_id, restaurant_id, expires_at);


--
-- Name: app_errors_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_errors_occurred_at_idx ON public.app_errors USING btree (occurred_at DESC);


--
-- Name: app_errors_restaurant_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_errors_restaurant_time_idx ON public.app_errors USING btree (restaurant_id, occurred_at DESC);


--
-- Name: app_errors_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_errors_status_idx ON public.app_errors USING btree (resolved, severity, occurred_at DESC);


--
-- Name: app_events_context_module_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_events_context_module_idx ON public.app_events USING btree (app_context, module, occurred_at DESC);


--
-- Name: app_events_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_events_occurred_at_idx ON public.app_events USING btree (occurred_at DESC);


--
-- Name: app_events_restaurant_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_events_restaurant_time_idx ON public.app_events USING btree (restaurant_id, occurred_at DESC);


--
-- Name: cash_movements_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cash_movements_session_idx ON public.restaurant_cash_movements USING btree (session_id, created_at DESC);


--
-- Name: cash_sale_per_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cash_sale_per_order ON public.restaurant_cash_movements USING btree (order_id, movement_type) WHERE ((order_id IS NOT NULL) AND (movement_type = ANY (ARRAY['sale'::text, 'refund'::text])));


--
-- Name: idx_cash_movements_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cash_movements_created_by ON public.restaurant_cash_movements USING btree (created_by);


--
-- Name: idx_cash_movements_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cash_movements_order ON public.restaurant_cash_movements USING btree (order_id);


--
-- Name: idx_cash_movements_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cash_movements_restaurant ON public.restaurant_cash_movements USING btree (restaurant_id, created_at DESC);


--
-- Name: idx_cash_sessions_closed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cash_sessions_closed_by ON public.restaurant_cash_sessions USING btree (closed_by);


--
-- Name: idx_cash_sessions_opened_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cash_sessions_opened_by ON public.restaurant_cash_sessions USING btree (opened_by);


--
-- Name: idx_order_status_events_changed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_status_events_changed_by ON public.restaurant_order_status_events USING btree (changed_by);


--
-- Name: idx_order_status_events_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_status_events_restaurant ON public.restaurant_order_status_events USING btree (restaurant_id, created_at DESC);


--
-- Name: idx_payments_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_order ON public.restaurant_payments USING btree (order_id);


--
-- Name: idx_product_option_groups_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_option_groups_restaurant ON public.restaurant_product_option_groups USING btree (restaurant_id);


--
-- Name: idx_product_options_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_options_restaurant ON public.restaurant_product_options USING btree (restaurant_id);


--
-- Name: idx_promotion_products_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotion_products_product ON public.restaurant_promotion_products USING btree (product_id);


--
-- Name: idx_promotion_products_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotion_products_restaurant ON public.restaurant_promotion_products USING btree (restaurant_id);


--
-- Name: idx_promotions_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotions_restaurant ON public.restaurant_promotions USING btree (restaurant_id, active);


--
-- Name: idx_reviews_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_customer ON public.restaurant_reviews USING btree (customer_id);


--
-- Name: idx_reviews_restaurant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_restaurant_created ON public.restaurant_reviews USING btree (restaurant_id, created_at DESC);


--
-- Name: one_open_cash_session_per_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX one_open_cash_session_per_restaurant ON public.restaurant_cash_sessions USING btree (restaurant_id) WHERE (status = 'open'::text);


--
-- Name: option_groups_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX option_groups_product_idx ON public.restaurant_product_option_groups USING btree (product_id, active, sort_order);


--
-- Name: order_status_events_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_status_events_order_idx ON public.restaurant_order_status_events USING btree (order_id, created_at DESC);


--
-- Name: payment_proofs_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_proofs_customer_idx ON public.payment_proofs USING btree (customer_id);


--
-- Name: payment_proofs_method_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_proofs_method_idx ON public.payment_proofs USING btree (method_id);


--
-- Name: payment_proofs_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_proofs_order_idx ON public.payment_proofs USING btree (order_id);


--
-- Name: payment_proofs_restaurant_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_proofs_restaurant_status_idx ON public.payment_proofs USING btree (restaurant_id, status);


--
-- Name: payment_proofs_reviewer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_proofs_reviewer_idx ON public.payment_proofs USING btree (reviewed_by);


--
-- Name: product_options_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_options_group_idx ON public.restaurant_product_options USING btree (group_id, available, sort_order);


--
-- Name: professional_appointments_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_appointments_provider_idx ON public.professional_appointments USING btree (provider_id, starts_at, ends_at, status);


--
-- Name: professional_appointments_public_token_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX professional_appointments_public_token_key ON public.professional_appointments USING btree (public_token);


--
-- Name: professional_appointments_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_appointments_restaurant_idx ON public.professional_appointments USING btree (restaurant_id, starts_at, status);


--
-- Name: professional_availability_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_availability_provider_idx ON public.professional_availability USING btree (provider_id, weekday, active);


--
-- Name: professional_booking_payment_intents_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_booking_payment_intents_customer_idx ON public.professional_booking_payment_intents USING btree (customer_id, created_at DESC);


--
-- Name: professional_booking_payment_intents_public_token_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX professional_booking_payment_intents_public_token_key ON public.professional_booking_payment_intents USING btree (public_token);


--
-- Name: professional_booking_payment_intents_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_booking_payment_intents_restaurant_idx ON public.professional_booking_payment_intents USING btree (restaurant_id, created_at DESC);


--
-- Name: professional_provider_services_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_provider_services_restaurant_idx ON public.professional_provider_services USING btree (restaurant_id);


--
-- Name: professional_providers_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_providers_restaurant_idx ON public.professional_providers USING btree (restaurant_id, active, sort_order);


--
-- Name: professional_services_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_services_restaurant_idx ON public.professional_services USING btree (restaurant_id, active, sort_order);


--
-- Name: professional_time_off_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX professional_time_off_provider_idx ON public.professional_time_off USING btree (provider_id, starts_at, ends_at);


--
-- Name: push_campaigns_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_campaigns_created_at_idx ON public.push_campaigns USING btree (created_at DESC);


--
-- Name: push_subscriptions_audience_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_audience_idx ON public.push_subscriptions USING btree (audience) WHERE enabled;


--
-- Name: push_subscriptions_business_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_business_type_idx ON public.push_subscriptions USING btree (business_type) WHERE enabled;


--
-- Name: push_subscriptions_context_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_context_restaurant_idx ON public.push_subscriptions USING btree (context_restaurant_id) WHERE enabled;


--
-- Name: push_subscriptions_geo_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_geo_idx ON public.push_subscriptions USING btree (country_code, city) WHERE enabled;


--
-- Name: push_subscriptions_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_restaurant_idx ON public.push_subscriptions USING btree (restaurant_id) WHERE enabled;


--
-- Name: push_subscriptions_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_user_idx ON public.push_subscriptions USING btree (user_id) WHERE enabled;


--
-- Name: restaurant_cash_movements_retail_online_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_cash_movements_retail_online_order_idx ON public.restaurant_cash_movements USING btree (retail_online_order_id) WHERE (retail_online_order_id IS NOT NULL);


--
-- Name: restaurant_cash_movements_retail_return_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_cash_movements_retail_return_idx ON public.restaurant_cash_movements USING btree (retail_return_id) WHERE (retail_return_id IS NOT NULL);


--
-- Name: restaurant_cash_movements_retail_sale_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_cash_movements_retail_sale_idx ON public.restaurant_cash_movements USING btree (retail_sale_id) WHERE (retail_sale_id IS NOT NULL);


--
-- Name: restaurant_categories_restaurant_slug_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX restaurant_categories_restaurant_slug_key ON public.restaurant_categories USING btree (restaurant_id, slug);


--
-- Name: restaurant_email_notification_log_restaurant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_email_notification_log_restaurant_created_idx ON public.restaurant_email_notification_log USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurant_inventory_items_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_inventory_items_restaurant_idx ON public.restaurant_inventory_items USING btree (restaurant_id, active);


--
-- Name: restaurant_inventory_movements_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_inventory_movements_item_idx ON public.restaurant_inventory_movements USING btree (inventory_item_id, created_at DESC);


--
-- Name: restaurant_inventory_movements_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_inventory_movements_restaurant_idx ON public.restaurant_inventory_movements USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurant_orders_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_created_idx ON public.restaurant_orders USING btree (created_at DESC);


--
-- Name: restaurant_orders_customer_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_customer_id_created_at_idx ON public.restaurant_orders USING btree (customer_id, created_at DESC);


--
-- Name: restaurant_orders_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_customer_id_idx ON public.restaurant_orders USING btree (customer_id);


--
-- Name: restaurant_orders_mp_payment_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX restaurant_orders_mp_payment_unique ON public.restaurant_orders USING btree (mp_payment_id) WHERE (mp_payment_id IS NOT NULL);


--
-- Name: restaurant_orders_mp_preference_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_mp_preference_idx ON public.restaurant_orders USING btree (mp_preference_id);


--
-- Name: restaurant_orders_operations_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_operations_idx ON public.restaurant_orders USING btree (restaurant_id, order_source, payment_status, status, created_at DESC);


--
-- Name: restaurant_orders_restaurant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_restaurant_created_idx ON public.restaurant_orders USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurant_orders_status_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_status_created_idx ON public.restaurant_orders USING btree (status, created_at DESC);


--
-- Name: restaurant_orders_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_orders_table_idx ON public.restaurant_orders USING btree (restaurant_table_id) WHERE (restaurant_table_id IS NOT NULL);


--
-- Name: restaurant_payment_methods_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_payment_methods_restaurant_idx ON public.restaurant_payment_methods USING btree (restaurant_id, active, sort_order);


--
-- Name: restaurant_payments_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_payments_restaurant_idx ON public.restaurant_payments USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurant_product_ingredients_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_product_ingredients_restaurant_idx ON public.restaurant_product_ingredients USING btree (restaurant_id);


--
-- Name: restaurant_promotions_code_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX restaurant_promotions_code_unique ON public.restaurant_promotions USING btree (restaurant_id, lower(code)) WHERE (code IS NOT NULL);


--
-- Name: restaurant_reviews_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_reviews_restaurant_idx ON public.restaurant_reviews USING btree (restaurant_id, published, created_at DESC);


--
-- Name: restaurant_subscription_history_restaurant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_subscription_history_restaurant_created_idx ON public.restaurant_subscription_history USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurant_tables_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_tables_restaurant_idx ON public.restaurant_tables USING btree (restaurant_id, sort_order, id);


--
-- Name: restaurant_whatsapp_message_log_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_whatsapp_message_log_order_idx ON public.restaurant_whatsapp_message_log USING btree (order_id);


--
-- Name: restaurant_whatsapp_message_log_restaurant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurant_whatsapp_message_log_restaurant_created_idx ON public.restaurant_whatsapp_message_log USING btree (restaurant_id, created_at DESC);


--
-- Name: restaurants_business_type_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_business_type_created_idx ON public.restaurants USING btree (business_type, created_at DESC, id DESC);


--
-- Name: restaurants_business_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_business_type_idx ON public.restaurants USING btree (business_type, active);


--
-- Name: restaurants_country_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_country_code_idx ON public.restaurants USING btree (country_code);


--
-- Name: restaurants_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_created_at_idx ON public.restaurants USING btree (created_at DESC);


--
-- Name: restaurants_flow_subscription_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_flow_subscription_idx ON public.restaurants USING btree (flow_subscription_id);


--
-- Name: restaurants_mp_subscription_id_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX restaurants_mp_subscription_id_uidx ON public.restaurants USING btree (mp_subscription_id) WHERE (mp_subscription_id IS NOT NULL);


--
-- Name: restaurants_search_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_search_trgm_idx ON public.restaurants USING gin ((((((((((COALESCE(name, ''::text) || ' '::text) || COALESCE(address, ''::text)) || ' '::text) || COALESCE(custom_domain, ''::text)) || ' '::text) || COALESCE(city, ''::text)) || ' '::text) || COALESCE(slug, ''::text))) public.gin_trgm_ops);


--
-- Name: restaurants_subscription_plan_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_subscription_plan_id_idx ON public.restaurants USING btree (subscription_plan_id);


--
-- Name: restaurants_subscription_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX restaurants_subscription_status_idx ON public.restaurants USING btree (subscription_status);


--
-- Name: retail_online_order_items_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_online_order_items_order_idx ON public.retail_online_order_items USING btree (order_id);


--
-- Name: retail_online_order_items_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_online_order_items_product_idx ON public.retail_online_order_items USING btree (product_id);


--
-- Name: retail_online_orders_code_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retail_online_orders_code_unique ON public.retail_online_orders USING btree (restaurant_id, order_code) WHERE (order_code IS NOT NULL);


--
-- Name: retail_online_orders_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_online_orders_customer_idx ON public.retail_online_orders USING btree (customer_id, created_at DESC) WHERE (customer_id IS NOT NULL);


--
-- Name: retail_online_orders_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_online_orders_expiry_idx ON public.retail_online_orders USING btree (reservation_expires_at) WHERE (status = 'pending_payment'::text);


--
-- Name: retail_online_orders_restaurant_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_online_orders_restaurant_date_idx ON public.retail_online_orders USING btree (restaurant_id, created_at DESC);


--
-- Name: retail_online_orders_tracking_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retail_online_orders_tracking_unique ON public.retail_online_orders USING btree (tracking_token);


--
-- Name: retail_products_barcode_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retail_products_barcode_unique ON public.retail_products USING btree (restaurant_id, barcode) WHERE ((barcode IS NOT NULL) AND (btrim(barcode) <> ''::text));


--
-- Name: retail_products_low_stock_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_products_low_stock_idx ON public.retail_products USING btree (restaurant_id, current_stock, minimum_stock) WHERE (active = true);


--
-- Name: retail_products_restaurant_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_products_restaurant_active_idx ON public.retail_products USING btree (restaurant_id, active, name);


--
-- Name: retail_products_sku_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retail_products_sku_unique ON public.retail_products USING btree (restaurant_id, sku) WHERE ((sku IS NOT NULL) AND (btrim(sku) <> ''::text));


--
-- Name: retail_purchase_items_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_purchase_items_product_idx ON public.retail_purchase_items USING btree (product_id);


--
-- Name: retail_purchase_items_purchase_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_purchase_items_purchase_idx ON public.retail_purchase_items USING btree (purchase_id);


--
-- Name: retail_purchases_restaurant_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_purchases_restaurant_date_idx ON public.retail_purchases USING btree (restaurant_id, created_at DESC);


--
-- Name: retail_return_items_return_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_return_items_return_idx ON public.retail_return_items USING btree (return_id);


--
-- Name: retail_return_items_sale_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_return_items_sale_item_idx ON public.retail_return_items USING btree (sale_item_id);


--
-- Name: retail_returns_restaurant_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_returns_restaurant_date_idx ON public.retail_returns USING btree (restaurant_id, created_at DESC);


--
-- Name: retail_returns_sale_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_returns_sale_idx ON public.retail_returns USING btree (sale_id, created_at DESC);


--
-- Name: retail_sale_items_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_sale_items_product_idx ON public.retail_sale_items USING btree (product_id);


--
-- Name: retail_sale_items_sale_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_sale_items_sale_idx ON public.retail_sale_items USING btree (sale_id);


--
-- Name: retail_sales_cash_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_sales_cash_session_idx ON public.retail_sales USING btree (cash_session_id, created_at DESC);


--
-- Name: retail_sales_code_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retail_sales_code_unique ON public.retail_sales USING btree (restaurant_id, sale_code) WHERE (sale_code IS NOT NULL);


--
-- Name: retail_sales_restaurant_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_sales_restaurant_date_idx ON public.retail_sales USING btree (restaurant_id, created_at DESC);


--
-- Name: retail_stock_movements_product_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_stock_movements_product_date_idx ON public.retail_stock_movements USING btree (product_id, created_at DESC);


--
-- Name: retail_stock_movements_restaurant_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_stock_movements_restaurant_date_idx ON public.retail_stock_movements USING btree (restaurant_id, created_at DESC);


--
-- Name: retail_suppliers_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retail_suppliers_restaurant_idx ON public.retail_suppliers USING btree (restaurant_id, active, name);


--
-- Name: streaming_accounts_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_accounts_restaurant_idx ON public.streaming_accounts USING btree (restaurant_id, platform_id, active);


--
-- Name: streaming_customers_phone_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_customers_phone_idx ON public.streaming_customers USING btree (restaurant_id, phone);


--
-- Name: streaming_customers_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_customers_restaurant_idx ON public.streaming_customers USING btree (restaurant_id, active, full_name);


--
-- Name: streaming_orders_customer_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_orders_customer_created_idx ON public.streaming_orders USING btree (customer_user_id, created_at DESC);


--
-- Name: streaming_orders_payment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_orders_payment_idx ON public.streaming_orders USING btree (payment_status, created_at DESC);


--
-- Name: streaming_orders_restaurant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_orders_restaurant_created_idx ON public.streaming_orders USING btree (restaurant_id, created_at DESC);


--
-- Name: streaming_platforms_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_platforms_restaurant_idx ON public.streaming_platforms USING btree (restaurant_id, active, sort_order);


--
-- Name: streaming_platforms_restaurant_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX streaming_platforms_restaurant_name_uq ON public.streaming_platforms USING btree (restaurant_id, lower(name));


--
-- Name: streaming_reminder_logs_once_per_day; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX streaming_reminder_logs_once_per_day ON public.streaming_reminder_logs USING btree (restaurant_id, subscription_id, reminder_type, opened_date);


--
-- Name: streaming_reminder_logs_restaurant_opened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_reminder_logs_restaurant_opened_at ON public.streaming_reminder_logs USING btree (restaurant_id, opened_at DESC);


--
-- Name: streaming_reminder_logs_subscription_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_reminder_logs_subscription_idx ON public.streaming_reminder_logs USING btree (subscription_id);


--
-- Name: streaming_renewals_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_renewals_restaurant_idx ON public.streaming_renewals USING btree (restaurant_id, created_at DESC);


--
-- Name: streaming_renewals_subscription_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_renewals_subscription_idx ON public.streaming_renewals USING btree (subscription_id, created_at DESC);


--
-- Name: streaming_subscriptions_account_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_subscriptions_account_idx ON public.streaming_subscriptions USING btree (restaurant_id, account_id, status);


--
-- Name: streaming_subscriptions_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_subscriptions_customer_idx ON public.streaming_subscriptions USING btree (restaurant_id, customer_id);


--
-- Name: streaming_subscriptions_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_subscriptions_order_idx ON public.streaming_subscriptions USING btree (order_id);


--
-- Name: streaming_subscriptions_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX streaming_subscriptions_restaurant_idx ON public.streaming_subscriptions USING btree (restaurant_id, status, expires_at);


--
-- Name: subscription_payment_methods_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payment_methods_restaurant_idx ON public.subscription_payment_methods USING btree (restaurant_id, active, created_at DESC);


--
-- Name: subscription_payments_one_pending_per_restaurant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscription_payments_one_pending_per_restaurant ON public.subscription_payments USING btree (restaurant_id) WHERE (status = 'pending'::text);


--
-- Name: subscription_payments_provider_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payments_provider_order_idx ON public.subscription_payments USING btree (provider, provider_order_id) WHERE (provider_order_id IS NOT NULL);


--
-- Name: subscription_payments_provider_subscription_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payments_provider_subscription_idx ON public.subscription_payments USING btree (provider, provider_subscription_id);


--
-- Name: subscription_payments_provider_token_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payments_provider_token_idx ON public.subscription_payments USING btree (provider, provider_token);


--
-- Name: subscription_plans_business_type_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_plans_business_type_active_idx ON public.subscription_plans USING btree (business_type, active, amount);


--
-- Name: subscription_plans_one_default_trial_per_business_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscription_plans_one_default_trial_per_business_idx ON public.subscription_plans USING btree (business_type) WHERE (is_default_trial = true);


--
-- Name: user_issue_reports_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_issue_reports_restaurant_idx ON public.user_issue_reports USING btree (restaurant_id, created_at DESC);


--
-- Name: user_issue_reports_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_issue_reports_status_idx ON public.user_issue_reports USING btree (status, created_at DESC);


--
-- Name: veripagos_transactions_auto_check_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX veripagos_transactions_auto_check_idx ON public.veripagos_transactions USING btree (status, scope, next_check_at, created_at) WHERE ((scope = 'subscription'::text) AND (status = 'pending'::text));


--
-- Name: veripagos_transactions_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX veripagos_transactions_order_idx ON public.veripagos_transactions USING btree (order_id) WHERE (order_id IS NOT NULL);


--
-- Name: veripagos_transactions_restaurant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX veripagos_transactions_restaurant_idx ON public.veripagos_transactions USING btree (restaurant_id, created_at DESC);


--
-- Name: veripagos_transactions_retail_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX veripagos_transactions_retail_order_idx ON public.veripagos_transactions USING btree (retail_order_id) WHERE (retail_order_id IS NOT NULL);


--
-- Name: veripagos_transactions_subscription_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX veripagos_transactions_subscription_idx ON public.veripagos_transactions USING btree (subscription_payment_id) WHERE (subscription_payment_id IS NOT NULL);


--
-- Name: restaurant_orders auto_prepare_local_kitchen_order_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER auto_prepare_local_kitchen_order_trigger AFTER INSERT OR UPDATE OF payment_status, payment_method, order_source ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.auto_prepare_local_kitchen_order();


--
-- Name: restaurant_orders enforce_kitchen_order_transition_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_kitchen_order_transition_trigger BEFORE UPDATE OF status ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.enforce_kitchen_order_transition();


--
-- Name: restaurant_inventory_movements inventory_movement_apply_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inventory_movement_apply_stock BEFORE INSERT ON public.restaurant_inventory_movements FOR EACH ROW EXECUTE FUNCTION public.apply_inventory_movement();


--
-- Name: restaurant_orders log_initial_order_status_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER log_initial_order_status_trigger AFTER INSERT ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.log_initial_order_status();


--
-- Name: restaurant_orders process_order_transition_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER process_order_transition_trigger BEFORE UPDATE OF status ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.process_order_transition();


--
-- Name: subscription_plans protect_default_trial_plan_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_default_trial_plan_trigger BEFORE INSERT OR UPDATE ON public.subscription_plans FOR EACH ROW EXECUTE FUNCTION public.protect_default_trial_plan();


--
-- Name: restaurant_orders protect_order_intake_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_order_intake_trigger BEFORE INSERT OR UPDATE OF payment_status, payment_method, order_source ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.protect_order_intake();


--
-- Name: streaming_subscriptions streaming_subscription_capacity_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER streaming_subscription_capacity_guard BEFORE INSERT OR UPDATE OF restaurant_id, platform_id, account_id, starts_at, expires_at, status ON public.streaming_subscriptions FOR EACH ROW EXECUTE FUNCTION public.streaming_validate_subscription_assignment();


--
-- Name: streaming_subscriptions streaming_subscription_sync_order; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER streaming_subscription_sync_order AFTER INSERT OR UPDATE OF account_id, delivery_status, status ON public.streaming_subscriptions FOR EACH ROW WHEN ((new.order_id IS NOT NULL)) EXECUTE FUNCTION public.streaming_sync_order_status();


--
-- Name: restaurant_orders sync_order_payment_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_order_payment_trigger AFTER INSERT OR UPDATE OF payment_method, payment_status, refund_status, total, mp_payment_id ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION private.sync_order_payment();


--
-- Name: admin_users trg_admin_account_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_admin_account_type AFTER INSERT OR DELETE OR UPDATE ON public.admin_users FOR EACH ROW EXECUTE FUNCTION public.sync_admin_account_type();


--
-- Name: customer_profiles trg_enforce_customer_profile_account_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_customer_profile_account_type BEFORE INSERT OR UPDATE ON public.customer_profiles FOR EACH ROW EXECUTE FUNCTION public.enforce_customer_profile_account_type();


--
-- Name: restaurants trg_enforce_restaurant_creator_account_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_restaurant_creator_account_type BEFORE INSERT ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_creator_account_type();


--
-- Name: restaurant_staff trg_enforce_restaurant_staff_account_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_restaurant_staff_account_type BEFORE INSERT OR UPDATE OF user_id ON public.restaurant_staff FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_staff_account_type();


--
-- Name: restaurants trg_initialize_restaurant_trial; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_initialize_restaurant_trial BEFORE INSERT ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.initialize_restaurant_trial();


--
-- Name: restaurant_staff trg_new_restaurant_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_new_restaurant_email AFTER INSERT ON public.restaurant_staff FOR EACH ROW EXECUTE FUNCTION public.notify_new_restaurant_by_email();


--
-- Name: professional_appointments trg_professional_appointments_mp_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_professional_appointments_mp_source BEFORE INSERT OR UPDATE OF mp_preference_id ON public.professional_appointments FOR EACH ROW EXECUTE FUNCTION public.mark_mp_credential_source_from_override();


--
-- Name: professional_booking_payment_intents trg_professional_intents_mp_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_professional_intents_mp_source BEFORE INSERT OR UPDATE OF mp_preference_id ON public.professional_booking_payment_intents FOR EACH ROW EXECUTE FUNCTION public.mark_mp_credential_source_from_override();


--
-- Name: restaurant_orders trg_restaurant_orders_mp_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_restaurant_orders_mp_source BEFORE INSERT OR UPDATE OF mp_preference_id ON public.restaurant_orders FOR EACH ROW EXECUTE FUNCTION public.mark_mp_credential_source_from_override();


--
-- Name: restaurants trg_restaurants_plan_business_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_restaurants_plan_business_type BEFORE INSERT OR UPDATE OF subscription_plan_id, business_type ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_plan_business_type();


--
-- Name: retail_online_orders trg_retail_orders_mp_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_retail_orders_mp_source BEFORE INSERT OR UPDATE OF mp_preference_id ON public.retail_online_orders FOR EACH ROW EXECUTE FUNCTION public.mark_mp_credential_source_from_override();


--
-- Name: restaurant_staff trg_staff_account_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_staff_account_type AFTER INSERT OR DELETE OR UPDATE ON public.restaurant_staff FOR EACH ROW EXECUTE FUNCTION public.sync_staff_account_type();


--
-- Name: streaming_orders trg_streaming_orders_mp_source; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_streaming_orders_mp_source BEFORE INSERT OR UPDATE OF mp_preference_id ON public.streaming_orders FOR EACH ROW EXECUTE FUNCTION public.mark_mp_credential_source_from_override();


--
-- Name: subscription_payments trg_subscription_payments_business_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_subscription_payments_business_type BEFORE INSERT OR UPDATE OF plan_id, restaurant_id ON public.subscription_payments FOR EACH ROW EXECUTE FUNCTION public.enforce_subscription_payment_business_type();


--
-- Name: subscription_payment_settings trg_sync_demo_api_defaults_after_global_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_demo_api_defaults_after_global_change AFTER INSERT OR UPDATE OF public_key, access_token, veripagos_basic_username, veripagos_basic_password, veripagos_secret_key, veripagos_enabled, veripagos_vigencia ON public.subscription_payment_settings FOR EACH STATEMENT EXECUTE FUNCTION public.sync_demo_api_defaults_after_global_change();


--
-- Name: restaurants trg_sync_demo_api_defaults_on_business_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_demo_api_defaults_on_business_change AFTER INSERT OR UPDATE OF is_demo, use_demo_api_defaults, country_code ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.sync_demo_api_defaults_on_business_change();


--
-- Name: admin_client_preview_sessions admin_client_preview_sessions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_client_preview_sessions
    ADD CONSTRAINT admin_client_preview_sessions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: admin_client_preview_sessions admin_client_preview_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_client_preview_sessions
    ADD CONSTRAINT admin_client_preview_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: admin_users admin_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users
    ADD CONSTRAINT admin_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: app_errors app_errors_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_errors
    ADD CONSTRAINT app_errors_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE SET NULL;


--
-- Name: app_events app_events_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_events
    ADD CONSTRAINT app_events_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id) ON DELETE SET NULL;


--
-- Name: app_events app_events_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_events
    ADD CONSTRAINT app_events_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE SET NULL;


--
-- Name: business_payment_test_overrides business_payment_test_overrides_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_payment_test_overrides
    ADD CONSTRAINT business_payment_test_overrides_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: business_payment_test_overrides business_payment_test_overrides_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_payment_test_overrides
    ADD CONSTRAINT business_payment_test_overrides_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: customer_profiles customer_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_profiles
    ADD CONSTRAINT customer_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payment_proofs payment_proofs_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payment_proofs payment_proofs_method_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_method_id_fkey FOREIGN KEY (method_id) REFERENCES public.restaurant_payment_methods(id) ON DELETE SET NULL;


--
-- Name: payment_proofs payment_proofs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: payment_proofs payment_proofs_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: payment_proofs payment_proofs_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_proofs
    ADD CONSTRAINT payment_proofs_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: professional_appointments professional_appointments_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: professional_appointments professional_appointments_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.professional_providers(id) ON DELETE RESTRICT;


--
-- Name: professional_appointments professional_appointments_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_appointments professional_appointments_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_appointments
    ADD CONSTRAINT professional_appointments_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.professional_services(id) ON DELETE RESTRICT;


--
-- Name: professional_availability professional_availability_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_availability
    ADD CONSTRAINT professional_availability_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.professional_providers(id) ON DELETE CASCADE;


--
-- Name: professional_availability professional_availability_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_availability
    ADD CONSTRAINT professional_availability_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.professional_appointments(id) ON DELETE SET NULL;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_payment_method_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_payment_method_id_fkey FOREIGN KEY (payment_method_id) REFERENCES public.restaurant_payment_methods(id) ON DELETE SET NULL;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.professional_providers(id) ON DELETE RESTRICT;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_booking_payment_intents
    ADD CONSTRAINT professional_booking_payment_intents_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.professional_services(id) ON DELETE RESTRICT;


--
-- Name: professional_provider_services professional_provider_services_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_provider_services
    ADD CONSTRAINT professional_provider_services_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.professional_providers(id) ON DELETE CASCADE;


--
-- Name: professional_provider_services professional_provider_services_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_provider_services
    ADD CONSTRAINT professional_provider_services_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_provider_services professional_provider_services_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_provider_services
    ADD CONSTRAINT professional_provider_services_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.professional_services(id) ON DELETE CASCADE;


--
-- Name: professional_providers professional_providers_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_providers
    ADD CONSTRAINT professional_providers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_providers professional_providers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_providers
    ADD CONSTRAINT professional_providers_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: professional_services professional_services_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_services
    ADD CONSTRAINT professional_services_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: professional_time_off professional_time_off_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_time_off
    ADD CONSTRAINT professional_time_off_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.professional_providers(id) ON DELETE CASCADE;


--
-- Name: professional_time_off professional_time_off_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_time_off
    ADD CONSTRAINT professional_time_off_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: push_campaigns push_campaigns_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_campaigns
    ADD CONSTRAINT push_campaigns_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE SET NULL;


--
-- Name: push_subscriptions push_subscriptions_context_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_context_restaurant_id_fkey FOREIGN KEY (context_restaurant_id) REFERENCES public.restaurants(id) ON DELETE SET NULL;


--
-- Name: push_subscriptions push_subscriptions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: push_subscriptions push_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_retail_online_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_retail_online_order_id_fkey FOREIGN KEY (retail_online_order_id) REFERENCES public.retail_online_orders(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_retail_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_retail_return_id_fkey FOREIGN KEY (retail_return_id) REFERENCES public.retail_returns(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_retail_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_retail_sale_id_fkey FOREIGN KEY (retail_sale_id) REFERENCES public.retail_sales(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_movements restaurant_cash_movements_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_movements
    ADD CONSTRAINT restaurant_cash_movements_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.restaurant_cash_sessions(id) ON DELETE CASCADE;


--
-- Name: restaurant_cash_sessions restaurant_cash_sessions_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_sessions
    ADD CONSTRAINT restaurant_cash_sessions_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_sessions restaurant_cash_sessions_opened_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_sessions
    ADD CONSTRAINT restaurant_cash_sessions_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_cash_sessions restaurant_cash_sessions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_cash_sessions
    ADD CONSTRAINT restaurant_cash_sessions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_categories restaurant_categories_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_categories
    ADD CONSTRAINT restaurant_categories_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_email_notification_log restaurant_email_notification_log_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_email_notification_log
    ADD CONSTRAINT restaurant_email_notification_log_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_inventory_items restaurant_inventory_items_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_items
    ADD CONSTRAINT restaurant_inventory_items_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_inventory_movements restaurant_inventory_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_movements
    ADD CONSTRAINT restaurant_inventory_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_inventory_movements restaurant_inventory_movements_inventory_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_movements
    ADD CONSTRAINT restaurant_inventory_movements_inventory_item_id_fkey FOREIGN KEY (inventory_item_id) REFERENCES public.restaurant_inventory_items(id) ON DELETE CASCADE;


--
-- Name: restaurant_inventory_movements restaurant_inventory_movements_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_inventory_movements
    ADD CONSTRAINT restaurant_inventory_movements_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_order_status_events restaurant_order_status_events_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_order_status_events
    ADD CONSTRAINT restaurant_order_status_events_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_order_status_events restaurant_order_status_events_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_order_status_events
    ADD CONSTRAINT restaurant_order_status_events_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: restaurant_order_status_events restaurant_order_status_events_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_order_status_events
    ADD CONSTRAINT restaurant_order_status_events_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_orders restaurant_orders_assigned_courier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_assigned_courier_id_fkey FOREIGN KEY (assigned_courier_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_orders restaurant_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_orders restaurant_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: restaurant_orders restaurant_orders_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_orders restaurant_orders_restaurant_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_orders
    ADD CONSTRAINT restaurant_orders_restaurant_table_id_fkey FOREIGN KEY (restaurant_table_id) REFERENCES public.restaurant_tables(id) ON DELETE SET NULL;


--
-- Name: restaurant_payment_connections restaurant_payment_connections_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payment_connections
    ADD CONSTRAINT restaurant_payment_connections_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_payment_methods restaurant_payment_methods_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payment_methods
    ADD CONSTRAINT restaurant_payment_methods_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_payments restaurant_payments_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payments
    ADD CONSTRAINT restaurant_payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: restaurant_payments restaurant_payments_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_payments
    ADD CONSTRAINT restaurant_payments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_ingredients restaurant_product_ingredients_inventory_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_ingredients
    ADD CONSTRAINT restaurant_product_ingredients_inventory_item_id_fkey FOREIGN KEY (inventory_item_id) REFERENCES public.restaurant_inventory_items(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_ingredients restaurant_product_ingredients_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_ingredients
    ADD CONSTRAINT restaurant_product_ingredients_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.restaurant_products(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_ingredients restaurant_product_ingredients_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_ingredients
    ADD CONSTRAINT restaurant_product_ingredients_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_option_groups restaurant_product_option_groups_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_option_groups
    ADD CONSTRAINT restaurant_product_option_groups_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.restaurant_products(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_option_groups restaurant_product_option_groups_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_option_groups
    ADD CONSTRAINT restaurant_product_option_groups_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_options restaurant_product_options_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_options
    ADD CONSTRAINT restaurant_product_options_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.restaurant_product_option_groups(id) ON DELETE CASCADE;


--
-- Name: restaurant_product_options restaurant_product_options_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_product_options
    ADD CONSTRAINT restaurant_product_options_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_products restaurant_products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_products
    ADD CONSTRAINT restaurant_products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.restaurant_categories(id) ON DELETE SET NULL;


--
-- Name: restaurant_products restaurant_products_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_products
    ADD CONSTRAINT restaurant_products_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_promotion_products restaurant_promotion_products_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotion_products
    ADD CONSTRAINT restaurant_promotion_products_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.restaurant_products(id) ON DELETE CASCADE;


--
-- Name: restaurant_promotion_products restaurant_promotion_products_promotion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotion_products
    ADD CONSTRAINT restaurant_promotion_products_promotion_id_fkey FOREIGN KEY (promotion_id) REFERENCES public.restaurant_promotions(id) ON DELETE CASCADE;


--
-- Name: restaurant_promotion_products restaurant_promotion_products_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotion_products
    ADD CONSTRAINT restaurant_promotion_products_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_promotions restaurant_promotions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_promotions
    ADD CONSTRAINT restaurant_promotions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_reviews restaurant_reviews_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_reviews
    ADD CONSTRAINT restaurant_reviews_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: restaurant_reviews restaurant_reviews_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_reviews
    ADD CONSTRAINT restaurant_reviews_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: restaurant_reviews restaurant_reviews_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_reviews
    ADD CONSTRAINT restaurant_reviews_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_staff restaurant_staff_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_staff
    ADD CONSTRAINT restaurant_staff_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_staff restaurant_staff_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_staff
    ADD CONSTRAINT restaurant_staff_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: restaurant_subscription_history restaurant_subscription_history_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_subscription_history
    ADD CONSTRAINT restaurant_subscription_history_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_tables restaurant_tables_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_tables
    ADD CONSTRAINT restaurant_tables_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_veripagos_connections restaurant_veripagos_connections_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_veripagos_connections
    ADD CONSTRAINT restaurant_veripagos_connections_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_whatsapp_automations restaurant_whatsapp_automations_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_automations
    ADD CONSTRAINT restaurant_whatsapp_automations_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_whatsapp_connections restaurant_whatsapp_connections_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_connections
    ADD CONSTRAINT restaurant_whatsapp_connections_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_whatsapp_message_log restaurant_whatsapp_message_log_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_message_log
    ADD CONSTRAINT restaurant_whatsapp_message_log_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE SET NULL;


--
-- Name: restaurant_whatsapp_message_log restaurant_whatsapp_message_log_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_whatsapp_message_log
    ADD CONSTRAINT restaurant_whatsapp_message_log_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurants restaurants_country_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_country_code_fkey FOREIGN KEY (country_code) REFERENCES public.platform_countries(code);


--
-- Name: restaurants restaurants_subscription_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_subscription_plan_id_fkey FOREIGN KEY (subscription_plan_id) REFERENCES public.subscription_plans(id) ON DELETE SET NULL;


--
-- Name: restaurants restaurants_trial_intended_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_trial_intended_plan_id_fkey FOREIGN KEY (trial_intended_plan_id) REFERENCES public.subscription_plans(id) ON DELETE SET NULL;


--
-- Name: retail_online_order_items retail_online_order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_order_items
    ADD CONSTRAINT retail_online_order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.retail_online_orders(id) ON DELETE CASCADE;


--
-- Name: retail_online_order_items retail_online_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_order_items
    ADD CONSTRAINT retail_online_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE RESTRICT;


--
-- Name: retail_online_orders retail_online_orders_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_orders
    ADD CONSTRAINT retail_online_orders_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.restaurant_cash_sessions(id) ON DELETE SET NULL;


--
-- Name: retail_online_orders retail_online_orders_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_online_orders
    ADD CONSTRAINT retail_online_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_products retail_products_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_products
    ADD CONSTRAINT retail_products_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_purchase_items retail_purchase_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchase_items
    ADD CONSTRAINT retail_purchase_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE RESTRICT;


--
-- Name: retail_purchase_items retail_purchase_items_purchase_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchase_items
    ADD CONSTRAINT retail_purchase_items_purchase_id_fkey FOREIGN KEY (purchase_id) REFERENCES public.retail_purchases(id) ON DELETE CASCADE;


--
-- Name: retail_purchases retail_purchases_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchases
    ADD CONSTRAINT retail_purchases_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_purchases retail_purchases_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_purchases
    ADD CONSTRAINT retail_purchases_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.retail_suppliers(id) ON DELETE SET NULL;


--
-- Name: retail_return_items retail_return_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_return_items
    ADD CONSTRAINT retail_return_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE RESTRICT;


--
-- Name: retail_return_items retail_return_items_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_return_items
    ADD CONSTRAINT retail_return_items_return_id_fkey FOREIGN KEY (return_id) REFERENCES public.retail_returns(id) ON DELETE CASCADE;


--
-- Name: retail_return_items retail_return_items_sale_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_return_items
    ADD CONSTRAINT retail_return_items_sale_item_id_fkey FOREIGN KEY (sale_item_id) REFERENCES public.retail_sale_items(id) ON DELETE RESTRICT;


--
-- Name: retail_returns retail_returns_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_returns
    ADD CONSTRAINT retail_returns_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.restaurant_cash_sessions(id) ON DELETE SET NULL;


--
-- Name: retail_returns retail_returns_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_returns
    ADD CONSTRAINT retail_returns_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_returns retail_returns_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_returns
    ADD CONSTRAINT retail_returns_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.retail_sales(id) ON DELETE RESTRICT;


--
-- Name: retail_sale_items retail_sale_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sale_items
    ADD CONSTRAINT retail_sale_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE RESTRICT;


--
-- Name: retail_sale_items retail_sale_items_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sale_items
    ADD CONSTRAINT retail_sale_items_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.retail_sales(id) ON DELETE CASCADE;


--
-- Name: retail_sales retail_sales_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sales
    ADD CONSTRAINT retail_sales_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.restaurant_cash_sessions(id) ON DELETE SET NULL;


--
-- Name: retail_sales retail_sales_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_sales
    ADD CONSTRAINT retail_sales_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_stock_movements retail_stock_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_stock_movements
    ADD CONSTRAINT retail_stock_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE CASCADE;


--
-- Name: retail_stock_movements retail_stock_movements_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_stock_movements
    ADD CONSTRAINT retail_stock_movements_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: retail_suppliers retail_suppliers_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retail_suppliers
    ADD CONSTRAINT retail_suppliers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: site_links site_links_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_links
    ADD CONSTRAINT site_links_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: streaming_accounts streaming_accounts_platform_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_platform_id_fkey FOREIGN KEY (platform_id) REFERENCES public.streaming_platforms(id) ON DELETE RESTRICT;


--
-- Name: streaming_accounts streaming_accounts_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_accounts streaming_accounts_tenant_platform_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_accounts
    ADD CONSTRAINT streaming_accounts_tenant_platform_fk FOREIGN KEY (restaurant_id, platform_id) REFERENCES public.streaming_platforms(restaurant_id, id) ON DELETE RESTRICT;


--
-- Name: streaming_customers streaming_customers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_customers
    ADD CONSTRAINT streaming_customers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: streaming_customers streaming_customers_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_customers
    ADD CONSTRAINT streaming_customers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_orders streaming_orders_customer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_orders
    ADD CONSTRAINT streaming_orders_customer_user_id_fkey FOREIGN KEY (customer_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: streaming_orders streaming_orders_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_orders
    ADD CONSTRAINT streaming_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_platforms streaming_platforms_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_platforms
    ADD CONSTRAINT streaming_platforms_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_reminder_logs streaming_reminder_logs_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_reminder_logs
    ADD CONSTRAINT streaming_reminder_logs_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_reminder_logs streaming_reminder_logs_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_reminder_logs
    ADD CONSTRAINT streaming_reminder_logs_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.streaming_subscriptions(id) ON DELETE CASCADE;


--
-- Name: streaming_renewals streaming_renewals_renewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_renewals
    ADD CONSTRAINT streaming_renewals_renewed_by_fkey FOREIGN KEY (renewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: streaming_renewals streaming_renewals_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_renewals
    ADD CONSTRAINT streaming_renewals_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_renewals streaming_renewals_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_renewals
    ADD CONSTRAINT streaming_renewals_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.streaming_subscriptions(id) ON DELETE CASCADE;


--
-- Name: streaming_renewals streaming_renewals_tenant_subscription_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_renewals
    ADD CONSTRAINT streaming_renewals_tenant_subscription_fk FOREIGN KEY (restaurant_id, subscription_id) REFERENCES public.streaming_subscriptions(restaurant_id, id) ON DELETE CASCADE;


--
-- Name: streaming_subscriptions streaming_subscriptions_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.streaming_accounts(id) ON DELETE SET NULL;


--
-- Name: streaming_subscriptions streaming_subscriptions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: streaming_subscriptions streaming_subscriptions_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.streaming_customers(id) ON DELETE RESTRICT;


--
-- Name: streaming_subscriptions streaming_subscriptions_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.streaming_orders(id) ON DELETE SET NULL;


--
-- Name: streaming_subscriptions streaming_subscriptions_platform_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_platform_id_fkey FOREIGN KEY (platform_id) REFERENCES public.streaming_platforms(id) ON DELETE RESTRICT;


--
-- Name: streaming_subscriptions streaming_subscriptions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: streaming_subscriptions streaming_subscriptions_tenant_account_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_tenant_account_fk FOREIGN KEY (restaurant_id, account_id) REFERENCES public.streaming_accounts(restaurant_id, id) ON DELETE SET NULL;


--
-- Name: streaming_subscriptions streaming_subscriptions_tenant_customer_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_tenant_customer_fk FOREIGN KEY (restaurant_id, customer_id) REFERENCES public.streaming_customers(restaurant_id, id) ON DELETE RESTRICT;


--
-- Name: streaming_subscriptions streaming_subscriptions_tenant_platform_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streaming_subscriptions
    ADD CONSTRAINT streaming_subscriptions_tenant_platform_fk FOREIGN KEY (restaurant_id, platform_id) REFERENCES public.streaming_platforms(restaurant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_payment_methods subscription_payment_methods_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_methods
    ADD CONSTRAINT subscription_payment_methods_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: subscription_payment_methods subscription_payment_methods_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payment_methods
    ADD CONSTRAINT subscription_payment_methods_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: subscription_payments subscription_payments_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id);


--
-- Name: subscription_payments subscription_payments_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: table_qr_push_subscriptions table_qr_push_subscriptions_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.table_qr_push_subscriptions
    ADD CONSTRAINT table_qr_push_subscriptions_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: user_issue_reports user_issue_reports_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_issue_reports
    ADD CONSTRAINT user_issue_reports_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE SET NULL;


--
-- Name: user_profiles user_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: veripagos_transactions veripagos_transactions_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;


--
-- Name: veripagos_transactions veripagos_transactions_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: veripagos_transactions veripagos_transactions_retail_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_retail_order_id_fkey FOREIGN KEY (retail_order_id) REFERENCES public.retail_online_orders(id) ON DELETE CASCADE;


--
-- Name: veripagos_transactions veripagos_transactions_subscription_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.veripagos_transactions
    ADD CONSTRAINT veripagos_transactions_subscription_payment_id_fkey FOREIGN KEY (subscription_payment_id) REFERENCES public.subscription_payments(id) ON DELETE CASCADE;


--
-- Name: site_links Admins can delete site links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete site links" ON public.site_links FOR DELETE TO authenticated USING (public.is_site_admin());


--
-- Name: site_links Admins can insert site links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert site links" ON public.site_links FOR INSERT TO authenticated WITH CHECK (public.is_site_admin());


--
-- Name: site_links Admins can update site links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update site links" ON public.site_links FOR UPDATE TO authenticated USING (public.is_site_admin()) WITH CHECK (public.is_site_admin());


--
-- Name: site_links Public can read active site links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can read active site links" ON public.site_links FOR SELECT TO authenticated, anon USING (((is_active = true) OR public.is_site_admin()));


--
-- Name: account_profile_archive; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.account_profile_archive ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_users admin can view own admin row; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin can view own admin row" ON public.admin_users FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: admin_client_preview_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_client_preview_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_users admins can view admin directory; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins can view admin directory" ON public.admin_users FOR SELECT TO authenticated USING ((( SELECT public.current_account_role() AS current_account_role) = 'admin'::text));


--
-- Name: user_profiles admins manage profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins manage profiles" ON public.user_profiles TO authenticated USING (public.is_site_admin()) WITH CHECK (public.is_site_admin());


--
-- Name: account_profile_archive admins read account profile archive; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins read account profile archive" ON public.account_profile_archive FOR SELECT TO authenticated USING (public.is_site_admin());


--
-- Name: push_campaigns admins read push campaigns; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins read push campaigns" ON public.push_campaigns FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: restaurant_payment_connections admins_manage_payment_connections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_manage_payment_connections ON public.restaurant_payment_connections TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: subscription_plans anon_read_active_subscription_plans; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anon_read_active_subscription_plans ON public.subscription_plans FOR SELECT TO anon USING ((active = true));


--
-- Name: app_errors; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_errors ENABLE ROW LEVEL SECURITY;

--
-- Name: app_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_events ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_plans authenticated_read_active_subscription_plans; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY authenticated_read_active_subscription_plans ON public.subscription_plans FOR SELECT TO authenticated USING (((active = true) OR (EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid())))));


--
-- Name: business_payment_test_overrides; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_payment_test_overrides ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_countries countries admin manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "countries admin manage" ON public.platform_countries TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: platform_countries countries public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "countries public read" ON public.platform_countries FOR SELECT TO authenticated, anon USING ((active = true));


--
-- Name: customer_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_signup_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_signup_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_orders customers create own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers create own orders" ON public.restaurant_orders FOR INSERT TO authenticated WITH CHECK ((customer_id = auth.uid()));


--
-- Name: payment_proofs customers create proofs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers create proofs" ON public.payment_proofs FOR INSERT TO authenticated WITH CHECK ((customer_id = ( SELECT auth.uid() AS uid)));


--
-- Name: restaurant_reviews customers create reviews; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers create reviews" ON public.restaurant_reviews FOR INSERT TO authenticated WITH CHECK (((customer_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.restaurant_orders o
  WHERE ((o.id = restaurant_reviews.order_id) AND (o.restaurant_id = o.restaurant_id) AND (o.customer_id = ( SELECT auth.uid() AS uid)) AND (o.status = 'entregado'::text))))));


--
-- Name: customer_profiles customers insert own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers insert own profile" ON public.customer_profiles FOR INSERT TO authenticated WITH CHECK (((user_id = auth.uid()) AND public.can_register_customer()));


--
-- Name: restaurant_orders customers read own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers read own orders" ON public.restaurant_orders FOR SELECT TO authenticated USING ((customer_id = auth.uid()));


--
-- Name: restaurant_payments customers read own payments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers read own payments" ON public.restaurant_payments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_orders o
  WHERE ((o.id = restaurant_payments.order_id) AND (o.customer_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: customer_profiles customers read own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers read own profile" ON public.customer_profiles FOR SELECT TO authenticated USING (((user_id = auth.uid()) AND (public.current_account_role() = 'customer'::text)));


--
-- Name: payment_proofs customers read proofs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers read proofs" ON public.payment_proofs FOR SELECT TO authenticated USING (((customer_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.can_manage_restaurant(payment_proofs.restaurant_id) AS can_manage_restaurant) OR ( SELECT public.is_site_admin() AS is_site_admin)));


--
-- Name: customer_profiles customers update own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers update own profile" ON public.customer_profiles FOR UPDATE TO authenticated USING (((user_id = auth.uid()) AND (public.current_account_role() = 'customer'::text))) WITH CHECK (((user_id = auth.uid()) AND (public.current_account_role() = 'customer'::text)));


--
-- Name: restaurant_reviews customers update own reviews; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "customers update own reviews" ON public.restaurant_reviews FOR UPDATE TO authenticated USING ((customer_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((customer_id = ( SELECT auth.uid() AS uid)));


--
-- Name: restaurant_staff managers manage staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "managers manage staff" ON public.restaurant_staff TO authenticated USING (public.is_system_manager()) WITH CHECK ((public.is_system_manager() AND (role = ANY (ARRAY['restaurant'::text, 'editor'::text, 'manager'::text]))));


--
-- Name: payment_proofs managers update proofs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "managers update proofs" ON public.payment_proofs FOR UPDATE TO authenticated USING ((( SELECT public.can_manage_restaurant(payment_proofs.restaurant_id) AS can_manage_restaurant) OR ( SELECT public.is_site_admin() AS is_site_admin))) WITH CHECK ((( SELECT public.can_manage_restaurant(payment_proofs.restaurant_id) AS can_manage_restaurant) OR ( SELECT public.is_site_admin() AS is_site_admin)));


--
-- Name: observability_alert_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.observability_alert_log ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_orders operational staff update orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "operational staff update orders" ON public.restaurant_orders FOR UPDATE TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'orders'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'orders'::text));


--
-- Name: restaurant_payment_methods payment methods managers manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "payment methods managers manage" ON public.restaurant_payment_methods TO authenticated USING ((( SELECT public.can_manage_restaurant(restaurant_payment_methods.restaurant_id) AS can_manage_restaurant) OR ( SELECT public.is_site_admin() AS is_site_admin))) WITH CHECK ((( SELECT public.can_manage_restaurant(restaurant_payment_methods.restaurant_id) AS can_manage_restaurant) OR ( SELECT public.is_site_admin() AS is_site_admin)));


--
-- Name: restaurant_payment_methods payment methods public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "payment methods public read" ON public.restaurant_payment_methods FOR SELECT TO authenticated, anon USING ((active AND (EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = restaurant_payment_methods.restaurant_id) AND r.active)))));


--
-- Name: payment_proofs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment_proofs ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_countries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_countries ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_appointments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_appointments ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_appointments professional_appointments_customer_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_appointments_customer_read ON public.professional_appointments FOR SELECT TO authenticated USING (((customer_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_appointments.restaurant_id) AND (r.business_type = 'professional'::text))))));


--
-- Name: professional_appointments professional_appointments_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_appointments_staff ON public.professional_appointments TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_appointments.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'appointments'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_appointments.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'appointments'::text))));


--
-- Name: professional_availability; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_availability ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_availability professional_availability_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_availability_staff ON public.professional_availability TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_availability.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_availability.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text))));


--
-- Name: professional_booking_payment_intents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_booking_payment_intents ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_booking_payment_intents professional_booking_payment_intents_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_booking_payment_intents_staff_select ON public.professional_booking_payment_intents FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'appointments'::text)));


--
-- Name: professional_provider_services; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_provider_services ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_provider_services professional_provider_services_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_provider_services_staff ON public.professional_provider_services TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_provider_services.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_provider_services.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text))));


--
-- Name: professional_providers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_providers professional_providers_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_providers_staff ON public.professional_providers TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_providers.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_providers.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text))));


--
-- Name: professional_services; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_services ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_services professional_services_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_services_staff ON public.professional_services TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_services.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'services'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_services.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'services'::text))));


--
-- Name: professional_time_off; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professional_time_off ENABLE ROW LEVEL SECURITY;

--
-- Name: professional_time_off professional_time_off_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professional_time_off_staff ON public.professional_time_off TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_time_off.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = professional_time_off.restaurant_id) AND (r.business_type = 'professional'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'professionals'::text))));


--
-- Name: restaurant_promotions public read active promotions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read active promotions" ON public.restaurant_promotions FOR SELECT TO authenticated, anon USING ((active AND ((starts_at IS NULL) OR (starts_at <= now())) AND ((ends_at IS NULL) OR (ends_at >= now()))));


--
-- Name: restaurants public read active restaurants; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read active restaurants" ON public.restaurants FOR SELECT TO authenticated, anon USING ((active = true));


--
-- Name: restaurant_categories public read categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read categories" ON public.restaurant_categories FOR SELECT TO authenticated, anon USING ((active = true));


--
-- Name: restaurant_product_option_groups public read option groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read option groups" ON public.restaurant_product_option_groups FOR SELECT TO authenticated, anon USING ((active AND (EXISTS ( SELECT 1
   FROM public.restaurant_products p
  WHERE ((p.id = restaurant_product_option_groups.product_id) AND (p.restaurant_id = p.restaurant_id) AND p.available)))));


--
-- Name: restaurant_product_options public read product options; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read product options" ON public.restaurant_product_options FOR SELECT TO authenticated, anon USING ((available AND (EXISTS ( SELECT 1
   FROM public.restaurant_product_option_groups g
  WHERE ((g.id = restaurant_product_options.group_id) AND (g.restaurant_id = g.restaurant_id) AND g.active)))));


--
-- Name: restaurant_products public read products; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read products" ON public.restaurant_products FOR SELECT TO authenticated, anon USING ((available = true));


--
-- Name: restaurant_promotion_products public read promotion products; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read promotion products" ON public.restaurant_promotion_products FOR SELECT TO authenticated, anon USING ((EXISTS ( SELECT 1
   FROM public.restaurant_promotions p
  WHERE ((p.id = restaurant_promotion_products.promotion_id) AND p.active AND ((p.starts_at IS NULL) OR (p.starts_at <= now())) AND ((p.ends_at IS NULL) OR (p.ends_at >= now()))))));


--
-- Name: restaurant_reviews public read published reviews; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read published reviews" ON public.restaurant_reviews FOR SELECT TO authenticated, anon USING (published);


--
-- Name: restaurant_orders public_can_create_restaurant_orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY public_can_create_restaurant_orders ON public.restaurant_orders FOR INSERT TO authenticated, anon WITH CHECK (((restaurant_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = restaurant_orders.restaurant_id) AND (r.active = true) AND (r.subscription_status = ANY (ARRAY['trial'::text, 'active'::text])) AND (r.subscription_expires_at > now()))))));


--
-- Name: push_campaigns; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.push_campaigns ENABLE ROW LEVEL SECURITY;

--
-- Name: push_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.push_config ENABLE ROW LEVEL SECURITY;

--
-- Name: push_notification_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.push_notification_log ENABLE ROW LEVEL SECURITY;

--
-- Name: push_subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_categories restaurant categories admin write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant categories admin write" ON public.restaurant_categories TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: restaurant_categories restaurant categories public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant categories public read" ON public.restaurant_categories FOR SELECT TO authenticated, anon USING ((active = true));


--
-- Name: restaurant_categories restaurant managers manage categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant managers manage categories" ON public.restaurant_categories TO authenticated USING (public.can_manage_restaurant(restaurant_id)) WITH CHECK (public.can_manage_restaurant(restaurant_id));


--
-- Name: restaurant_orders restaurant managers manage orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant managers manage orders" ON public.restaurant_orders TO authenticated USING (public.can_manage_restaurant(restaurant_id)) WITH CHECK (public.can_manage_restaurant(restaurant_id));


--
-- Name: restaurant_products restaurant managers manage products; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant managers manage products" ON public.restaurant_products TO authenticated USING (public.can_manage_restaurant(restaurant_id)) WITH CHECK (public.can_manage_restaurant(restaurant_id));


--
-- Name: restaurant_staff restaurant managers update staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant managers update staff" ON public.restaurant_staff FOR UPDATE TO authenticated USING ((public.can_manage_restaurant_staff(restaurant_id) AND (role <> 'restaurant'::text))) WITH CHECK ((public.can_manage_restaurant_staff(restaurant_id) AND (role = ANY (ARRAY['manager'::text, 'editor'::text, 'cashier'::text, 'kitchen'::text, 'courier'::text, 'waiter'::text]))));


--
-- Name: restaurant_staff restaurant managers view staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant managers view staff" ON public.restaurant_staff FOR SELECT TO authenticated USING (public.can_manage_restaurant_staff(restaurant_id));


--
-- Name: restaurant_whatsapp_automations restaurant members read whatsapp automations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant members read whatsapp automations" ON public.restaurant_whatsapp_automations FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_automations.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true)))));


--
-- Name: restaurant_whatsapp_connections restaurant members read whatsapp connection; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant members read whatsapp connection" ON public.restaurant_whatsapp_connections FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_connections.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true)))));


--
-- Name: restaurant_whatsapp_message_log restaurant members read whatsapp logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant members read whatsapp logs" ON public.restaurant_whatsapp_message_log FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_message_log.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true)))));


--
-- Name: restaurant_orders restaurant orders admin read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant orders admin read" ON public.restaurant_orders FOR SELECT TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: restaurant_orders restaurant orders admin update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant orders admin update" ON public.restaurant_orders FOR UPDATE TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: restaurant_orders restaurant orders public insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant orders public insert" ON public.restaurant_orders FOR INSERT TO authenticated, anon WITH CHECK (true);


--
-- Name: restaurant_whatsapp_automations restaurant owners manage whatsapp automations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant owners manage whatsapp automations" ON public.restaurant_whatsapp_automations TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_automations.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true) AND (s.role = ANY (ARRAY['restaurant'::text, 'manager'::text])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_automations.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true) AND (s.role = ANY (ARRAY['restaurant'::text, 'manager'::text]))))));


--
-- Name: restaurant_whatsapp_connections restaurant owners manage whatsapp connection; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant owners manage whatsapp connection" ON public.restaurant_whatsapp_connections TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_connections.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true) AND (s.role = ANY (ARRAY['restaurant'::text, 'manager'::text])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_whatsapp_connections.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true) AND (s.role = ANY (ARRAY['restaurant'::text, 'manager'::text]))))));


--
-- Name: restaurant_products restaurant products admin write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant products admin write" ON public.restaurant_products TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: restaurant_products restaurant products public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant products public read" ON public.restaurant_products FOR SELECT TO authenticated, anon USING ((available = true));


--
-- Name: restaurant_settings restaurant settings admin write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant settings admin write" ON public.restaurant_settings TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: restaurant_settings restaurant settings public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant settings public read" ON public.restaurant_settings FOR SELECT TO authenticated, anon USING (true);


--
-- Name: restaurant_inventory_movements restaurant staff create inventory movements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff create inventory movements" ON public.restaurant_inventory_movements FOR INSERT TO authenticated WITH CHECK ((((created_by = ( SELECT auth.uid() AS uid)) OR (created_by IS NULL)) AND (public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_inventory_movements.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active)))) AND (EXISTS ( SELECT 1
   FROM public.restaurant_inventory_items i
  WHERE ((i.id = restaurant_inventory_movements.inventory_item_id) AND (i.restaurant_id = i.restaurant_id))))));


--
-- Name: restaurant_tables restaurant staff create tables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff create tables" ON public.restaurant_tables FOR INSERT TO authenticated WITH CHECK (public.has_restaurant_permission(restaurant_id, 'table_qr'::text));


--
-- Name: restaurant_tables restaurant staff delete tables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff delete tables" ON public.restaurant_tables FOR DELETE TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'table_qr'::text));


--
-- Name: restaurant_inventory_items restaurant staff manage inventory; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff manage inventory" ON public.restaurant_inventory_items TO authenticated USING ((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_inventory_items.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active))))) WITH CHECK ((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_inventory_items.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active)))));


--
-- Name: restaurant_product_ingredients restaurant staff manage product ingredients; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff manage product ingredients" ON public.restaurant_product_ingredients TO authenticated USING ((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_product_ingredients.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active))))) WITH CHECK (((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_product_ingredients.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active)))) AND (EXISTS ( SELECT 1
   FROM public.restaurant_products p
  WHERE ((p.id = restaurant_product_ingredients.product_id) AND (p.restaurant_id = p.restaurant_id)))) AND (EXISTS ( SELECT 1
   FROM public.restaurant_inventory_items i
  WHERE ((i.id = restaurant_product_ingredients.inventory_item_id) AND (i.restaurant_id = i.restaurant_id))))));


--
-- Name: restaurant_inventory_movements restaurant staff read inventory movements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff read inventory movements" ON public.restaurant_inventory_movements FOR SELECT TO authenticated USING ((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_inventory_movements.restaurant_id) AND (s.user_id = ( SELECT auth.uid() AS uid)) AND s.active)))));


--
-- Name: restaurant_orders restaurant staff read own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff read own orders" ON public.restaurant_orders FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurant_orders.restaurant_id) AND (s.user_id = auth.uid()) AND (s.active = true)))));


--
-- Name: restaurant_tables restaurant staff read tables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff read tables" ON public.restaurant_tables FOR SELECT TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'table_qr'::text));


--
-- Name: restaurants restaurant staff update own restaurant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff update own restaurant" ON public.restaurants FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurants.id) AND (s.user_id = auth.uid()) AND s.active AND (s.role = 'restaurant'::text))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.restaurant_id = restaurants.id) AND (s.user_id = auth.uid()) AND s.active AND (s.role = 'restaurant'::text)))));


--
-- Name: restaurant_tables restaurant staff update tables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "restaurant staff update tables" ON public.restaurant_tables FOR UPDATE TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'table_qr'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'table_qr'::text));


--
-- Name: restaurant_cash_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_cash_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_cash_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_cash_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_email_notification_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_email_notification_log ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_inventory_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_inventory_items ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_inventory_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_inventory_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_payments restaurant_managers_read_subscription_payments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY restaurant_managers_read_subscription_payments ON public.subscription_payments FOR SELECT TO authenticated USING (public.can_manage_restaurant_staff(restaurant_id));


--
-- Name: restaurant_order_status_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_order_status_events ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_payment_connections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_payment_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_payment_methods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_payment_methods ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_product_ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_product_option_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_option_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_product_options; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_product_options ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_products ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_promotion_products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_promotion_products ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_promotions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_promotions ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_staff; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_staff ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_subscription_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_subscription_history ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_tables; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_veripagos_connections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_veripagos_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_whatsapp_automations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_whatsapp_automations ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_whatsapp_connections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_whatsapp_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_whatsapp_message_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurant_whatsapp_message_log ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.restaurants ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_online_order_items retail online order items staff read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail online order items staff read" ON public.retail_online_order_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.retail_online_orders o
  WHERE ((o.id = retail_online_order_items.order_id) AND ((o.customer_id = auth.uid()) OR public.is_site_admin() OR public.has_restaurant_permission(o.restaurant_id, 'cash'::text) OR public.has_restaurant_permission(o.restaurant_id, 'inventory'::text))))));


--
-- Name: retail_online_orders retail online orders staff read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail online orders staff read" ON public.retail_online_orders FOR SELECT TO authenticated USING (((customer_id = auth.uid()) OR public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'cash'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_products retail products manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail products manage" ON public.retail_products TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'products'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text))) WITH CHECK ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'products'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_products retail products read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail products read" ON public.retail_products FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'products'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text) OR public.has_restaurant_permission(restaurant_id, 'cash'::text)));


--
-- Name: retail_purchase_items retail purchase items read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail purchase items read" ON public.retail_purchase_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.retail_purchases p
  WHERE ((p.id = retail_purchase_items.purchase_id) AND (public.is_site_admin() OR public.has_restaurant_permission(p.restaurant_id, 'inventory'::text))))));


--
-- Name: retail_purchases retail purchases read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail purchases read" ON public.retail_purchases FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_return_items retail return items read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail return items read" ON public.retail_return_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.retail_returns r
  WHERE ((r.id = retail_return_items.return_id) AND (public.is_site_admin() OR public.has_restaurant_permission(r.restaurant_id, 'cash'::text) OR public.has_restaurant_permission(r.restaurant_id, 'inventory'::text))))));


--
-- Name: retail_returns retail returns read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail returns read" ON public.retail_returns FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'cash'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_sale_items retail sale items read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail sale items read" ON public.retail_sale_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.retail_sales s
  WHERE ((s.id = retail_sale_items.sale_id) AND (public.is_site_admin() OR public.has_restaurant_permission(s.restaurant_id, 'cash'::text) OR public.has_restaurant_permission(s.restaurant_id, 'inventory'::text))))));


--
-- Name: retail_sales retail sales read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail sales read" ON public.retail_sales FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'cash'::text) OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_stock_movements retail stock movements read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail stock movements read" ON public.retail_stock_movements FOR SELECT TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'inventory'::text) OR public.has_restaurant_permission(restaurant_id, 'cash'::text)));


--
-- Name: retail_suppliers retail suppliers manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "retail suppliers manage" ON public.retail_suppliers TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'inventory'::text))) WITH CHECK ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'inventory'::text)));


--
-- Name: retail_online_order_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_online_order_items ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_online_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_online_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_products ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_purchase_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_purchase_items ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_purchases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_purchases ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_return_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_return_items ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_returns; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_returns ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_sale_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_sale_items ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_sales; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_sales ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_stock_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_stock_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: retail_suppliers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retail_suppliers ENABLE ROW LEVEL SECURITY;

--
-- Name: push_config service role manages push config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "service role manages push config" ON public.push_config TO service_role USING (true) WITH CHECK (true);


--
-- Name: push_notification_log service role manages push notification log; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "service role manages push notification log" ON public.push_notification_log TO service_role USING (true) WITH CHECK (true);


--
-- Name: customer_profiles site admins read customer profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "site admins read customer profiles" ON public.customer_profiles FOR SELECT TO authenticated USING (public.is_site_admin());


--
-- Name: site_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.site_links ENABLE ROW LEVEL SECURITY;

--
-- Name: restaurant_order_status_events staff insert order events; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff insert order events" ON public.restaurant_order_status_events FOR INSERT TO authenticated WITH CHECK (public.has_restaurant_permission(restaurant_id, 'orders'::text));


--
-- Name: restaurant_cash_movements staff manage cash movements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage cash movements" ON public.restaurant_cash_movements TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'cash'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'cash'::text));


--
-- Name: restaurant_cash_sessions staff manage cash sessions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage cash sessions" ON public.restaurant_cash_sessions TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'cash'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'cash'::text));


--
-- Name: restaurant_product_option_groups staff manage option groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage option groups" ON public.restaurant_product_option_groups TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'menu'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'menu'::text));


--
-- Name: restaurant_payments staff manage payments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage payments" ON public.restaurant_payments TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'payments'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'payments'::text));


--
-- Name: restaurant_product_options staff manage product options; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage product options" ON public.restaurant_product_options TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'menu'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'menu'::text));


--
-- Name: restaurant_promotion_products staff manage promotion products; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage promotion products" ON public.restaurant_promotion_products TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'promotions'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'promotions'::text));


--
-- Name: restaurant_promotions staff manage promotions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage promotions" ON public.restaurant_promotions TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'promotions'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'promotions'::text));


--
-- Name: restaurant_reviews staff manage reviews; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff manage reviews" ON public.restaurant_reviews TO authenticated USING (public.has_restaurant_permission(restaurant_id, 'reviews'::text)) WITH CHECK (public.has_restaurant_permission(restaurant_id, 'reviews'::text));


--
-- Name: restaurant_order_status_events staff read order events; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff read order events" ON public.restaurant_order_status_events FOR SELECT TO authenticated USING ((public.has_restaurant_permission(restaurant_id, 'orders'::text) OR (EXISTS ( SELECT 1
   FROM public.restaurant_orders o
  WHERE ((o.id = restaurant_order_status_events.order_id) AND (o.customer_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: restaurant_staff staff view own memberships; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "staff view own memberships" ON public.restaurant_staff FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR public.is_site_admin()));


--
-- Name: streaming_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_accounts streaming_accounts_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_accounts_staff ON public.streaming_accounts TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_accounts.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'products'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_accounts.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: streaming_customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_customers ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_customers streaming_customers_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_customers_staff ON public.streaming_customers TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_customers.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_customers.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: streaming_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_orders streaming_orders_customer_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_orders_customer_select ON public.streaming_orders FOR SELECT TO authenticated USING (((customer_user_id = ( SELECT auth.uid() AS uid)) OR public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text)));


--
-- Name: streaming_orders streaming_orders_staff_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_orders_staff_update ON public.streaming_orders FOR UPDATE TO authenticated USING ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))) WITH CHECK ((public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text)));


--
-- Name: streaming_platforms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_platforms ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_platforms streaming_platforms_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_platforms_staff ON public.streaming_platforms TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_platforms.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'categories'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_platforms.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'categories'::text))));


--
-- Name: streaming_reminder_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_reminder_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_reminder_logs streaming_reminder_logs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_reminder_logs_insert ON public.streaming_reminder_logs FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_reminder_logs.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: streaming_reminder_logs streaming_reminder_logs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_reminder_logs_select ON public.streaming_reminder_logs FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_reminder_logs.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: streaming_renewals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_renewals ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_renewals streaming_renewals_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_renewals_staff ON public.streaming_renewals TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_renewals.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_renewals.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: streaming_subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.streaming_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: streaming_subscriptions streaming_subscriptions_customer_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_subscriptions_customer_select ON public.streaming_subscriptions FOR SELECT TO authenticated USING (((order_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.streaming_orders o
  WHERE ((o.id = streaming_subscriptions.order_id) AND (o.customer_user_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: streaming_subscriptions streaming_subscriptions_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY streaming_subscriptions_staff ON public.streaming_subscriptions TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_subscriptions.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.restaurants r
  WHERE ((r.id = streaming_subscriptions.restaurant_id) AND (r.business_type = 'streaming'::text)))) AND (public.is_site_admin() OR public.has_restaurant_permission(restaurant_id, 'orders'::text) OR public.has_restaurant_permission(restaurant_id, 'products'::text))));


--
-- Name: restaurant_subscription_history subscription history admins read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "subscription history admins read" ON public.restaurant_subscription_history FOR SELECT TO authenticated USING (public.is_system_manager());


--
-- Name: restaurant_subscription_history subscription history admins write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "subscription history admins write" ON public.restaurant_subscription_history TO authenticated USING (public.is_system_manager()) WITH CHECK (public.is_system_manager());


--
-- Name: subscription_payment_providers subscription providers admin manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "subscription providers admin manage" ON public.subscription_payment_providers TO authenticated USING (( SELECT public.is_site_admin() AS is_site_admin)) WITH CHECK (( SELECT public.is_site_admin() AS is_site_admin));


--
-- Name: subscription_payment_providers subscription providers public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "subscription providers public read" ON public.subscription_payment_providers FOR SELECT TO authenticated, anon USING ((active OR ( SELECT public.is_site_admin() AS is_site_admin)));


--
-- Name: subscription_payment_methods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payment_methods ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_payment_methods subscription_payment_methods_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY subscription_payment_methods_read ON public.subscription_payment_methods FOR SELECT TO authenticated USING (((user_id = ( SELECT auth.uid() AS uid)) OR public.can_manage_restaurant_staff(restaurant_id) OR public.is_site_admin()));


--
-- Name: subscription_payment_providers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payment_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_payment_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payment_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_plans superadmins_manage_subscription_plans; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY superadmins_manage_subscription_plans ON public.subscription_plans TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: restaurants system managers manage restaurants; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "system managers manage restaurants" ON public.restaurants TO authenticated USING (public.is_system_manager()) WITH CHECK (public.is_system_manager());


--
-- Name: table_qr_push_subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.table_qr_push_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_issue_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_issue_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: push_subscriptions users create own push subscriptions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users create own push subscriptions" ON public.push_subscriptions FOR INSERT TO authenticated WITH CHECK (((auth.uid() = user_id) AND (((audience = 'customer'::text) AND (restaurant_id IS NULL)) OR ((audience = 'restaurant'::text) AND (restaurant_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.restaurant_staff s
  WHERE ((s.user_id = auth.uid()) AND (s.restaurant_id = push_subscriptions.restaurant_id) AND (s.active = true))))) OR ((audience = 'admin'::text) AND (restaurant_id IS NULL) AND (EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid())))))));


--
-- Name: push_subscriptions users delete own push subscriptions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users delete own push subscriptions" ON public.push_subscriptions FOR DELETE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: user_profiles users read own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users read own profile" ON public.user_profiles FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: push_subscriptions users read own push subscriptions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users read own push subscriptions" ON public.push_subscriptions FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: push_subscriptions users update own push subscriptions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users update own push subscriptions" ON public.push_subscriptions FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: subscription_payments users_read_own_subscription_payments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_read_own_subscription_payments ON public.subscription_payments FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM public.admin_users a
  WHERE (a.user_id = auth.uid())))));


--
-- Name: veripagos_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.veripagos_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: whatsapp_webhook_diagnostic_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.whatsapp_webhook_diagnostic_log ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--


