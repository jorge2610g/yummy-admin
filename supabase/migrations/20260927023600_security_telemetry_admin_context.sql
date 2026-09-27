-- YummyPro security hardening wave 4
-- Staging first. Public telemetry remains available, but Admin context requires a real site-admin session.

create or replace function public.log_app_error(
  p_app_context text,
  p_category text default 'system'::text,
  p_error_code text default null::text,
  p_message text default null::text,
  p_severity text default 'error'::text,
  p_is_user_error boolean default false,
  p_restaurant_id bigint default null::bigint,
  p_session_id text default null::text,
  p_route text default null::text,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id bigint;
  v_severity text;
begin
  if p_app_context not in ('landing','restaurant','client','admin') then
    raise exception 'Contexto inválido';
  end if;

  if p_app_context = 'admin'
     and (auth.uid() is null or not public.is_site_admin()) then
    raise exception 'No autorizado';
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
$function$;

create or replace function public.log_app_event(
  p_app_context text,
  p_event_name text,
  p_module text default null::text,
  p_restaurant_id bigint default null::bigint,
  p_plan_id bigint default null::bigint,
  p_session_id text default null::text,
  p_route text default null::text,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id bigint;
begin
  if p_app_context not in ('landing','restaurant','client','admin') then
    raise exception 'Contexto inválido';
  end if;

  if p_app_context = 'admin'
     and (auth.uid() is null or not public.is_site_admin()) then
    raise exception 'No autorizado';
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
$function$;
