-- YummyPro scalability hardening (staging first)
-- 2026-09-26
-- Goals:
-- 1) Ensure every public FK has a covering leading index.
-- 2) Add composite indexes for the hottest tenant-scoped reads.
-- 3) Make auth.uid() RLS expressions init-plan friendly.
-- 4) Add server-side paginated customer directory for Admin.

create index if not exists restaurant_products_restaurant_sort_idx
  on public.restaurant_products (restaurant_id, sort_order, id);

create index if not exists restaurant_categories_restaurant_sort_idx
  on public.restaurant_categories (restaurant_id, sort_order, id);

create index if not exists restaurant_staff_user_active_restaurant_idx
  on public.restaurant_staff (user_id, active, restaurant_id);

create index if not exists restaurant_staff_restaurant_active_idx
  on public.restaurant_staff (restaurant_id, active, user_id);

create index if not exists customer_profiles_created_idx
  on public.customer_profiles (created_at desc, user_id);

create index if not exists restaurant_orders_customer_created_idx
  on public.restaurant_orders (customer_id, created_at desc)
  where customer_id is not null;

create index if not exists professional_appointments_customer_created_idx
  on public.professional_appointments (customer_id, created_at desc)
  where customer_id is not null;

create index if not exists streaming_orders_customer_created_idx
  on public.streaming_orders (customer_user_id, created_at desc)
  where customer_user_id is not null;

create index if not exists restaurant_inventory_items_restaurant_active_idx
  on public.restaurant_inventory_items (restaurant_id, active, name);

create index if not exists restaurant_promotions_restaurant_created_idx
  on public.restaurant_promotions (restaurant_id, created_at desc);

-- Add a leading btree index for each FK that still lacks one.
do $$
declare
  r record;
  v_index_name text;
  v_cols text;
begin
  for r in
    with fk as (
      select c.oid,c.conrelid,n.nspname,t.relname,c.conname,c.conkey,
             array_agg(a.attname order by u.ord) as cols
      from pg_constraint c
      join pg_class t on t.oid=c.conrelid
      join pg_namespace n on n.oid=t.relnamespace
      join unnest(c.conkey) with ordinality u(attnum,ord) on true
      join pg_attribute a on a.attrelid=c.conrelid and a.attnum=u.attnum
      where c.contype='f' and n.nspname='public'
      group by c.oid,c.conrelid,n.nspname,t.relname,c.conname,c.conkey
    )
    select *
    from fk
    where not exists (
      select 1
      from pg_index i
      where i.indrelid=fk.conrelid
        and i.indisvalid
        and i.indisready
        and (i.indkey::smallint[])[0:cardinality(fk.conkey)-1]=fk.conkey
    )
  loop
    select string_agg(format('%I',x),', ')
      into v_cols
    from unnest(r.cols) x;
    v_index_name := left('idx_'||r.relname||'_'||substr(md5(r.conname),1,8)||'_fk',63);
    execute format('create index if not exists %I on %I.%I (%s)',
                   v_index_name,r.nspname,r.relname,v_cols);
  end loop;
end
$$;

-- Supabase/Postgres evaluates a scalar subselect once per statement instead of once per row.
-- Preserve every policy's semantics; only wrap auth.uid()/auth.role()/auth.jwt() in SELECT.
do $$
declare
  p record;
  q text;
  wc text;
  stmt text;
begin
  for p in
    select schemaname,tablename,policyname,qual,with_check
    from pg_policies
    where schemaname='public'
      and (
        position('auth.uid()' in coalesce(qual,''))>0
        or position('auth.uid()' in coalesce(with_check,''))>0
        or position('auth.role()' in coalesce(qual,''))>0
        or position('auth.role()' in coalesce(with_check,''))>0
        or position('auth.jwt()' in coalesce(qual,''))>0
        or position('auth.jwt()' in coalesce(with_check,''))>0
      )
  loop
    q := p.qual;
    wc := p.with_check;
    if q is not null then
      q := replace(q,'auth.uid()','(select auth.uid())');
      q := replace(q,'auth.role()','(select auth.role())');
      q := replace(q,'auth.jwt()','(select auth.jwt())');
    end if;
    if wc is not null then
      wc := replace(wc,'auth.uid()','(select auth.uid())');
      wc := replace(wc,'auth.role()','(select auth.role())');
      wc := replace(wc,'auth.jwt()','(select auth.jwt())');
    end if;
    stmt := format('alter policy %I on %I.%I',p.policyname,p.schemaname,p.tablename);
    if q is not null then stmt := stmt || ' using (' || q || ')'; end if;
    if wc is not null then stmt := stmt || ' with check (' || wc || ')'; end if;
    execute stmt;
  end loop;
