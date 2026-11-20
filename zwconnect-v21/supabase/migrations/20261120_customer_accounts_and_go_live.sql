-- Customer accounts and launch hardening.
-- Public catalogue reads remain anonymous; every order action is owned by one authenticated customer.

create table if not exists public.customer_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check(length(trim(display_name)) between 2 and 100),
  phone text not null check(length(trim(phone)) between 7 and 30),
  status text not null default 'active' check(status in ('active','suspended','closed')),
  terms_accepted_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.customer_profiles enable row level security;
create policy "customers read own profile" on public.customer_profiles for select to authenticated using(user_id=auth.uid());
create policy "admins read customer profiles" on public.customer_profiles for select to authenticated using(public.is_site_admin());

create or replace function public.register_customer_profile(full_name text,phone_number text,accepted_terms boolean)
returns uuid language plpgsql security definer set search_path=public,auth as $$
begin
  if auth.uid() is null then raise exception 'Sign in before creating a customer profile'; end if;
  if not accepted_terms then raise exception 'Terms and privacy consent are required'; end if;
  if nullif(trim(full_name),'') is null or length(trim(full_name))>100 then raise exception 'Enter a valid full name'; end if;
  if length(trim(coalesce(phone_number,''))) not between 7 and 30 then raise exception 'Enter a valid phone number'; end if;
  if exists(select 1 from public.account_roles where user_id=auth.uid())
    or exists(select 1 from public.owner_applications where applicant_id=auth.uid() and status='pending')
    or exists(select 1 from public.courier_applications where applicant_id=auth.uid() and status='pending') then
    raise exception 'Business and customer roles require separate accounts';
  end if;
  insert into public.customer_profiles(user_id,display_name,phone,terms_accepted_at)
  values(auth.uid(),trim(full_name),trim(phone_number),now())
  on conflict(user_id) do update set display_name=excluded.display_name,phone=excluded.phone,updated_at=now()
  where public.customer_profiles.status='active';
  return auth.uid();
end $$;

create or replace function public.prevent_overlapping_account_roles()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.customer_profiles where user_id=new.user_id) then
    raise exception 'Customer and business roles require separate accounts';
  end if;
  return new;
end $$;
drop trigger if exists prevent_overlapping_account_roles on public.account_roles;
create trigger prevent_overlapping_account_roles before insert or update on public.account_roles for each row execute function public.prevent_overlapping_account_roles();

create or replace function public.prevent_customer_business_application()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.customer_profiles where user_id=new.applicant_id) then
    raise exception 'Use a separate business account for owner or courier applications';
  end if;
  return new;
end $$;
drop trigger if exists prevent_customer_owner_application on public.owner_applications;
create trigger prevent_customer_owner_application before insert or update on public.owner_applications for each row execute function public.prevent_customer_business_application();
drop trigger if exists prevent_customer_courier_application on public.courier_applications;
create trigger prevent_customer_courier_application before insert or update on public.courier_applications for each row execute function public.prevent_customer_business_application();

create or replace function public.enforce_customer_order_owner()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Customer sign-in is required to place an order'; end if;
  if not exists(select 1 from public.customer_profiles c where c.user_id=auth.uid() and c.status='active') then
    raise exception 'An active customer account is required';
  end if;
  new.customer_user_id=auth.uid();
  new.customer_email=(select lower(email) from auth.users where id=auth.uid());
  return new;
end $$;
drop trigger if exists enforce_customer_order_owner on public.customer_orders;
create trigger enforce_customer_order_owner before insert on public.customer_orders for each row execute function public.enforce_customer_order_owner();

create or replace function public.get_customer_order(order_uuid uuid,tracking_uuid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('id',o.id,'tracking_token',o.tracking_token,'status',o.status,'amount',o.amount,'shop',s.name,'confirmation_note',o.confirmation_note,'rejection_reason',o.rejection_reason,'submitted_at',o.submitted_at,'confirmed_at',o.confirmed_at,'delivery',case when d.id is null then null else jsonb_build_object('id',d.id,'status',d.status,'pickup_address',d.pickup_address,'delivery_address',d.delivery_address,'parcel_details',d.parcel_details,'bids',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'courier',c.display_name,'phone',c.phone,'minimum_fee',b.minimum_fee,'offered_fee',b.offered_fee,'note',b.courier_note,'courier_to_pickup_km',b.courier_to_pickup_km,'pickup_to_dropoff_km',b.pickup_to_dropoff_km,'pickup_eta_minutes',b.pickup_eta_minutes,'status',b.status) order by b.offered_fee) from public.delivery_bids b join public.couriers c on c.id=b.courier_id where b.delivery_id=d.id and b.status in ('pending','accepted')),'[]'::jsonb)) end)
  from public.customer_orders o join public.shops s on s.id=o.shop_id left join public.deliveries d on d.order_id=o.id
  where auth.uid() is not null and o.customer_user_id=auth.uid() and o.id=order_uuid and o.tracking_token=tracking_uuid
