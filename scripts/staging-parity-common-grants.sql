with
tgrants as (
  select grantee,table_schema,table_name,privilege_type
  from information_schema.role_table_grants
  where table_schema in ('public','storage')
    and grantee in ('anon','authenticated','service_role')
    and not (table_schema='public' and table_name='business_custom_domains')
),
seqg as (
  select grantee,object_schema,object_name,privilege_type
  from information_schema.role_usage_grants
  where object_type='SEQUENCE'
    and object_schema='public'
    and grantee in ('anon','authenticated','service_role')
    and object_name <> 'business_custom_domains_id_seq'
)
select concat_ws('|',
  (select md5(string_agg(
    concat_ws('|',grantee,table_schema,table_name,privilege_type),
    E'\n' order by grantee,table_schema,table_name,privilege_type
  )) from tgrants),
  (select md5(string_agg(
    concat_ws('|',grantee,object_schema,object_name,privilege_type),
    E'\n' order by grantee,object_name,privilege_type
  )) from seqg)
);
