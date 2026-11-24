-- Hosted recipient profiles, dynamic card updates, lead exchange and owner analytics.

create table public.tapcard_cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_card_id text not null check (length(local_card_id) between 8 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]{8,32}$'),
  label text not null default 'Personal',
  name text not null check (length(name) between 1 and 120),
  title text not null default '',
  company text not null default '',
  phone text not null default '',
  email text not null default '',
  website text not null default '',
  linkedin text not null default '',
  instagram text not null default '',
  whatsapp text not null default '',
  booking_url text not null default '',
  bio text not null default '' check (length(bio) <= 240),
  address text not null default '',
  theme text not null default 'green' check (theme in ('green','blue','purple','charcoal')),
  is_published boolean not null default false,
  view_count bigint not null default 0 check (view_count >= 0),
  last_viewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, local_card_id)
);
create index tapcard_cards_owner_idx on public.tapcard_cards (user_id, updated_at desc);
create index tapcard_cards_published_slug_idx on public.tapcard_cards (slug) where is_published;

alter table public.tapcard_cards enable row level security;
revoke all on public.tapcard_cards from anon;
grant select, delete on public.tapcard_cards to authenticated;
grant insert (user_id, local_card_id, slug, label, name, title, company, phone, email,
  website, linkedin, instagram, whatsapp, booking_url, bio, address, theme, is_published, updated_at)
  on public.tapcard_cards to authenticated;
grant update (slug, label, name, title, company, phone, email, website, linkedin,
  instagram, whatsapp, booking_url, bio, address, theme, is_published, updated_at)
  on public.tapcard_cards to authenticated;

create or replace function public.tapcard_has_hosted_access(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tapcard_subscriptions s
    where s.user_id = target_user_id
      and s.plan <> 'free'
      and s.status in ('active','trialing')
      and case when s.status = 'trialing'
        then s.trial_ends_at >= now()
        else s.current_period_end >= now()
      end
  );
$$;

create policy "card owner reads" on public.tapcard_cards
for select to authenticated using (user_id = auth.uid() or public.tapcard_is_admin());
create policy "card owner creates" on public.tapcard_cards
for insert to authenticated with check (
  user_id = auth.uid() and (not is_published or public.tapcard_has_hosted_access(auth.uid()))
);
create policy "card owner updates" on public.tapcard_cards
for update to authenticated using (user_id = auth.uid()) with check (
  user_id = auth.uid() and (not is_published or public.tapcard_has_hosted_access(auth.uid()))
);
create policy "card owner deletes" on public.tapcard_cards
for delete to authenticated using (user_id = auth.uid());

create or replace function public.tapcard_get_public_card(card_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare card public.tapcard_cards;
begin
  if card_slug !~ '^[a-z0-9]{8,32}$' then return null; end if;
  update public.tapcard_cards
  set view_count = view_count + 1, last_viewed_at = now()
  where slug = card_slug and is_published and public.tapcard_has_hosted_access(user_id)
  returning * into card;
  if card.id is null then return null; end if;
  return jsonb_build_object(
    'slug', card.slug, 'name', card.name, 'title', card.title, 'company', card.company,
    'phone', card.phone, 'email', card.email, 'website', card.website,
    'linkedin', card.linkedin, 'instagram', card.instagram, 'whatsapp', card.whatsapp,
    'booking_url', card.booking_url, 'bio', card.bio, 'address', card.address,
    'theme', card.theme, 'updated_at', card.updated_at
  );
end;
$$;

create or replace function public.tapcard_submit_lead(
  card_slug text,
  lead_name text,
  lead_email text default '',
  lead_phone text default '',
  lead_company text default '',
  lead_note text default '',
  consent boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare card public.tapcard_cards; lead_id uuid;
begin
  if not consent then raise exception 'consent is required'; end if;
  if length(trim(lead_name)) not between 2 and 120 then raise exception 'enter your full name'; end if;
  if trim(lead_email) = '' and trim(lead_phone) = '' then raise exception 'email or phone is required'; end if;
  if trim(lead_email) <> '' and trim(lead_email) !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'enter a valid email address';
  end if;
  if trim(lead_phone) <> '' and length(regexp_replace(lead_phone, '\D', '', 'g')) < 7 then
    raise exception 'enter a valid phone number';
  end if;
  if length(lead_email) > 200 or length(lead_phone) > 40 or length(lead_company) > 120 or length(lead_note) > 500 then
    raise exception 'lead details are too long';
  end if;
  select * into card from public.tapcard_cards
  where slug = card_slug and is_published and public.tapcard_has_hosted_access(user_id);
  if card.id is null then raise exception 'card not found'; end if;
  if (select count(*) from public.tapcard_leads
      where owner_id = card.user_id and card_id = card.local_card_id
        and ((trim(lead_email) <> '' and lower(email) = lower(trim(lead_email)))
          or (trim(lead_email) = '' and phone = trim(lead_phone)))
        and created_at >= now() - interval '1 day') >= 5 then
    raise exception 'please try again later';
  end if;
  insert into public.tapcard_leads
    (owner_id, card_id, full_name, email, phone, company, notes, consent_to_contact, source)
  values
    (card.user_id, card.local_card_id, trim(lead_name), trim(lead_email), trim(lead_phone),
     trim(lead_company), trim(lead_note), true, 'public_profile')
  returning id into lead_id;
  return lead_id;
end;
$$;

create or replace function public.tapcard_my_dashboard()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'published_cards', (select count(*) from public.tapcard_cards where user_id = auth.uid() and is_published),
    'total_views', (select coalesce(sum(view_count),0) from public.tapcard_cards where user_id = auth.uid()),
    'total_leads', (select count(*) from public.tapcard_leads where owner_id = auth.uid())
  );
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
    'profile_views', (select coalesce(sum(view_count),0) from public.tapcard_cards),
    'captured_leads', (select count(*) from public.tapcard_leads),
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
       (select max(e.created_at) from public.tapcard_analytics_events e where e.user_id = p.user_id) as last_active_at,
       (select count(*) from public.tapcard_cards c where c.user_id = p.user_id and c.is_published) as published_cards,
       (select coalesce(sum(c.view_count),0) from public.tapcard_cards c where c.user_id = p.user_id) as profile_views,
       (select count(*) from public.tapcard_leads l where l.owner_id = p.user_id) as captured_leads
from public.tapcard_profiles p
join public.tapcard_subscriptions s using (user_id);

revoke execute on function public.tapcard_get_public_card(text) from public;
revoke execute on function public.tapcard_submit_lead(text,text,text,text,text,text,boolean) from public;
revoke execute on function public.tapcard_my_dashboard() from public, anon;
revoke execute on function public.tapcard_has_hosted_access(uuid) from public, anon;
grant execute on function public.tapcard_has_hosted_access(uuid) to authenticated;
grant execute on function public.tapcard_get_public_card(text) to anon, authenticated;
grant execute on function public.tapcard_submit_lead(text,text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.tapcard_my_dashboard() to authenticated;
grant select on public.tapcard_admin_user_overview to authenticated;
revoke execute on function public.tapcard_admin_dashboard_metrics() from public, anon;
grant execute on function public.tapcard_admin_dashboard_metrics() to authenticated;
