-- TapCard ZW commercial platform foundation.
-- Apply with the Supabase CLI or paste into the Supabase SQL editor.

create extension if not exists pgcrypto;

create type public.tapcard_app_role as enum ('customer', 'admin');
create type public.tapcard_plan_code as enum ('free', 'pro', 'business');
create type public.tapcard_subscription_status as enum ('active', 'trialing', 'past_due', 'cancelled', 'expired');
create type public.tapcard_billing_source as enum ('manual', 'google_play', 'promo');

create table public.tapcard_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null default '',
  company_name text not null default '',
  avatar_url text,
  role public.tapcard_app_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tapcard_subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan public.tapcard_plan_code not null default 'free',
  status public.tapcard_subscription_status not null default 'active',
  source public.tapcard_billing_source not null default 'manual',
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  google_purchase_token_hash text unique,
  notes text not null default '',
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint paid_plan_requires_expiry check (
    plan = 'free' or trial_ends_at is not null or current_period_end is not null
  )
);

create table public.tapcard_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  install_id uuid not null,
  app_version text not null default '',
  device_model text not null default '',
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, install_id)
);

create table public.tapcard_analytics_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  install_id uuid not null,
  card_id text,
  event_name text not null check (length(event_name) between 2 and 64),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index tapcard_analytics_events_created_idx on public.tapcard_analytics_events (created_at desc);
create index tapcard_analytics_events_user_created_idx on public.tapcard_analytics_events (user_id, created_at desc);

create table public.tapcard_leads (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  card_id text,
  full_name text not null,
  email text,
  phone text,
  company text,
  notes text not null default '',
  consent_to_contact boolean not null default false,
  source text not null default 'card',
  created_at timestamptz not null default now()
);
create index tapcard_leads_owner_created_idx on public.tapcard_leads (owner_id, created_at desc);

