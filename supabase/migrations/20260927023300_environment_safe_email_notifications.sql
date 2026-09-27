-- YummyPro environment-safe email notification dispatch.
-- The default remains Production. Staging overrides app.settings.edge_functions_base_url at DB level.

create schema if not exists private;

create or replace function private.edge_functions_base_url()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('app.settings.edge_functions_base_url', true), ''),
    'https://gulctljitzlwokqydigx.supabase.co/functions/v1'
  );
$$;

revoke all on function private.edge_functions_base_url() from public;

create or replace function public.notify_new_restaurant_by_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := private.edge_functions_base_url() || '/restaurant-email-notifications';
begin
  if new.role = 'restaurant' and new.active = true then
    perform net.http_post(
      url := v_url,
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object(
        'restaurant_id', new.restaurant_id,
        'event_type', 'welcome',
        'event_key', 'welcome:' || new.restaurant_id::text
      )
    );
    perform net.http_post(
      url := v_url,
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object(
        'restaurant_id', new.restaurant_id,
        'event_type', 'trial_started',
        'event_key', 'trial-start:' || new.restaurant_id::text
      )
    );
  end if;
  return new;
end;
$$;

create or replace function public.process_subscription_email_reminders()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec record;
  local_today date;
  local_expiry date;
  diff integer;
  event_type text;
  v_url text := private.edge_functions_base_url() || '/restaurant-email-notifications';
begin
  for rec in
    select id, subscription_expires_at, coalesce(timezone,'America/Santiago') as tz, subscription_status
    from public.restaurants
    where subscription_expires_at is not null
      and coalesce(subscription_status,'') in ('trial','active')
  loop
    local_today := (now() at time zone rec.tz)::date;
    local_expiry := (rec.subscription_expires_at at time zone rec.tz)::date;
    diff := local_expiry - local_today;
    event_type := case
      when diff = 7 then 'expiring_7d'
      when diff = 1 then 'expiring_1d'
      when diff <= 0 then 'expired'
      else null
    end;

    if event_type is not null then
      perform net.http_post(
        url := v_url,
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object(
          'restaurant_id', rec.id,
          'event_type', event_type,
          'event_key', event_type || ':' || rec.id::text || ':' || rec.subscription_expires_at::text
        )
      );

      if event_type = 'expired' then
        update public.restaurants
        set subscription_status='expired'
        where id=rec.id;
      end if;
    end if;
  end loop;
end;
$$;
