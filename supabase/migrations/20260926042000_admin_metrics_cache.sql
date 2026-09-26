-- Cache expensive Admin dashboard aggregates for short bursts of concurrent refreshes.
create table if not exists private.admin_metrics_cache (
  cache_key text primary key,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

revoke all on private.admin_metrics_cache from public, anon, authenticated;

create or replace function public.admin_general_metrics_cached()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_payload jsonb;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  select c.payload into v_payload
  from private.admin_metrics_cache c
  where c.cache_key='general'
    and c.updated_at > now() - interval '15 seconds';

  if v_payload is not null then return v_payload; end if;

  perform pg_advisory_xact_lock(hashtext('yummypro:admin-metrics:general'));

  select c.payload into v_payload
  from private.admin_metrics_cache c
  where c.cache_key='general'
    and c.updated_at > now() - interval '15 seconds';

  if v_payload is null then
    select to_jsonb(m) into v_payload from public.admin_general_metrics() m;
    insert into private.admin_metrics_cache(cache_key,payload,updated_at)
    values ('general',coalesce(v_payload,'{}'::jsonb),now())
    on conflict (cache_key) do update
      set payload=excluded.payload,updated_at=excluded.updated_at;
  end if;

  return coalesce(v_payload,'{}'::jsonb);
end
$function$;

create or replace function public.admin_dashboard_overview_cached(p_restaurant_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_key text := 'overview:'||coalesce(p_restaurant_id::text,'all');
  v_payload jsonb;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  select c.payload into v_payload
  from private.admin_metrics_cache c
  where c.cache_key=v_key
    and c.updated_at > now() - interval '15 seconds';

  if v_payload is not null then return v_payload; end if;

  perform pg_advisory_xact_lock(hashtext('yummypro:admin-metrics:'||v_key));

  select c.payload into v_payload
  from private.admin_metrics_cache c
  where c.cache_key=v_key
    and c.updated_at > now() - interval '15 seconds';

  if v_payload is null then
    v_payload := public.admin_dashboard_overview(p_restaurant_id);
    insert into private.admin_metrics_cache(cache_key,payload,updated_at)
    values (v_key,coalesce(v_payload,'{}'::jsonb),now())
    on conflict (cache_key) do update
      set payload=excluded.payload,updated_at=excluded.updated_at;
  end if;

  return coalesce(v_payload,'{}'::jsonb);
end
$function$;

revoke all on function public.admin_general_metrics_cached() from public, anon;
revoke all on function public.admin_dashboard_overview_cached(bigint) from public, anon;
grant execute on function public.admin_general_metrics_cached() to authenticated;
grant execute on function public.admin_dashboard_overview_cached(bigint) to authenticated;

-- Keep cache bounded even if many business IDs are opened over time.
delete from private.admin_metrics_cache where updated_at < now() - interval '1 day';
