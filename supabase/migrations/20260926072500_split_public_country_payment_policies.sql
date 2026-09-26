-- Pruebas: separar lectura pública de helpers administrativos para evitar 401 en anon.

drop policy if exists "countries select" on public.platform_countries;
drop policy if exists "countries select public active" on public.platform_countries;
drop policy if exists "countries select authenticated" on public.platform_countries;

create policy "countries select public active"
on public.platform_countries
for select
to anon
using (active = true);

create policy "countries select authenticated"
on public.platform_countries
for select
to authenticated
using (active = true or public.is_site_admin());

drop policy if exists "payment methods select" on public.restaurant_payment_methods;
drop policy if exists "payment methods select public active" on public.restaurant_payment_methods;
drop policy if exists "payment methods select authenticated" on public.restaurant_payment_methods;

create policy "payment methods select public active"
on public.restaurant_payment_methods
for select
to anon
using (
  active
  and exists (
    select 1 from public.restaurants r
    where r.id = restaurant_payment_methods.restaurant_id
      and r.active
  )
);

create policy "payment methods select authenticated"
on public.restaurant_payment_methods
for select
to authenticated
using (
  (
    active
    and exists (
      select 1 from public.restaurants r
      where r.id = restaurant_payment_methods.restaurant_id
        and r.active
    )
  )
  or public.can_manage_restaurant(restaurant_id)
  or public.is_site_admin()
);
