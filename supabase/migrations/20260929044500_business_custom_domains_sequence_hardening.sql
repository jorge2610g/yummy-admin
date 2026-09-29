-- YummyPro · Hardening de secuencia para dominios personalizados en Staging.
-- La tabla es service-only; su secuencia tampoco debe ser utilizable por clientes.
revoke all on sequence public.business_custom_domains_id_seq from anon, authenticated;
grant usage, select on sequence public.business_custom_domains_id_seq to service_role;