end
$$;

create or replace function public.admin_customer_directory_page(
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
  if not public.is_site_admin() then
    raise exception 'No autorizado';
  end if;

  with filtered_profiles as (
    select c.*
    from public.customer_profiles c
    where
      (
        v_search is null
        or coalesce(c.full_name,'') ilike '%'||v_search||'%'
        or coalesce(c.phone,'') ilike '%'||v_search||'%'
        or exists (
          select 1 from public.restaurant_orders o
          where o.customer_id=c.user_id
            and coalesce(o.customer_email,'') ilike '%'||v_search||'%'
          union all
          select 1 from public.retail_online_orders o
          where o.customer_id=c.user_id
            and coalesce(o.customer_email,'') ilike '%'||v_search||'%'
          union all
          select 1 from public.professional_appointments a
          where a.customer_id=c.user_id
            and coalesce(a.customer_email,'') ilike '%'||v_search||'%'
        )
      )
      and (
        (v_type is null and p_restaurant_id is null)
        or exists (
          select 1
          from (
            select o.customer_id, o.restaurant_id
            from public.restaurant_orders o
            where o.customer_id=c.user_id
            union all
            select o.customer_id, o.restaurant_id
            from public.retail_online_orders o
            where o.customer_id=c.user_id
            union all
            select a.customer_id, a.restaurant_id
            from public.professional_appointments a
            where a.customer_id=c.user_id
            union all
            select o.customer_user_id, o.restaurant_id
            from public.streaming_orders o
            where o.customer_user_id=c.user_id
          ) a
          join public.restaurants r on r.id=a.restaurant_id
          where (p_restaurant_id is null or a.restaurant_id=p_restaurant_id)
            and (v_type is null or r.business_type=v_type)
        )
      )
  ),
  page as (
    select *
    from filtered_profiles
    order by created_at desc, user_id
    offset v_offset
    limit v_limit
  ),
  activity as (
    select o.customer_id as user_id,o.restaurant_id,o.customer_email
    from public.restaurant_orders o
    join page p on p.user_id=o.customer_id
    union all
    select o.customer_id,o.restaurant_id,o.customer_email
    from public.retail_online_orders o
    join page p on p.user_id=o.customer_id
    union all
    select a.customer_id,a.restaurant_id,a.customer_email
    from public.professional_appointments a
    join page p on p.user_id=a.customer_id
    union all
    select o.customer_user_id,o.restaurant_id,null::text
    from public.streaming_orders o
    join page p on p.user_id=o.customer_user_id
  ),
  agg as (
    select
      a.user_id,
      count(*)::bigint as activities,
      max(nullif(a.customer_email,'')) as email,
      coalesce(jsonb_agg(distinct a.restaurant_id) filter (where a.restaurant_id is not null),'[]'::jsonb) as restaurant_ids,
      coalesce(jsonb_agg(distinct r.business_type) filter (where r.business_type is not null),'[]'::jsonb) as business_types
    from activity a
    left join public.restaurants r on r.id=a.restaurant_id
    group by a.user_id
  )
  select jsonb_build_object(
    'total',(select count(*) from filtered_profiles),
    'rows',coalesce((
      select jsonb_agg(
        to_jsonb(p)
        || jsonb_build_object(
          'orders',coalesce(a.activities,0),
          'email',coalesce(a.email,''),
          'restaurantIds',coalesce(a.restaurant_ids,'[]'::jsonb),
          'businessTypes',coalesce(a.business_types,'[]'::jsonb)
        )
        order by p.created_at desc,p.user_id
      )
      from page p
      left join agg a on a.user_id=p.user_id
    ),'[]'::jsonb)
  )
  into v_result;

  return v_result;
end
$function$;

revoke all on function public.admin_customer_directory_page(integer,integer,text,text,bigint) from public, anon;
grant execute on function public.admin_customer_directory_page(integer,integer,text,text,bigint) to authenticated;

analyze public.restaurant_products;
analyze public.restaurant_categories;
analyze public.restaurant_orders;
analyze public.retail_online_orders;
analyze public.professional_appointments;
analyze public.streaming_orders;
analyze public.customer_profiles;
analyze public.restaurant_staff;
