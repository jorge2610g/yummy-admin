with
cols as (
 select table_schema,table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,coalesce(column_default,'') d
 from information_schema.columns where table_schema in ('public','storage','private')
),
pols as (
 select schemaname,tablename,policyname,permissive,roles::text roles,cmd,coalesce(qual,'') qual,coalesce(with_check,'') with_check
 from pg_policies where schemaname in ('public','storage')
),
funcs as (
 select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args,p.prosecdef,pg_get_functiondef(p.oid) def
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','private') and p.prokind in ('f','p')
),
trigs as (
 select n.nspname,c.relname,t.tgname,pg_get_triggerdef(t.oid) def
 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
 where not t.tgisinternal and n.nspname in ('public','private')
),
tgrants as (
 select grantee,table_schema,table_name,privilege_type
 from information_schema.role_table_grants
 where table_schema in ('public','storage') and grantee in ('anon','authenticated','service_role')
),
seqg as (
 select grantee,object_schema,object_name,privilege_type
 from information_schema.role_usage_grants
 where object_type='SEQUENCE' and object_schema='public' and grantee in ('anon','authenticated','service_role')
),
fx as (
 select r.role,n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args,
        has_function_privilege(r.role,p.oid,'EXECUTE') can_exec
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 cross join (values ('anon'),('authenticated'),('service_role')) r(role)
 where n.nspname='public' and p.prokind in ('f','p')
),
dacl as (
 select pg_get_userbyid(defaclrole) owner,coalesce((select nspname from pg_namespace where oid=defaclnamespace),'') schema_name,
        defaclobjtype,defaclacl::text acl
 from pg_default_acl
),
exts as (select extname,extversion from pg_extension),
b as (select id,name,public,file_size_limit,allowed_mime_types from storage.buckets),
h as (
 select
  md5(string_agg(concat_ws('|',table_schema,table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,d),E'\n' order by table_schema,table_name,ordinal_position)) columns_hash,
  (select md5(string_agg(concat_ws('|',schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check),E'\n' order by schemaname,tablename,policyname)) from pols) policies_hash,
  (select md5(string_agg(concat_ws('|',nspname,proname,args,prosecdef,def),E'\n' order by nspname,proname,args)) from funcs) functions_hash,
  (select md5(string_agg(concat_ws('|',nspname,relname,tgname,def),E'\n' order by nspname,relname,tgname)) from trigs) triggers_hash,
  (select md5(string_agg(concat_ws('|',grantee,table_schema,table_name,privilege_type),E'\n' order by grantee,table_schema,table_name,privilege_type)) from tgrants) table_grants_hash,
  (select md5(string_agg(concat_ws('|',grantee,object_schema,object_name,privilege_type),E'\n' order by grantee,object_name,privilege_type)) from seqg) sequence_grants_hash,
  (select md5(string_agg(concat_ws('|',role,nspname,proname,args,can_exec),E'\n' order by role,nspname,proname,args)) from fx) routine_effective_hash,
  (select md5(string_agg(concat_ws('|',owner,schema_name,defaclobjtype,acl),E'\n' order by owner,schema_name,defaclobjtype)) from dacl) default_acl_hash,
  (select md5(string_agg(concat_ws('|',extname,extversion),E'\n' order by extname)) from exts) extension_hash,
  (select md5(string_agg(concat_ws('|',id,name,public,file_size_limit,allowed_mime_types::text),E'\n' order by id)) from b) bucket_hash
 from cols
)
select concat_ws('|',columns_hash,policies_hash,functions_hash,triggers_hash,table_grants_hash,sequence_grants_hash,routine_effective_hash,default_acl_hash,extension_hash,bucket_hash)
from h;
