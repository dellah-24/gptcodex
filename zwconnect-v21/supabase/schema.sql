-- ZWConnect marketplace + POS access model for Supabase/PostgreSQL.
-- Run in a fresh project. The reserved administrator email below is
-- automatically assigned the single site_admin platform role.
create extension if not exists pgcrypto;

create type public.platform_role as enum ('site_admin','shop_owner','worker');
create type public.application_status as enum ('pending','approved','rejected');
create type public.shop_status as enum ('draft','active','suspended');
create type public.worker_job as enum ('branch_manager','cashier','stock_controller','procurement','accountant');
create type public.subscription_status as enum ('trial','active','past_due','suspended','cancelled');

create table public.business_profiles (
  id text primary key,
  title text not null,
  icon text not null,
  description text not null,
  enabled boolean not null default true,
  display_order integer not null default 0
);

create table public.account_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role public.platform_role not null,
  created_at timestamptz not null default now()
);
comment on table public.account_roles is 'One row per auth user guarantees one non-overlapping platform role.';

-- Keep the reserved ZWConnect administrator account mapped to site_admin.
-- A successful login still requires Supabase Auth verification.
create function public.sync_reserved_site_admin()
returns trigger language plpgsql security definer
set search_path=public,auth
as $$
begin
  if lower(new.email) = 'dylankoshita96@gmail.com' then
    insert into public.account_roles(user_id,role)
    values(new.id,'site_admin')
    on conflict(user_id) do update set role='site_admin';
  elsif tg_op = 'UPDATE'
    and lower(coalesce(old.email,'')) = 'dylankoshita96@gmail.com'
    and lower(coalesce(new.email,'')) <> 'dylankoshita96@gmail.com' then
    delete from public.account_roles
    where user_id=new.id and role='site_admin';
  end if;
  return new;
end $$;

create trigger sync_reserved_site_admin_role
after insert or update of email on auth.users
for each row execute function public.sync_reserved_site_admin();

revoke execute on function public.sync_reserved_site_admin() from public,anon,authenticated;

-- Backfill the role when the Auth account already exists.
insert into public.account_roles(user_id,role)
select id,'site_admin' from auth.users
where lower(email)='dylankoshita96@gmail.com'
on conflict(user_id) do update set role='site_admin';

create table public.owner_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id) on delete cascade,
  owner_name text not null,
  email text not null,
  phone text not null,
  business_name text not null,
  profile_id text not null references public.business_profiles(id),
  city text not null,
  address text not null,
  proof_path text,
  proof_name text,
  proof_mime text check (proof_mime is null or proof_mime in ('image/jpeg','image/png','image/webp','application/pdf')),
  proof_size bigint check (proof_size is null or proof_size between 1 and 10485760),
  latitude double precision,
  longitude double precision,
  status public.application_status not null default 'pending',
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  unique (applicant_id, business_name)
);

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  application_id uuid unique references public.owner_applications(id) on delete restrict,
  profile_id text not null references public.business_profiles(id),
  name text not null,
  slug text not null unique,
  phone text,
  city text not null,
  address text not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  opening_hours jsonb not null default '{}',
  image_url text,
  status public.shop_status not null default 'draft',
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.shop_workers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  job public.worker_job not null,
  active boolean not null default true,
  invited_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (shop_id, user_id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  sku text not null,
  name text not null,
  description text,
  price numeric(14,2) not null check (price >= 0),
  quantity numeric(14,3) not null default 0,
  unit text not null default 'each',
  image_url text,
  published boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (shop_id, sku)
);

create table public.product_movements (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid references public.shops(id) on delete set null,
  product_id uuid references public.products(id) on delete set null,
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  reason text not null check (reason in ('sale','restock','return','damage','count')),
  device_id text not null check (char_length(device_id) between 1 and 200),
  created_by uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null,
  synced_at timestamptz not null default now()
);