$$;

create or replace function public.get_my_customer_orders()
returns table(id uuid,tracking_token uuid,status text,amount numeric,shop text,confirmation_note text,rejection_reason text,submitted_at timestamptz)
language sql stable security definer set search_path=public as $$
  select o.id,o.tracking_token,o.status,o.amount,s.name,o.confirmation_note,o.rejection_reason,o.submitted_at
  from public.customer_orders o join public.shops s on s.id=o.shop_id
  where o.customer_user_id=auth.uid()
  order by o.submitted_at desc limit 50
$$;

create or replace function public.request_order_delivery(order_uuid uuid,tracking_uuid uuid,dropoff_address text,dropoff_lat double precision,dropoff_lng double precision,parcel_description text)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.customer_orders; s public.shops; delivery_id uuid; route_km numeric;
begin
  select * into o from public.customer_orders where id=order_uuid and tracking_token=tracking_uuid and customer_user_id=auth.uid() for update;
  if not found or o.status<>'payment_confirmed' then raise exception 'Delivery can be requested only by the signed-in customer after payment confirmation'; end if;
  if nullif(trim(dropoff_address),'') is null or dropoff_lat is null or dropoff_lng is null then raise exception 'Delivery address and map location are required'; end if;
  select * into s from public.shops where id=o.shop_id; route_km=public.geo_distance_km(s.latitude,s.longitude,dropoff_lat,dropoff_lng);
  insert into public.deliveries(order_id,pickup_address,delivery_address,pickup_latitude,pickup_longitude,delivery_latitude,delivery_longitude,parcel_details,route_distance_km,status)
  values(o.id,s.address,trim(dropoff_address),s.latitude,s.longitude,dropoff_lat,dropoff_lng,coalesce(nullif(trim(parcel_description),''),'Customer order'),route_km,'open') returning id into delivery_id;
  update public.customer_orders set status='delivery_requested',delivery_requested=true,delivery_address=trim(dropoff_address),delivery_latitude=dropoff_lat,delivery_longitude=dropoff_lng where id=o.id;
  return delivery_id;
end $$;

create or replace function public.decide_delivery_bid(order_uuid uuid,tracking_uuid uuid,target_bid uuid,accept_bid boolean)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries; b public.delivery_bids; booking_fee numeric;
begin
  select dlv.* into d from public.deliveries dlv join public.customer_orders o on o.id=dlv.order_id where o.id=order_uuid and o.tracking_token=tracking_uuid and o.customer_user_id=auth.uid() and dlv.status='open' for update of dlv;
  if not found then raise exception 'Open delivery not found for this customer'; end if;
  select * into b from public.delivery_bids where id=target_bid and delivery_id=d.id and status='pending' for update;
  if not found then raise exception 'Courier offer is unavailable'; end if;
  if not accept_bid then update public.delivery_bids set status='declined',decided_at=now() where id=b.id; return b.id; end if;
  if exists(select 1 from public.deliveries where courier_id=b.courier_id and status in ('accepted','collected','courier_completed')) then raise exception 'This courier already has an active delivery'; end if;
  select courier_booking_fee into booking_fee from public.platform_fee_rules where id=true;
  update public.delivery_bids set status=case when id=b.id then 'accepted' else 'declined' end,decided_at=now() where delivery_id=d.id and status='pending';
  update public.deliveries set courier_id=b.courier_id,courier_fee=b.offered_fee,platform_fee=coalesce(booking_fee,0),status='accepted',accepted_at=now() where id=d.id;
  update public.customer_orders set status='courier_selected' where id=order_uuid;
  return b.id;
end $$;

