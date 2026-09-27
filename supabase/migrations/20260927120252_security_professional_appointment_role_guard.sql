-- YummyPro security hardening v2.3.90
-- Staging first. Direct professional appointment creation is restricted
-- to customer accounts or an active Admin client-preview session for the business.

create or replace function public.create_professional_appointment(
  p_restaurant_id bigint,
  p_service_id bigint,
  p_provider_id bigint,
  p_starts_at timestamp with time zone,
  p_customer_name text,
  p_customer_phone text default ''::text,
  p_customer_email text default null::text,
  p_notes text default null::text
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_service public.professional_services%rowtype;
  v_rest public.restaurants%rowtype;
  v_end timestamptz;
  v_id bigint;
begin
  if auth.uid() is null
     or (
       public.current_account_role() <> 'customer'
       and not public.has_admin_client_preview(p_restaurant_id)
     ) then
    raise exception 'Inicia sesión como cliente para continuar';
  end if;

  select * into v_rest from public.restaurants
  where id=p_restaurant_id and business_type='professional' and active
    and subscription_status in ('trial','active')
    and (subscription_expires_at is null or subscription_expires_at > now());
  if not found then raise exception 'Este profesional no está disponible'; end if;

  select * into v_service from public.professional_services
  where id=p_service_id and restaurant_id=p_restaurant_id and active;
  if not found then raise exception 'Servicio no disponible'; end if;

  if not exists(
    select 1 from public.professional_providers p
    where p.id=p_provider_id and p.restaurant_id=p_restaurant_id and p.active
  ) then
    raise exception 'Profesional no disponible';
  end if;

  if coalesce(btrim(p_customer_name),'')='' then raise exception 'Ingresa tu nombre'; end if;
  if p_starts_at < now()+make_interval(hours=>v_rest.professional_booking_min_notice_hours)
     or p_starts_at > now()+make_interval(days=>v_rest.professional_booking_max_days)
  then raise exception 'Horario fuera de la ventana de reserva'; end if;

  v_end := p_starts_at + make_interval(mins=>v_service.duration_minutes);

  if not exists(
    select 1
    from public.get_professional_available_slots(
      p_restaurant_id,p_service_id,p_provider_id,
      (p_starts_at at time zone v_rest.timezone)::date
    ) s
    where s.slot_start=p_starts_at
  ) then
    raise exception 'Ese horario ya no está disponible';
  end if;

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
$function$;
