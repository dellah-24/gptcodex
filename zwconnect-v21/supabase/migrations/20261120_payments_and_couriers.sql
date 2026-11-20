-- Customer payment confirmation, accounting ledger and approved bicycle couriers.
-- Run after 20261120_case_and_unit_sales.sql.

alter type public.platform_role add value if not exists 'courier';

create table if not exists public.shop_payment_methods (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  method_type text not null check(method_type in ('ecocash','onemoney','bank_transfer','cash_on_delivery')),
  display_name text not null,
  account_name text not null,
  account_number text not null,
  instructions text,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.customer_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  customer_user_id uuid references auth.users(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  customer_email text,
  payment_method_id uuid not null references public.shop_payment_methods(id) on delete restrict,
  payment_reference text not null,
  amount numeric(14,2) not null check(amount>=0),
  status text not null default 'payment_submitted' check(status in ('payment_submitted','payment_confirmed','payment_rejected','delivery_requested','dispatched','completed','cancelled')),
  delivery_requested boolean not null default false,
  delivery_address text,
  delivery_city text,
  delivery_latitude double precision,
  delivery_longitude double precision,
  submitted_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id) on delete restrict,
  confirmed_at timestamptz,
  rejection_reason text
);

create table if not exists public.customer_order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.customer_orders(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  sku text not null,
  sale_unit text not null check(sale_unit in ('unit','case')),
  package_quantity numeric(14,3) not null check(package_quantity>0),
  units_per_case integer not null check(units_per_case>0),
  base_quantity numeric(14,3) not null check(base_quantity>0),
  unit_price numeric(14,2) not null check(unit_price>=0),
  line_total numeric(14,2) not null check(line_total>=0)
);

create table if not exists public.ledger_entries (
  id bigint generated always as identity primary key,
  shop_id uuid references public.shops(id) on delete set null,
  order_id uuid references public.customer_orders(id) on delete set null,
  sale_id uuid references public.sales(id) on delete set null,
  entry_type text not null check(entry_type in ('customer_payment','platform_fee','courier_fee','refund')),
  debit_account text not null,
  credit_account text not null,
  amount numeric(14,2) not null check(amount>=0),
  currency text not null default 'USD',
  memo text,
  posted_by uuid references auth.users(id) on delete restrict,
  posted_at timestamptz not null default now()
);

create table if not exists public.platform_fee_rules (
  id boolean primary key default true check(id),
  order_fee_percent numeric(6,3) not null default 2.5 check(order_fee_percent between 0 and 100),
  courier_booking_fee numeric(14,2) not null default 0.50 check(courier_booking_fee>=0),
  updated_by uuid references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);
insert into public.platform_fee_rules(id) values(true) on conflict(id) do nothing;

create table if not exists public.courier_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null,
  business_name text not null,
  email text not null,
  phone text not null,
  national_id text not null,
  bicycle_details text not null,
  operating_city text not null,
  proof_path text,
  status public.application_status not null default 'pending',
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  unique(applicant_id)
);

create table if not exists public.couriers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  application_id uuid not null unique references public.courier_applications(id) on delete restrict,
  display_name text not null,
  phone text not null,
  operating_city text not null,
  bio text,
  available boolean not null default true,
  approved_at timestamptz not null default now(),
  active boolean not null default true
);

create table if not exists public.courier_rates (
  courier_id uuid primary key references public.couriers(id) on delete cascade,
  rate_type text not null default 'distance' check(rate_type in ('distance','location','hybrid')),
  base_fee numeric(14,2) not null default 2 check(base_fee>=0),
  included_km numeric(8,2) not null default 2 check(included_km>=0),
  per_km_fee numeric(14,2) not null default 0.75 check(per_km_fee>=0),
  minimum_fee numeric(14,2) not null default 2 check(minimum_fee>=0),
  maximum_distance_km numeric(8,2) not null default 30 check(maximum_distance_km>0),
  location_rates jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

create table if not exists public.courier_subscriptions (
  courier_id uuid primary key references public.couriers(id) on delete cascade,
  amount numeric(14,2) not null default 0 check(amount>=0),
  currency text not null default 'USD',
  duration_days integer not null default 30 check(duration_days>0),
  trial_ends_at timestamptz,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  status public.subscription_status not null default 'trial',
  updated_by uuid references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);

create table if not exists public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.customer_orders(id) on delete restrict,
  courier_id uuid references public.couriers(id) on delete restrict,
  distance_km numeric(8,2),
  courier_fee numeric(14,2) not null default 0 check(courier_fee>=0),
  platform_fee numeric(14,2) not null default 0 check(platform_fee>=0),
  pickup_address text not null,
  delivery_address text not null,
  status text not null default 'open' check(status in ('open','accepted','collected','delivered','cancelled')),
  accepted_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.is_courier(target_courier uuid default null)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.couriers c where c.user_id=auth.uid() and c.active and (target_courier is null or c.id=target_courier))
