-- YummyPro environment runtime configuration.
-- Environment-specific values live in private.runtime_config and are not hardcoded in shared migrations.

create schema if not exists private;

create table if not exists private.runtime_config(
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

revoke all on table private.runtime_config from public, anon, authenticated;

create or replace function private.edge_functions_base_url()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select rc.value from private.runtime_config rc where rc.key='edge_functions_base_url'),
    'https://gulctljitzlwokqydigx.supabase.co/functions/v1'
  );
$$;

revoke all on function private.edge_functions_base_url() from public, anon, authenticated;
