-- YummyPro · acceso backend seguro al token Cloudflare guardado en Supabase Vault
-- Staging migration registrada como 20260928172828_custom_domain_cloudflare_vault_secret.
-- No contiene ningún secreto.

create or replace function public.service_get_runtime_secret(p_name text)
returns text
language sql
security definer
set search_path=''
as $$
  select ds.decrypted_secret
  from vault.decrypted_secrets ds
  where ds.name=p_name
  order by ds.updated_at desc nulls last, ds.created_at desc
  limit 1
$$;

revoke all on function public.service_get_runtime_secret(text) from public,anon,authenticated;
grant execute on function public.service_get_runtime_secret(text) to service_role;
