-- YummyPro observabilidad — referencia técnica
-- Aplicada en producción: 2026-09-23
-- Migraciones Supabase: observability_trial_intent_analytics + observability_admin_alert_log

alter table public.restaurants
  add column if not exists trial_intended_plan_id bigint references public.subscription_plans(id) on delete set null,
  add column if not exists trial_intended_plan_selected_at timestamptz;

create table if not exists public.app_events (
  id bigserial primary key,
  occurred_at timestamptz not null default now(),
  app_context text not null check (app_context in ('landing','restaurant','client','admin')),
  event_name text not null,
  module text,
  restaurant_id bigint references public.restaurants(id) on delete set null,
  user_id uuid,
  plan_id bigint references public.subscription_plans(id) on delete set null,
  session_id text,
  route text,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.app_errors (
  id bigserial primary key,
  occurred_at timestamptz not null default now(),
  app_context text not null check (app_context in ('landing','restaurant','client','admin')),
  category text not null default 'system',
  error_code text,
  message text,
  severity text not null default 'error' check (severity in ('info','warning','error','critical')),
  is_user_error boolean not null default false,
  restaurant_id bigint references public.restaurants(id) on delete set null,
  user_id uuid,
  session_id text,
  route text,
  metadata jsonb not null default '{}'::jsonb,
  resolved boolean not null default false,
  resolved_at timestamptz,
  resolution_note text
);

create table if not exists public.user_issue_reports (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  app_context text not null check (app_context in ('restaurant','client')),
  restaurant_id bigint references public.restaurants(id) on delete set null,
  user_id uuid,
  title text not null,
  description text not null,
  route text,
  metadata jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  resolved_at timestamptz,
  resolution_note text
);

create table if not exists public.observability_alert_log (
  id bigserial primary key,
  alert_key text not null unique,
  alert_type text not null,
  sent_at timestamptz not null default now(),
  recipient_count integer not null default 0,
  metadata jsonb not null default '{}'::jsonb
);

-- En producción también existen índices, RLS, REVOKE/GRANT y las funciones:
-- public.log_app_event(...)
-- public.log_app_error(...)
-- public.submit_issue_report(...)
-- public.admin_observability_summary(integer,bigint)
-- public.admin_plan_recommendations(integer)
-- public.create_my_trial_restaurant_v2(text,text,text,text,bigint)
--
-- Importante: antes de recrear funciones SECURITY DEFINER, revisar search_path,
-- permisos EXECUTE y la implementación actual en Supabase. No copiar secretos
-- de Edge Functions dentro del repositorio.
