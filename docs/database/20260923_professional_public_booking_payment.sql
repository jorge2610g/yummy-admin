-- YummyPro · estado de anticipo en reservas públicas profesionales
-- Aplicado al proyecto gulctljitzlwokqydigx el 2026-09-23.

create or replace function public.create_public_professional_appointment(
  p_restaurant_id bigint,
  p_service_id bigint,
  p_provider_id bigint,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_phone text default '',
  p_customer_email text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_end timestamptz;
  v_status text;
  v_price numeric;
  v_deposit numeric;
  v_id bigint;
  v_timezone text;
begin
  if nullif(btrim(p_customer_name),'') is null then
    raise exception 'Ingresa el nombre del cliente';
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
    case when coalesce(r.professional_booking_auto_confirm,true) then 'confirmed' else 'pending' end,
    svc.price,
    case when coalesce(r.professional_booking_deposit_required,false)
      then least(coalesce(r.professional_booking_deposit_amount,0),svc.price)
      else 0 end
  into v_status,v_price,v_deposit
  from public.professional_services svc
  join public.restaurants r on r.id=svc.restaurant_id
  where svc.id=p_service_id and svc.restaurant_id=p_restaurant_id and svc.active;

  insert into public.professional_appointments(
    restaurant_id,service_id,provider_id,customer_id,customer_name,
    customer_phone,customer_email,starts_at,ends_at,status,notes,
    payment_status,deposit_amount,total_amount,created_by
  ) values (
    p_restaurant_id,p_service_id,p_provider_id,(select auth.uid()),btrim(p_customer_name),
    coalesce(p_customer_phone,''),nullif(btrim(coalesce(p_customer_email,'')),''),
    p_starts_at,v_end,v_status,nullif(btrim(coalesce(p_notes,'')),''),
    case when coalesce(v_deposit,0)>0 then 'pending' else 'not_required' end,
    coalesce(v_deposit,0),coalesce(v_price,0),(select auth.uid())
  ) returning id into v_id;

  return jsonb_build_object(
    'id',v_id,'status',v_status,'starts_at',p_starts_at,'ends_at',v_end,
    'payment_status',case when coalesce(v_deposit,0)>0 then 'pending' else 'not_required' end,
    'deposit_amount',coalesce(v_deposit,0)
  );
exception
  when exclusion_violation then
    raise exception 'Ese horario acaba de ser reservado. Elige otro.';
end;
$function$;

revoke all on function public.create_public_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) from public;
grant execute on function public.create_public_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) to anon, authenticated, service_role;