create table public.shop_subscriptions (
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

create table public.audit_events (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete restrict,
  action text not null,
  entity_type text not null,
  entity_id text not null,
  shop_id uuid references public.shops(id) on delete set null,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

insert into public.business_profiles(id,title,icon,description,display_order) values
('liquor','Bottle Stores & Liquor','wine','Bottle stores, wine merchants and beverage outlets.',1),
('grocery','Supermarkets & Grocery','shopping-cart','Groceries, fresh produce and household essentials.',2),
('butchery','Butcheries','beef','Fresh meat, cuts, bulk packs and frozen goods.',3),
('bakery','Bakeries','croissant','Bread, cakes, pastries and custom orders.',4),
('fashion','Clothing & Fashion','shirt','Fashion stores, boutiques, shoes and accessories.',5),
('cosmetics','Cosmetics & Beauty','sparkles','Makeup, skincare, fragrances and beauty products.',6),
('electronics','Electronics & Phones','smartphone','Phones, devices, accessories and repairs.',7),
('auto','Auto Parts & Spares','car-front','Vehicle spares, tyres, batteries and accessories.',8),
('hardware','Hardware & Building','hammer','Tools, timber, plumbing and building materials.',9),
('pharmacy','Pharmacy & Health','pill','Health essentials and approved pharmacy products.',10),
('hospitality','Restaurants & Cafés','utensils','Restaurants, takeaways, cafés and food outlets.',11),
('salon','Salons & Services','scissors','Salons, barbers and appointment-based services.',12),
('furniture','Furniture & Homeware','sofa','Furniture, appliances and home accessories.',13),
('stationery','Stationery & Bookshops','book-open','Books, stationery, printing and school supplies.',14),
('fuel','Fuel & Forecourt','fuel','Fuel stations, convenience stores and fleet services.',15),
('lpg','LP Gas Retail & Wholesale','flame','Licensed LP gas refills, cylinder exchanges, wholesale supply and safety accessories.',16);

create function public.current_platform_role()
returns public.platform_role language sql stable security definer set search_path=public
as $$ select role from public.account_roles where user_id=auth.uid() $$;

create function public.is_site_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select coalesce(public.current_platform_role()='site_admin',false) $$;

create function public.owns_shop(target_shop uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.shops where id=target_shop and owner_id=auth.uid()) $$;

create function public.works_at_shop(target_shop uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.shop_workers where shop_id=target_shop and user_id=auth.uid() and active) $$;

create function public.enforce_worker_limit()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if new.active and (select count(*) from public.shop_workers where shop_id=new.shop_id and active and id<>new.id) >= 7 then
    raise exception 'A shop may have no more than 7 active worker accounts';
  end if;
  if not exists(select 1 from public.account_roles where user_id=new.user_id and role='worker') then
    raise exception 'The invited user must have the worker platform role';
  end if;
  return new;
end $$;
create trigger shop_worker_limit before insert or update of active,shop_id,user_id on public.shop_workers for each row execute function public.enforce_worker_limit();

create function public.approve_owner_application(application_uuid uuid, shop_slug text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare app public.owner_applications; new_shop uuid;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may approve owners'; end if;
  select * into app from public.owner_applications where id=application_uuid and status='pending' for update;
  if not found then raise exception 'Pending application not found'; end if;
  insert into public.account_roles(user_id,role) values(app.applicant_id,'shop_owner')
    on conflict(user_id) do update set role='shop_owner' where public.account_roles.role='shop_owner';
  if not found then raise exception 'Applicant already has a different platform role'; end if;
  insert into public.shops(owner_id,application_id,profile_id,name,slug,phone,city,address,latitude,longitude,status,verified_at)
    values(app.applicant_id,app.id,app.profile_id,app.business_name,shop_slug,app.phone,app.city,app.address,coalesce(app.latitude,0),coalesce(app.longitude,0),'draft',now()) returning id into new_shop;
  update public.owner_applications set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=app.id;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id) values(auth.uid(),'owner_application.approved','owner_application',app.id::text,new_shop);
  return new_shop;
end $$;

create function public.set_shop_subscription(
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

create function public.apply_product_movement(
  client_event_uuid uuid,
  target_product uuid,
  target_shop uuid,
  target_sku text,
  quantity_delta numeric,
  movement_reason text,
  occurred_at timestamptz,
  source_device text
)
returns numeric language plpgsql security definer set search_path=public
as $$
declare resolved_product uuid; resolved_shop uuid; inserted_rows integer; resulting_quantity numeric;
begin
  if quantity_delta=0 then raise exception 'Product movement cannot be zero'; end if;
  if movement_reason not in ('sale','restock','return','damage','count') then raise exception 'Invalid movement reason'; end if;
  select id,shop_id into resolved_product,resolved_shop from public.products
  where id=target_product or (target_product is null and shop_id=target_shop and sku=target_sku)
  limit 1 for update;
  if not found then raise exception 'Product not found'; end if;
  if not (public.owns_shop(resolved_shop) or public.works_at_shop(resolved_shop)) then
    raise exception 'Not authorised to change this shop stock';
  end if;
  insert into public.product_movements(client_event_id,shop_id,product_id,quantity_delta,reason,device_id,created_by,occurred_at)
  values(client_event_uuid,resolved_shop,resolved_product,quantity_delta,movement_reason,left(source_device,200),auth.uid(),occurred_at)
  on conflict(client_event_id) do nothing;
  get diagnostics inserted_rows=row_count;
  if inserted_rows>0 then
    update public.products set quantity=greatest(0,quantity+quantity_delta),updated_at=now()
    where id=resolved_product returning quantity into resulting_quantity;
  else
    select quantity into resulting_quantity from public.products where id=resolved_product;
  end if;
  return resulting_quantity;
end $$;

revoke execute on function public.apply_product_movement(uuid,uuid,uuid,text,numeric,text,timestamptz,text) from public,anon;
grant execute on function public.apply_product_movement(uuid,uuid,uuid,text,numeric,text,timestamptz,text) to authenticated;

alter table public.business_profiles enable row level security;
alter table public.account_roles enable row level security;
alter table public.owner_applications enable row level security;
alter table public.shops enable row level security;
alter table public.shop_workers enable row level security;
alter table public.products enable row level security;
alter table public.product_movements enable row level security;
alter table public.shop_subscriptions enable row level security;
alter table public.audit_events enable row level security;

create policy "profiles are public" on public.business_profiles for select using(enabled);
create policy "users read own role" on public.account_roles for select using(user_id=auth.uid() or public.is_site_admin());
create policy "applicants submit applications" on public.owner_applications for insert with check(applicant_id=auth.uid());
create policy "applicants read own applications" on public.owner_applications for select using(applicant_id=auth.uid() or public.is_site_admin());
create policy "admins review applications" on public.owner_applications for update using(public.is_site_admin()) with check(public.is_site_admin());
create policy "active shops are public" on public.shops for select using(status='active' or owner_id=auth.uid() or public.works_at_shop(id) or public.is_site_admin());
create policy "owners update their shop" on public.shops for update using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy "admins manage shops" on public.shops for all using(public.is_site_admin()) with check(public.is_site_admin());
create policy "owners and admins read workers" on public.shop_workers for select using(public.owns_shop(shop_id) or public.is_site_admin() or user_id=auth.uid());
create policy "owners manage workers" on public.shop_workers for all using(public.owns_shop(shop_id)) with check(public.owns_shop(shop_id));
create policy "published products are public" on public.products for select using(published and exists(select 1 from public.shops s where s.id=shop_id and s.status='active') or public.owns_shop(shop_id) or public.works_at_shop(shop_id) or public.is_site_admin());
create policy "shop team manages products" on public.products for all using(public.owns_shop(shop_id) or public.works_at_shop(shop_id)) with check(public.owns_shop(shop_id) or public.works_at_shop(shop_id));
create policy "shop team reads product movements" on public.product_movements for select
using(shop_id is not null and (public.owns_shop(shop_id) or public.works_at_shop(shop_id) or public.is_site_admin()));
create policy "admins manage subscriptions" on public.shop_subscriptions for all using(public.is_site_admin()) with check(public.is_site_admin());
create policy "owners read own subscription" on public.shop_subscriptions for select using(public.owns_shop(shop_id));
create policy "admins read audit" on public.audit_events for select using(public.is_site_admin());
create policy "owners read shop audit" on public.audit_events for select using(shop_id is not null and public.owns_shop(shop_id));

-- Private shop proof uploads. Store objects under <auth.uid()>/<application-id>/<filename>.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('shop-proofs','shop-proofs',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy "applicants upload own shop proof" on storage.objects for insert to authenticated
with check(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='products') then
    alter publication supabase_realtime add table public.products;
  end if;
end $$;
create policy "applicants read own shop proof" on storage.objects for select to authenticated
using(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "admins read shop proofs" on storage.objects for select to authenticated
using(bucket_id='shop-proofs' and public.is_site_admin());
create policy "applicants replace own shop proof" on storage.objects for update to authenticated
using(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

-- Worker account creation must run in a Cloudflare Worker or Supabase Edge Function
-- using the service-role key: create auth user -> insert account_roles(worker) ->
-- insert shop_workers. Never expose the service-role key in browser JavaScript.
