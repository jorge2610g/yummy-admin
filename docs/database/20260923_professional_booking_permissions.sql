-- YummyPro · permisos mínimos para el módulo Profesional / Servicios
-- Aplicado al proyecto gulctljitzlwokqydigx el 2026-09-23.

begin;

revoke all on table
  public.professional_services,
  public.professional_providers,
  public.professional_provider_services,
  public.professional_availability,
  public.professional_time_off,
  public.professional_appointments
from anon;

revoke all on table
  public.professional_services,
  public.professional_providers,
  public.professional_provider_services,
  public.professional_availability,
  public.professional_time_off,
  public.professional_appointments
from authenticated;

grant select, insert, update, delete on table
  public.professional_services,
  public.professional_providers,
  public.professional_provider_services,
  public.professional_availability,
  public.professional_time_off,
  public.professional_appointments
to authenticated;

revoke all on function public.create_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) from public, anon;
grant execute on function public.create_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) to authenticated, service_role;

revoke all on function public.get_professional_public_catalog(bigint) from public;
grant execute on function public.get_professional_public_catalog(bigint) to anon, authenticated, service_role;

revoke all on function public.get_public_professional_catalog(text) from public;
grant execute on function public.get_public_professional_catalog(text) to anon, authenticated, service_role;

revoke all on function public.get_professional_available_slots(bigint,bigint,bigint,date) from public;
grant execute on function public.get_professional_available_slots(bigint,bigint,bigint,date) to anon, authenticated, service_role;

revoke all on function public.create_public_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) from public;
grant execute on function public.create_public_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text) to anon, authenticated, service_role;

commit;
