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
-- Name: private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA private;


--
-- Name: auto_prepare_local_kitchen_order(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.auto_prepare_local_kitchen_order() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'auth'
    AS $$
declare
  v_source text := lower(coalesce(new.order_source,''));
  v_status text := lower(trim(coalesce(new.status,'')));
  v_method text := lower(trim(coalesce(new.payment_method,'')));
  v_paid text := lower(trim(coalesce(new.payment_status,'')));
begin
  if v_status not in ('nuevo','recibido') then return new; end if;

  if v_source='waiter'
     or (
       v_source='table_qr'
       and (
         v_method not in ('mercado pago','qr bolivia')
         or v_paid='approved'
       )
     ) then
    update public.restaurant_orders
       set status='preparacion', updated_at=now()
     where id=new.id and status in ('nuevo','recibido');
  end if;

  return new;
end
$$;


--
-- Name: enforce_kitchen_order_transition(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.enforce_kitchen_order_transition() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'private'
    AS $$
declare v_role text;
begin
  if auth.uid() is null or public.is_site_admin() then return new; end if;
  select role into v_role from public.restaurant_staff
   where restaurant_id=old.restaurant_id and user_id=auth.uid() and active limit 1;
  if v_role='kitchen' then
    if not (((old.status='recibido' or old.status='nuevo') and new.status='preparacion') or (old.status='preparacion' and new.status='listo')) then
      raise exception 'Cocina solo puede avanzar pedidos a Preparación o Listo';
    end if;
    if new.restaurant_id is distinct from old.restaurant_id
       or new.total is distinct from old.total
       or new.items is distinct from old.items
       or new.payment_method is distinct from old.payment_method
       or new.payment_status is distinct from old.payment_status
       or new.customer_name is distinct from old.customer_name
       or new.order_source is distinct from old.order_source then
      raise exception 'Cocina no puede modificar datos comerciales del pedido';
    end if;
  end if;
  return new;
end
$$;


--
-- Name: log_initial_order_status(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.log_initial_order_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'auth'
    AS $$
begin
 insert into public.restaurant_order_status_events(restaurant_id,order_id,previous_status,new_status,changed_by)
 values(new.restaurant_id,new.id,null,new.status,(select auth.uid()));
 return new;
end $$;


--
-- Name: process_order_transition(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.process_order_transition() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'auth'
    AS $$
declare line jsonb; pid bigint; quantity numeric; ingredient record; open_session bigint;
begin
 if new.status is distinct from old.status then
   if new.status='preparacion' and new.kitchen_started_at is null then new.kitchen_started_at=now(); end if;
   if new.status='listo' and new.ready_at is null then new.ready_at=now(); end if;
   if new.status='entregado' and new.delivered_at is null then new.delivered_at=now(); end if;
   insert into public.restaurant_order_status_events(restaurant_id,order_id,previous_status,new_status,changed_by)
   values(new.restaurant_id,new.id,old.status,new.status,(select auth.uid()));
   if new.status='preparacion' and new.inventory_deducted_at is null then
     for line in select value from jsonb_array_elements(coalesce(new.items,'[]'::jsonb))
     loop
       pid=nullif(line->>'product_id','')::bigint;
       quantity=greatest(coalesce(nullif(line->>'qty','')::numeric,1),0);
       if pid is not null then
         for ingredient in select inventory_item_id,quantity_per_unit from public.restaurant_product_ingredients where restaurant_id=new.restaurant_id and product_id=pid
         loop
           insert into public.restaurant_inventory_movements(restaurant_id,inventory_item_id,movement_type,quantity_delta,note,created_by)
           values(new.restaurant_id,ingredient.inventory_item_id,'consumo',-(ingredient.quantity_per_unit*quantity),'Pedido '||new.order_code,(select auth.uid()));
         end loop;
       end if;
     end loop;
     new.inventory_deducted_at=now();
   end if;
   if new.status='entregado'
      and lower(coalesce(new.payment_status,''))='approved'
      and lower(coalesce(new.payment_method,'')) in ('efectivo','cash') then
     select id into open_session from public.restaurant_cash_sessions where restaurant_id=new.restaurant_id and status='open' limit 1;
     if open_session is not null then
       insert into public.restaurant_cash_movements(restaurant_id,session_id,order_id,movement_type,payment_method,amount,description,created_by)
       values(new.restaurant_id,open_session,new.id,'sale','Efectivo',new.total,'Venta pedido '||new.order_code,(select auth.uid())) on conflict do nothing;
     end if;
   end if;
 end if;
 return new;
end
$$;


--
-- Name: protect_order_intake(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.protect_order_intake() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'private'
    AS $$
begin
  if tg_op='UPDATE' and new.order_source is distinct from old.order_source then
    raise exception 'No se puede cambiar el origen de un pedido existente';
  end if;

  if new.order_source='waiter' then
    if tg_op='INSERT' then
      if coalesce(auth.role(),'')<>'service_role'
         and (auth.uid() is null or not public.has_restaurant_permission(new.restaurant_id,'pos')) then
        raise exception 'No autorizado para gestionar pedidos de mesero';
      end if;
      if not exists (
        select 1 from public.restaurant_cash_sessions s
        where s.restaurant_id=new.restaurant_id and s.status='open'
      ) then
        raise exception 'Debes abrir una caja antes de enviar pedidos a cocina';
      end if;
      new.created_by:=auth.uid();
      new.payment_status:='internal';
      new.payment_method:='Pendiente';
    else
      if coalesce(auth.role(),'')<>'service_role'
         and (
           auth.uid() is null
           or not (
             public.has_restaurant_permission(new.restaurant_id,'pos')
             or public.has_restaurant_permission(new.restaurant_id,'cash')
           )
         ) then
        raise exception 'No autorizado para gestionar pedidos de mesero';
      end if;
    end if;
  end if;

  if new.order_source in ('online','table_qr')
     and lower(coalesce(new.payment_method,'')) in ('mercado pago','qr bolivia')
     and new.payment_status='approved'
     and coalesce(auth.role(),'anon')<>'service_role'
     and not public.is_site_admin() then
    raise exception 'La aprobación del pago online solo puede confirmarla el proveedor';
  end if;

  return new;
end
$$;


--
-- Name: sync_order_payment(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.sync_order_payment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
begin
 insert into public.restaurant_payments(
   restaurant_id,order_id,method,provider,status,amount,provider_payment_id,paid_at,refunded_at,updated_at
 )
 values(
   new.restaurant_id,new.id,coalesce(new.payment_method,'Pendiente'),
   case
     when lower(coalesce(new.payment_method,'')) like '%mercado%' then 'mercadopago'
     when lower(trim(coalesce(new.payment_method,'')))='qr bolivia' then 'veripagos'
     else null
   end,
   case
     when new.refund_status in ('approved','refunded') then 'refunded'
     when new.payment_status='approved' then 'approved'
     when new.payment_status='rejected' then 'rejected'
     else 'pending'
   end,
   new.total,
   case when lower(trim(coalesce(new.payment_method,'')))='qr bolivia' then new.payment_reference else new.mp_payment_id end,
   new.paid_at,new.refunded_at,now()
 )
 on conflict(order_id) do update set
   method=excluded.method,provider=excluded.provider,status=excluded.status,amount=excluded.amount,
   provider_payment_id=excluded.provider_payment_id,paid_at=excluded.paid_at,refunded_at=excluded.refunded_at,updated_at=now();
 return new;
end
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: push_config; Type: TABLE; Schema: private; Owner: -
--

CREATE TABLE private.push_config (
    id boolean DEFAULT true NOT NULL,
    vapid_public_key text NOT NULL,
    vapid_private_key text NOT NULL,
    subject text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT push_config_id_check CHECK (id)
);


--
-- Name: push_notification_log; Type: TABLE; Schema: private; Owner: -
--

CREATE TABLE private.push_notification_log (
    event_key text NOT NULL,
    order_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: push_config push_config_pkey; Type: CONSTRAINT; Schema: private; Owner: -
--

ALTER TABLE ONLY private.push_config
    ADD CONSTRAINT push_config_pkey PRIMARY KEY (id);


--
-- Name: push_notification_log push_notification_log_pkey; Type: CONSTRAINT; Schema: private; Owner: -
--

ALTER TABLE ONLY private.push_notification_log
    ADD CONSTRAINT push_notification_log_pkey PRIMARY KEY (event_key);


--
-- PostgreSQL database dump complete
--


