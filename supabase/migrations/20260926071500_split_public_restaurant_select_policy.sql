-- Pruebas: evitar que la política pública de restaurantes ejecute funciones administrativas.
-- anon solo puede leer negocios activos; authenticated conserva acceso ampliado para administradores.

drop policy if exists "restaurants select" on public.restaurants;
drop policy if exists "restaurants select public active" on public.restaurants;
drop policy if exists "restaurants select authenticated" on public.restaurants;

create policy "restaurants select public active"
on public.restaurants
for select
to anon
using (active = true);

create policy "restaurants select authenticated"
on public.restaurants
for select
to authenticated
using (active = true or public.is_system_manager());
