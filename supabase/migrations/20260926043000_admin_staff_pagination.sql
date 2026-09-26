-- Paginated staff directory for the global Admin.
create or replace function public.admin_staff_directory_page(
  p_limit integer default 25,
  p_offset integer default 0,
  p_search text default null,
  p_business_type text default 'all',
  p_restaurant_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_limit integer := least(greatest(coalesce(p_limit,25),1),100);
  v_offset integer := greatest(coalesce(p_offset,0),0);
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_type text := nullif(btrim(coalesce(p_business_type,'all')),'all');
  v_result jsonb;
begin
  if not public.is_site_admin() then raise exception 'No autorizado'; end if;

  with filtered as (
    select s.*,r.name as restaurant_name,r.business_type
    from public.restaurant_staff s
    join public.restaurants r on r.id=s.restaurant_id
    where (p_restaurant_id is null or s.restaurant_id=p_restaurant_id)
      and (v_type is null or r.business_type=v_type)
      and (
        v_search is null
        or coalesce(s.email,'') ilike '%'||v_search||'%'
        or coalesce(s.display_name,'') ilike '%'||v_search||'%'
        or coalesce(s.role,'') ilike '%'||v_search||'%'
        or coalesce(r.name,'') ilike '%'||v_search||'%'
      )
  ),
  page as (
    select * from filtered
    order by created_at desc,id desc
    offset v_offset
    limit v_limit
  )
  select jsonb_build_object(
    'total',(select count(*) from filtered),
    'rows',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.id desc) from page p),'[]'::jsonb)
  )
  into v_result;

  return v_result;
end
$function$;

revoke all on function public.admin_staff_directory_page(integer,integer,text,text,bigint) from public, anon;
grant execute on function public.admin_staff_directory_page(integer,integer,text,text,bigint) to authenticated;