create or replace function public.customer_confirm_delivery(order_uuid uuid,tracking_uuid uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries;
begin
  select dlv.* into d from public.deliveries dlv join public.customer_orders o on o.id=dlv.order_id where o.id=order_uuid and o.tracking_token=tracking_uuid and o.customer_user_id=auth.uid() and dlv.status in ('courier_completed','delivered') for update of dlv;
  if not found then raise exception 'Delivery is not awaiting receipt for this customer'; end if;
  if d.status='delivered' then return d.id; end if;
  update public.deliveries set status='delivered',customer_received_at=now(),delivered_at=now() where id=d.id;
  update public.customer_orders set status='completed' where id=order_uuid;
  return d.id;
end $$;

create or replace function public.get_customer_delivery_tracking(order_uuid uuid,tracking_uuid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('delivery_id',d.id,'status',d.status,'courier',c.display_name,'phone',c.phone,'latitude',t.latitude,'longitude',t.longitude,'recorded_at',t.recorded_at,'courier_to_pickup_km',case when t.latitude is null then b.courier_to_pickup_km else public.geo_distance_km(t.latitude,t.longitude,d.pickup_latitude,d.pickup_longitude) end,'pickup_to_dropoff_km',d.route_distance_km,'pickup_eta_minutes',case when d.status='accepted' then greatest(1,ceil((case when t.latitude is null then b.courier_to_pickup_km else public.geo_distance_km(t.latitude,t.longitude,d.pickup_latitude,d.pickup_longitude) end)/(case when coalesce(t.speed_kph,0) between 5 and 80 then t.speed_kph else 15 end)*60)::integer) else 0 end,'delivery_eta_minutes',case when d.status in ('collected','courier_completed') and t.latitude is not null then greatest(1,ceil(public.geo_distance_km(t.latitude,t.longitude,d.delivery_latitude,d.delivery_longitude)/(case when coalesce(t.speed_kph,0) between 5 and 80 then t.speed_kph else 15 end)*60)::integer) else null end)
  from public.customer_orders o join public.deliveries d on d.order_id=o.id join public.couriers c on c.id=d.courier_id left join public.delivery_tracking t on t.delivery_id=d.id left join public.delivery_bids b on b.delivery_id=d.id and b.courier_id=d.courier_id and b.status='accepted'
  where o.customer_user_id=auth.uid() and o.id=order_uuid and o.tracking_token=tracking_uuid and d.status in ('accepted','collected','courier_completed','delivered')
$$;

drop policy if exists "customers upload random payment proof" on storage.objects;
drop policy if exists "customers upload own payment proof" on storage.objects;
drop policy if exists "customers read own payment proof" on storage.objects;
create policy "customers upload own payment proof" on storage.objects for insert to authenticated
with check(bucket_id='payment-proofs' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.customer_profiles c where c.user_id=auth.uid() and c.status='active'));
create policy "customers read own payment proof" on storage.objects for select to authenticated
using(bucket_id='payment-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

revoke execute on function public.register_customer_profile(text,text,boolean) from public,anon;
revoke execute on function public.get_my_customer_orders() from public,anon;
revoke execute on function public.submit_customer_payment(uuid,uuid,text,text,text,uuid,text,jsonb,boolean,text,text) from anon;
revoke execute on function public.submit_cart_payment(uuid,uuid,uuid,text,text,text,uuid,text,text,text,jsonb) from anon;
revoke execute on function public.get_customer_order(uuid,uuid) from anon;
revoke execute on function public.request_order_delivery(uuid,uuid,text,double precision,double precision,text) from anon;
revoke execute on function public.decide_delivery_bid(uuid,uuid,uuid,boolean) from anon;
revoke execute on function public.customer_confirm_delivery(uuid,uuid) from anon;
revoke execute on function public.get_customer_delivery_tracking(uuid,uuid) from anon;
grant execute on function public.register_customer_profile(text,text,boolean) to authenticated;
grant execute on function public.get_my_customer_orders() to authenticated;
grant execute on function public.submit_customer_payment(uuid,uuid,text,text,text,uuid,text,jsonb,boolean,text,text) to authenticated;
grant execute on function public.submit_cart_payment(uuid,uuid,uuid,text,text,text,uuid,text,text,text,jsonb) to authenticated;
grant execute on function public.get_customer_order(uuid,uuid) to authenticated;
grant execute on function public.request_order_delivery(uuid,uuid,text,double precision,double precision,text) to authenticated;
grant execute on function public.decide_delivery_bid(uuid,uuid,uuid,boolean) to authenticated;
grant execute on function public.customer_confirm_delivery(uuid,uuid) to authenticated;
grant execute on function public.get_customer_delivery_tracking(uuid,uuid) to authenticated;
