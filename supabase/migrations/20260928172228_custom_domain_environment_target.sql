-- YummyPro · target de CNAME por ambiente
-- Supabase Staging migration: 20260928172228_custom_domain_environment_target
-- Producción debe definir custom_domain_cname_target=domains.yummypro.online durante release.

create or replace function public.get_business_custom_domain(p_restaurant_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_active jsonb;
  v_pending jsonb;
  v_cname_target text := 'domains.yummypro.online';
begin
  if (select auth.uid()) is null or not public.can_manage_restaurant(p_restaurant_id) then
    raise exception 'No autorizado';
  end if;

  select nullif(rc.value,'')
    into v_cname_target
  from private.runtime_config rc
  where rc.key='custom_domain_cname_target'
  limit 1;

  v_cname_target := coalesce(v_cname_target,'domains.yummypro.online');

  select jsonb_build_object(
    'hostname',d.hostname,
    'status',d.status,
    'ssl_status',d.ssl_status,
    'verified_at',d.verified_at,
    'activated_at',d.activated_at
  )
  into v_active
  from public.business_custom_domains d
  where d.restaurant_id=p_restaurant_id and d.status='active'
  order by d.activated_at desc nulls last,d.id desc
  limit 1;

  select jsonb_build_object(
    'hostname',d.hostname,
    'status',d.status,
    'ssl_status',d.ssl_status,
    'verification_record_name','_yummypro.'||d.hostname,
    'verification_record_value','yummypro-verification='||d.verification_token::text,
    'cname_target',v_cname_target,
    'verified_at',d.verified_at,
    'last_checked_at',d.last_checked_at,
    'last_error',d.last_error
  )
  into v_pending
  from public.business_custom_domains d
  where d.restaurant_id=p_restaurant_id
    and d.status in ('pending_dns','dns_verified','provisioning','failed')
  order by d.created_at desc,d.id desc
  limit 1;

  return jsonb_build_object('active',v_active,'pending',v_pending);
end
$$;

revoke all on function public.get_business_custom_domain(bigint) from public,anon;
grant execute on function public.get_business_custom_domain(bigint) to authenticated;

-- En cada ambiente configurar private.runtime_config.custom_domain_cname_target.
-- Staging actual: domains-pruebas.yummypro.online
-- Producción futura: domains.yummypro.online
