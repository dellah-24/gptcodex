-- Adds admin-managed subscriptions and shop administration to an existing
-- ZWConnect Supabase project while keeping billing data hidden from workers.

do $$ begin
  create type public.subscription_status as enum ('trial','active','past_due','suspended','cancelled');
exception when duplicate_object then null;
end $$;

create table if not exists public.shop_subscriptions (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  amount numeric(14,2) not null default 0 check (amount >= 0),
  currency text not null default 'USD',
  duration_days integer not null default 30 check (duration_days > 0),
  trial_ends_at timestamptz,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  status public.subscription_status not null default 'trial',
  notes text,
  updated_by uuid references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);

alter table public.audit_events drop constraint if exists audit_events_shop_id_fkey;
alter table public.audit_events add constraint audit_events_shop_id_fkey
  foreign key (shop_id) references public.shops(id) on delete set null;

create or replace function public.set_shop_subscription(
  target_shop uuid,
  subscription_amount numeric,
  subscription_duration_days integer,
  trial_days integer default 0,
  new_status public.subscription_status default 'active'
)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may manage subscriptions'; end if;
  if subscription_amount < 0 or subscription_duration_days < 1 or trial_days < 0 then
    raise exception 'Invalid subscription amount, duration or trial period';
  end if;
  insert into public.shop_subscriptions(shop_id,amount,duration_days,trial_ends_at,starts_at,ends_at,status,updated_by,updated_at)
  values(target_shop,subscription_amount,subscription_duration_days,
    case when trial_days > 0 then now() + make_interval(days=>trial_days) end,
    now(),now() + make_interval(days=>subscription_duration_days),new_status,auth.uid(),now())
  on conflict(shop_id) do update set
    amount=excluded.amount,duration_days=excluded.duration_days,trial_ends_at=excluded.trial_ends_at,
    starts_at=excluded.starts_at,ends_at=excluded.ends_at,status=excluded.status,
    updated_by=excluded.updated_by,updated_at=now();
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata)
  values(auth.uid(),'shop_subscription.updated','shop_subscription',target_shop::text,target_shop,
    jsonb_build_object('amount',subscription_amount,'duration_days',subscription_duration_days,'trial_days',trial_days,'status',new_status));
end $$;

revoke execute on function public.set_shop_subscription(uuid,numeric,integer,integer,public.subscription_status) from public,anon;
grant execute on function public.set_shop_subscription(uuid,numeric,integer,integer,public.subscription_status) to authenticated;

alter table public.shop_subscriptions enable row level security;

drop policy if exists "admins manage shops" on public.shops;
create policy "admins manage shops" on public.shops for all
  using(public.is_site_admin()) with check(public.is_site_admin());

drop policy if exists "admins manage subscriptions" on public.shop_subscriptions;
create policy "admins manage subscriptions" on public.shop_subscriptions for all
  using(public.is_site_admin()) with check(public.is_site_admin());

drop policy if exists "owners read own subscription" on public.shop_subscriptions;
create policy "owners read own subscription" on public.shop_subscriptions for select
  using(public.owns_shop(shop_id));
