-- Impide que un dominio se asigne durante la creación directa de un negocio.
-- La activación solo puede ocurrir desde service_activate_business_custom_domain.

create or replace function private.enforce_verified_custom_domain()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_host text;
begin
  if tg_op = 'UPDATE' and new.custom_domain is not distinct from old.custom_domain then return new; end if;
  if new.custom_domain is null or btrim(new.custom_domain)='' then new.custom_domain:=null; return new; end if;
  v_host:=private.normalize_custom_hostname(new.custom_domain);
  if not exists(select 1 from public.business_custom_domains d
    where d.restaurant_id=new.id and lower(d.hostname)=v_host and d.status='active') then
    raise exception 'El dominio personalizado todavía no está verificado y activo';
  end if;
  new.custom_domain:=v_host;
  return new;
end $$;

drop trigger if exists restaurants_verified_custom_domain_guard on public.restaurants;
create trigger restaurants_verified_custom_domain_guard
before insert or update of custom_domain on public.restaurants
for each row execute function private.enforce_verified_custom_domain();