$$;

create or replace function public.submit_customer_payment(client_event_uuid uuid,target_shop uuid,customer_name text,customer_phone text,customer_email text,target_payment_method uuid,payment_reference text,cart_items jsonb,wants_delivery boolean,delivery_address text default null,delivery_city text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_order uuid; item jsonb; p public.products; package_qty numeric; base_qty numeric; price numeric; total numeric:=0; selected_unit text; shop_mode text;
begin
  if exists(select 1 from public.customer_orders where id=client_event_uuid) then return client_event_uuid; end if;
  if nullif(trim(customer_name),'') is null or nullif(trim(customer_phone),'') is null or nullif(trim(payment_reference),'') is null then raise exception 'Customer and payment details are required'; end if;
  if jsonb_typeof(cart_items)<>'array' or jsonb_array_length(cart_items)=0 then raise exception 'Order requires at least one item'; end if;
  if not exists(select 1 from public.shop_payment_methods where id=target_payment_method and shop_id=target_shop and enabled) then raise exception 'Payment method is not available'; end if;
  select sales_mode into shop_mode from public.shops where id=target_shop and status='active';
  if shop_mode is null then raise exception 'Shop is unavailable'; end if;
  insert into public.customer_orders(id,shop_id,customer_user_id,customer_name,customer_phone,customer_email,payment_method_id,payment_reference,amount,delivery_requested,delivery_address,delivery_city)
  values(client_event_uuid,target_shop,auth.uid(),trim(customer_name),trim(customer_phone),nullif(lower(trim(customer_email)),''),target_payment_method,trim(payment_reference),0,wants_delivery,nullif(trim(delivery_address),''),nullif(trim(delivery_city),'')) returning id into new_order;
  for item in select * from jsonb_array_elements(cart_items) loop
    package_qty=(item->>'quantity')::numeric; selected_unit=coalesce(item->>'sale_unit','unit');
    if package_qty<=0 or selected_unit not in ('unit','case') then raise exception 'Invalid order quantity'; end if;
    if shop_mode='wholesale' and selected_unit<>'case' then raise exception 'Wholesale shops accept case orders only'; end if;
    if shop_mode='retail' and selected_unit<>'unit' then raise exception 'Retail shops accept singular-unit orders only'; end if;
    select * into p from public.products where shop_id=target_shop and sku=item->>'sku' and published;
    if not found then raise exception 'Product not found'; end if;
    base_qty=package_qty*(case when selected_unit='case' then p.case_size else 1 end);
    if p.quantity<base_qty then raise exception 'Insufficient stock for %',p.sku; end if;
    price=case when selected_unit='case' then coalesce(p.case_price,p.price*p.case_size) else p.price end;
    insert into public.customer_order_items(order_id,product_id,sku,sale_unit,package_quantity,units_per_case,base_quantity,unit_price,line_total)
    values(new_order,p.id,p.sku,selected_unit,package_qty,case when selected_unit='case' then p.case_size else 1 end,base_qty,price,round(package_qty*price,2));
    total=total+round(package_qty*price,2);
  end loop;
  update public.customer_orders set amount=total where id=new_order;
  return new_order;
end $$;

create or replace function public.save_shop_payment_method(target_shop uuid,method_details jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare method_id uuid;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner may manage payment details'; end if;
  if method_details->>'type' not in ('ecocash','onemoney','bank_transfer','cash_on_delivery') then raise exception 'Unsupported payment method'; end if;
  insert into public.shop_payment_methods(shop_id,method_type,display_name,account_name,account_number,instructions)
  values(target_shop,method_details->>'type',method_details->>'display_name',method_details->>'account_name',method_details->>'account_number',method_details->>'instructions') returning id into method_id;
  return method_id;
end $$;

create or replace function public.confirm_customer_payment(order_uuid uuid,approve boolean,rejection_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.customer_orders; oi public.customer_order_items; new_sale uuid; fee_percent numeric; fee numeric; device text:='customer-order';
begin
  select * into o from public.customer_orders where id=order_uuid for update;
  if not found or not public.owns_shop(o.shop_id) then raise exception 'Order not found or access denied'; end if;
  if o.status<>'payment_submitted' then raise exception 'Payment has already been reviewed'; end if;
  if not approve then update public.customer_orders set status='payment_rejected',rejection_reason=rejection_note,confirmed_by=auth.uid(),confirmed_at=now() where id=o.id; return null; end if;
  insert into public.sales(client_event_id,shop_id,sold_by,total,payment_method,source_device,sold_at)
  select o.id,o.shop_id,auth.uid(),o.amount,case pm.method_type when 'bank_transfer' then 'bank_transfer' when 'cash_on_delivery' then 'cash' else 'ecocash' end,device,now() from public.shop_payment_methods pm where pm.id=o.payment_method_id returning id into new_sale;
  for oi in select * from public.customer_order_items where order_id=o.id loop
    perform 1 from public.products where id=oi.product_id and quantity>=oi.base_quantity for update;
    if not found then raise exception 'Insufficient stock for %',oi.sku; end if;
    insert into public.sale_items(sale_id,product_id,sku,quantity,unit_price,sale_unit,package_quantity,base_quantity) values(new_sale,oi.product_id,oi.sku,oi.package_quantity,oi.unit_price,oi.sale_unit,oi.package_quantity,oi.base_quantity);
    update public.products set quantity=quantity-oi.base_quantity,updated_at=now() where id=oi.product_id;
    insert into public.product_movements(client_event_id,shop_id,product_id,quantity_delta,reason,device_id,created_by,occurred_at) values(gen_random_uuid(),o.shop_id,oi.product_id,-oi.base_quantity,'sale',device,auth.uid(),now());
  end loop;
  select order_fee_percent into fee_percent from public.platform_fee_rules where id=true; fee=round(o.amount*coalesce(fee_percent,0)/100,2);
  insert into public.ledger_entries(shop_id,order_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(o.shop_id,o.id,new_sale,'customer_payment','payment_clearing','sales_revenue',o.amount,'Customer payment confirmed',auth.uid());
  if fee>0 then insert into public.ledger_entries(shop_id,order_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(o.shop_id,o.id,new_sale,'platform_fee','platform_fees','payment_clearing',fee,'ZWConnect transaction fee',auth.uid()); end if;
  update public.customer_orders set status=case when delivery_requested then 'delivery_requested' else 'payment_confirmed' end,confirmed_by=auth.uid(),confirmed_at=now() where id=o.id;
  if o.delivery_requested then insert into public.deliveries(order_id,pickup_address,delivery_address) select o.id,s.address,coalesce(o.delivery_address,'Customer address required') from public.shops s where s.id=o.shop_id; end if;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'customer_payment.confirmed','customer_order',o.id::text,o.shop_id,jsonb_build_object('sale_id',new_sale,'amount',o.amount,'platform_fee',fee));
  return new_sale;
end $$;

create or replace function public.submit_courier_application(full_name text,business_name text,applicant_email text,applicant_phone text,applicant_national_id text,bicycle_details text,operating_city text,uploaded_proof_path text)
returns uuid language plpgsql security definer set search_path=public as $$
declare application_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in before submitting a courier application'; end if;
  if exists(select 1 from public.account_roles where user_id=auth.uid()) then raise exception 'This account already has a platform role'; end if;
  insert into public.courier_applications(applicant_id,full_name,business_name,email,phone,national_id,bicycle_details,operating_city,proof_path)
  values(auth.uid(),trim(full_name),trim(business_name),lower(trim(applicant_email)),trim(applicant_phone),trim(applicant_national_id),trim(bicycle_details),trim(operating_city),uploaded_proof_path)
  on conflict(applicant_id) do update set full_name=excluded.full_name,business_name=excluded.business_name,email=excluded.email,phone=excluded.phone,national_id=excluded.national_id,bicycle_details=excluded.bicycle_details,operating_city=excluded.operating_city,proof_path=excluded.proof_path,status='pending',reviewed_by=null,reviewed_at=null,rejection_reason=null
  returning id into application_id;
  return application_id;
end $$;

create or replace function public.approve_courier_application(application_uuid uuid,approve boolean,rejection_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare a public.courier_applications; new_courier uuid;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may review couriers'; end if;
  select * into a from public.courier_applications where id=application_uuid and status='pending' for update;
  if not found then raise exception 'Pending courier application not found'; end if;
  if not approve then update public.courier_applications set status='rejected',rejection_reason=rejection_note,reviewed_by=auth.uid(),reviewed_at=now() where id=a.id; return null; end if;
  insert into public.account_roles(user_id,role) values(a.applicant_id,'courier') on conflict(user_id) do update set role='courier' where public.account_roles.role='courier';
  if not found then raise exception 'Applicant already has a different platform role'; end if;
  insert into public.couriers(user_id,application_id,display_name,phone,operating_city) values(a.applicant_id,a.id,a.business_name,a.phone,a.operating_city) returning id into new_courier;
  insert into public.courier_rates(courier_id) values(new_courier);
  insert into public.courier_subscriptions(courier_id,trial_ends_at,status) values(new_courier,now()+interval '14 days','trial');
  update public.courier_applications set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=a.id;
  return new_courier;
end $$;

create or replace function public.save_courier_rate(rate_details jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare target_courier uuid; requested_type text;
begin
  select id into target_courier from public.couriers where user_id=auth.uid() and active;
  if target_courier is null then raise exception 'Approved courier account required'; end if;
  requested_type=rate_details->>'rate_type';
  if requested_type not in ('distance','location','hybrid') then raise exception 'Invalid rate type'; end if;
  insert into public.courier_rates(courier_id,rate_type,base_fee,included_km,per_km_fee,minimum_fee,maximum_distance_km,location_rates,updated_at)
  values(target_courier,requested_type,(rate_details->>'base_fee')::numeric,(rate_details->>'included_km')::numeric,(rate_details->>'per_km_fee')::numeric,(rate_details->>'minimum_fee')::numeric,(rate_details->>'maximum_distance_km')::numeric,coalesce(rate_details->'location_rates','{}'::jsonb),now())
  on conflict(courier_id) do update set rate_type=excluded.rate_type,base_fee=excluded.base_fee,included_km=excluded.included_km,per_km_fee=excluded.per_km_fee,minimum_fee=excluded.minimum_fee,maximum_distance_km=excluded.maximum_distance_km,location_rates=excluded.location_rates,updated_at=now();
  return target_courier;
end $$;

create or replace function public.set_courier_subscription(target_courier uuid,subscription_amount numeric,subscription_duration_days integer,trial_days integer,new_status public.subscription_status)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may manage courier subscriptions'; end if;
  if subscription_amount<0 or subscription_duration_days<1 or trial_days<0 then raise exception 'Invalid subscription settings'; end if;
  insert into public.courier_subscriptions(courier_id,amount,duration_days,trial_ends_at,starts_at,ends_at,status,updated_by,updated_at)
  values(target_courier,subscription_amount,subscription_duration_days,case when trial_days>0 then now()+make_interval(days=>trial_days) end,now(),now()+make_interval(days=>subscription_duration_days),new_status,auth.uid(),now())
  on conflict(courier_id) do update set amount=excluded.amount,duration_days=excluded.duration_days,trial_ends_at=excluded.trial_ends_at,starts_at=excluded.starts_at,ends_at=excluded.ends_at,status=excluded.status,updated_by=auth.uid(),updated_at=now();
  return target_courier;
end $$;

create or replace function public.assign_courier_to_delivery(delivery_uuid uuid,target_courier uuid,travel_distance_km numeric)
returns numeric language plpgsql security definer set search_path=public as $$
declare d public.deliveries; order_shop uuid; quoted numeric; booking_fee numeric;
begin
  select * into d from public.deliveries where id=delivery_uuid and status='open' for update;
  if not found then raise exception 'Open delivery not found'; end if;
  select shop_id into order_shop from public.customer_orders where id=d.order_id;
  if not public.owns_shop(order_shop) then raise exception 'Only the shop owner may assign this delivery'; end if;
  if not exists(select 1 from public.couriers c join public.courier_subscriptions s on s.courier_id=c.id where c.id=target_courier and c.active and c.available and s.status in ('trial','active') and (s.ends_at is null or s.ends_at>now())) then raise exception 'Courier is unavailable or subscription access has expired'; end if;
  quoted=public.quote_courier_fee(target_courier,travel_distance_km,(select delivery_city from public.customer_orders where id=d.order_id));
  if quoted is null then raise exception 'Delivery is outside the courier service area'; end if;
  select courier_booking_fee into booking_fee from public.platform_fee_rules where id=true;
  update public.deliveries set courier_id=target_courier,distance_km=travel_distance_km,courier_fee=quoted,platform_fee=coalesce(booking_fee,0),status='accepted',accepted_at=now() where id=d.id;
  insert into public.ledger_entries(shop_id,order_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(order_shop,d.order_id,'courier_fee','delivery_receivable','courier_payable',quoted,'Courier delivery fee',auth.uid());
  if coalesce(booking_fee,0)>0 then insert into public.ledger_entries(shop_id,order_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(order_shop,d.order_id,'platform_fee','delivery_receivable','platform_fees',booking_fee,'ZWConnect courier booking fee',auth.uid()); end if;
  return quoted+coalesce(booking_fee,0);
end $$;

create or replace function public.quote_courier_fee(target_courier uuid,distance_km numeric,destination_city text)
returns numeric language plpgsql stable security definer set search_path=public as $$
declare r public.courier_rates; location_fee numeric; quoted numeric;
begin
  select * into r from public.courier_rates where courier_id=target_courier;
  if not found or distance_km<0 or distance_km>r.maximum_distance_km then return null; end if;
  location_fee=coalesce((r.location_rates->>lower(destination_city))::numeric,0);
  quoted=case when r.rate_type='location' then location_fee else r.base_fee+greatest(0,distance_km-r.included_km)*r.per_km_fee+case when r.rate_type='hybrid' then location_fee else 0 end end;
  return greatest(r.minimum_fee,round(quoted,2));
end $$;

alter table public.shop_payment_methods enable row level security;
alter table public.customer_orders enable row level security;
alter table public.customer_order_items enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.platform_fee_rules enable row level security;
alter table public.courier_applications enable row level security;
alter table public.couriers enable row level security;
alter table public.courier_rates enable row level security;
alter table public.courier_subscriptions enable row level security;
alter table public.deliveries enable row level security;

create policy "payment methods public read" on public.shop_payment_methods for select using(enabled or public.owns_shop(shop_id) or public.is_site_admin());
create policy "owners manage payment methods" on public.shop_payment_methods for all using(public.owns_shop(shop_id)) with check(public.owns_shop(shop_id));
create policy "owners read customer orders" on public.customer_orders for select using(public.owns_shop(shop_id) or customer_user_id=auth.uid() or public.is_site_admin());
create policy "order parties read items" on public.customer_order_items for select using(exists(select 1 from public.customer_orders o where o.id=order_id and (public.owns_shop(o.shop_id) or o.customer_user_id=auth.uid() or public.is_site_admin())));
create policy "owners read ledger" on public.ledger_entries for select using((shop_id is not null and public.owns_shop(shop_id)) or public.is_site_admin());
create policy "fee rules public read" on public.platform_fee_rules for select using(true);
create policy "courier applicants read own" on public.courier_applications for select using(applicant_id=auth.uid() or public.is_site_admin());
create policy "courier applicants submit" on public.courier_applications for insert with check(applicant_id=auth.uid());
create policy "approved couriers public read" on public.couriers for select using(active or public.is_site_admin());
create policy "couriers update own profile" on public.couriers for update using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy "courier rates public read" on public.courier_rates for select using(true);
create policy "couriers manage own rates" on public.courier_rates for all using(public.is_courier(courier_id)) with check(public.is_courier(courier_id));
create policy "courier subscriptions restricted" on public.courier_subscriptions for select using(public.is_courier(courier_id) or public.is_site_admin());
create policy "delivery parties read" on public.deliveries for select using(public.is_courier(courier_id) or public.is_site_admin() or exists(select 1 from public.customer_orders o where o.id=order_id and (public.owns_shop(o.shop_id) or o.customer_user_id=auth.uid())));
create policy "couriers update deliveries" on public.deliveries for update using(public.is_courier(courier_id)) with check(public.is_courier(courier_id));

revoke execute on function public.submit_customer_payment(uuid,uuid,text,text,text,uuid,text,jsonb,boolean,text,text) from public;
grant execute on function public.submit_customer_payment(uuid,uuid,text,text,text,uuid,text,jsonb,boolean,text,text) to anon,authenticated;
grant execute on function public.save_shop_payment_method(uuid,jsonb) to authenticated;
grant execute on function public.confirm_customer_payment(uuid,boolean,text) to authenticated;
grant execute on function public.submit_courier_application(text,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.approve_courier_application(uuid,boolean,text) to authenticated;
grant execute on function public.save_courier_rate(jsonb) to authenticated;
grant execute on function public.set_courier_subscription(uuid,numeric,integer,integer,public.subscription_status) to authenticated;
grant execute on function public.quote_courier_fee(uuid,numeric,text) to anon,authenticated;
grant execute on function public.assign_courier_to_delivery(uuid,uuid,numeric) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('courier-proofs','courier-proofs',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "courier applicants upload proof" on storage.objects for insert to authenticated with check(bucket_id='courier-proofs' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "courier applicants read proof" on storage.objects for select to authenticated using(bucket_id='courier-proofs' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_site_admin()));

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='customer_orders') then alter publication supabase_realtime add table public.customer_orders; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='deliveries') then alter publication supabase_realtime add table public.deliveries; end if;
end $$;