create table public.tapcard_support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject text not null check (length(subject) between 3 and 120),
  message text not null check (length(message) between 3 and 5000),
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved')),
  admin_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tapcard_admin_audit_log (
  id bigint generated always as identity primary key,
  admin_id uuid not null references auth.users(id) on delete restrict,
  action text not null,
  target_user_id uuid references auth.users(id) on delete set null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.tapcard_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tapcard_profiles
    where user_id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.tapcard_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.tapcard_profiles (user_id, email, display_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  insert into public.tapcard_subscriptions (user_id) values (new.id);
  return new;
end;
$$;

create trigger tapcard_on_auth_user_created
after insert on auth.users
for each row execute procedure public.tapcard_handle_new_user();

alter table public.tapcard_profiles enable row level security;
alter table public.tapcard_subscriptions enable row level security;
alter table public.tapcard_devices enable row level security;
alter table public.tapcard_analytics_events enable row level security;
alter table public.tapcard_leads enable row level security;
alter table public.tapcard_support_tickets enable row level security;
alter table public.tapcard_admin_audit_log enable row level security;

revoke all on public.tapcard_profiles, public.tapcard_subscriptions, public.tapcard_devices,
  public.tapcard_analytics_events, public.tapcard_leads, public.tapcard_support_tickets,
  public.tapcard_admin_audit_log from anon;
grant select on public.tapcard_profiles, public.tapcard_subscriptions, public.tapcard_devices,
  public.tapcard_analytics_events, public.tapcard_leads, public.tapcard_support_tickets,
  public.tapcard_admin_audit_log to authenticated;
grant insert, update, delete on public.tapcard_devices, public.tapcard_leads to authenticated;
grant insert on public.tapcard_analytics_events, public.tapcard_support_tickets to authenticated;
grant update on public.tapcard_support_tickets to authenticated;
grant usage, select on sequence public.tapcard_analytics_events_id_seq to authenticated;

create policy "profile owner or admin reads" on public.tapcard_profiles
for select to authenticated using (user_id = auth.uid() or public.tapcard_is_admin());
create policy "profile owner updates" on public.tapcard_profiles
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "subscription owner or admin reads" on public.tapcard_subscriptions
for select to authenticated using (user_id = auth.uid() or public.tapcard_is_admin());

create policy "device owner manages" on public.tapcard_devices
for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "admin reads devices" on public.tapcard_devices
for select to authenticated using (public.tapcard_is_admin());

create policy "event owner inserts" on public.tapcard_analytics_events
for insert to authenticated with check (user_id = auth.uid());
create policy "event owner or admin reads" on public.tapcard_analytics_events
for select to authenticated using (user_id = auth.uid() or public.tapcard_is_admin());

create policy "lead owner manages" on public.tapcard_leads
for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "admin reads leads" on public.tapcard_leads
for select to authenticated using (public.tapcard_is_admin());

create policy "ticket owner reads" on public.tapcard_support_tickets
for select to authenticated using (user_id = auth.uid() or public.tapcard_is_admin());
create policy "ticket owner creates" on public.tapcard_support_tickets
for insert to authenticated with check (user_id = auth.uid());
create policy "admin updates tickets" on public.tapcard_support_tickets
for update to authenticated using (public.tapcard_is_admin()) with check (public.tapcard_is_admin());

create policy "admin reads audit log" on public.tapcard_admin_audit_log
for select to authenticated using (public.tapcard_is_admin());

grant update (display_name, company_name, avatar_url) on public.tapcard_profiles to authenticated;

create or replace function public.tapcard_admin_set_subscription(
  target_user_id uuid,
  new_plan public.tapcard_plan_code,
  new_status public.tapcard_subscription_status,
  new_trial_ends_at timestamptz default null,
  new_period_end timestamptz default null,
  admin_notes text default ''
)
returns public.tapcard_subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare result public.tapcard_subscriptions;
begin
  if not public.tapcard_is_admin() then raise exception 'admin access required'; end if;
  if new_plan <> 'free' and new_trial_ends_at is null and new_period_end is null then
    raise exception 'paid plans require a trial or period end date';
  end if;
  update public.tapcard_subscriptions
  set plan = new_plan,
      status = new_status,
      source = 'manual',
      trial_ends_at = new_trial_ends_at,
      current_period_end = new_period_end,
      notes = left(coalesce(admin_notes, ''), 1000),
      updated_by = auth.uid(),
      updated_at = now()
  where user_id = target_user_id
  returning * into result;
  if result.user_id is null then raise exception 'subscription not found'; end if;
  insert into public.tapcard_admin_audit_log (admin_id, action, target_user_id, details)
  values (auth.uid(), 'subscription_updated', target_user_id,
    jsonb_build_object('plan', new_plan, 'status', new_status, 'period_end', new_period_end));
  return result;
end;
$$;

create or replace function public.tapcard_admin_dashboard_metrics()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.tapcard_is_admin() then raise exception 'admin access required'; end if;
  return jsonb_build_object(
    'total_users', (select count(*) from public.tapcard_profiles),
    'active_paid', (select count(*) from public.tapcard_subscriptions where plan <> 'free' and status in ('active', 'trialing')),
    'trials', (select count(*) from public.tapcard_subscriptions where status = 'trialing'),
    'past_due', (select count(*) from public.tapcard_subscriptions where status = 'past_due'),
    'events_7d', (select count(*) from public.tapcard_analytics_events where created_at >= now() - interval '7 days'),
    'active_users_30d', (select count(distinct user_id) from public.tapcard_analytics_events where created_at >= now() - interval '30 days'),
    'open_tickets', (select count(*) from public.tapcard_support_tickets where status <> 'resolved')
  );
end;
$$;

create or replace view public.tapcard_admin_user_overview
with (security_invoker = true)
as
select p.user_id, p.email, p.display_name, p.company_name, p.role, p.created_at,
       s.plan, s.status, s.trial_ends_at, s.current_period_end, s.source, s.updated_at,
       (select count(*) from public.tapcard_analytics_events e where e.user_id = p.user_id) as event_count,
       (select max(e.created_at) from public.tapcard_analytics_events e where e.user_id = p.user_id) as last_active_at
from public.tapcard_profiles p
join public.tapcard_subscriptions s using (user_id);

grant select on public.tapcard_admin_user_overview to authenticated;
revoke execute on function public.tapcard_is_admin() from public, anon;
revoke execute on function public.tapcard_handle_new_user() from public, anon, authenticated;
revoke execute on function public.tapcard_admin_dashboard_metrics() from public, anon;
revoke execute on function public.tapcard_admin_set_subscription(uuid, public.tapcard_plan_code, public.tapcard_subscription_status, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.tapcard_is_admin() to authenticated;
grant execute on function public.tapcard_admin_dashboard_metrics() to authenticated;
grant execute on function public.tapcard_admin_set_subscription(uuid, public.tapcard_plan_code, public.tapcard_subscription_status, timestamptz, timestamptz, text) to authenticated;

-- Retain raw analytics for one year. Run this daily with pg_cron if enabled:
-- select cron.schedule('tapcard-analytics-retention', '15 2 * * *',
--   $$delete from public.tapcard_analytics_events where created_at < now() - interval '365 days'$$);
