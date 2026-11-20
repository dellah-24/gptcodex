-- Multi-item checkout, payment proof review and customer-selected courier bids.
-- Run after 20261120_payments_and_couriers.sql.

alter table public.customer_orders add column if not exists tracking_token uuid not null default gen_random_uuid();
alter table public.customer_orders add column if not exists payment_proof_path text;
alter table public.customer_orders add column if not exists payment_proof_text text;
alter table public.customer_orders drop constraint if exists customer_orders_status_check;
alter table public.customer_orders add constraint customer_orders_status_check check(status in ('payment_submitted','payment_confirmed','payment_rejected','delivery_requested','courier_selected','dispatched','completed','cancelled'));
alter table public.customer_orders add column if not exists confirmation_note text;
alter table public.customer_orders add column if not exists customer_status_seen_at timestamptz;
create unique index if not exists customer_orders_tracking_token_key on public.customer_orders(tracking_token);

alter table public.couriers add column if not exists current_latitude double precision check(current_latitude between -90 and 90);
alter table public.couriers add column if not exists current_longitude double precision check(current_longitude between -180 and 180);
alter table public.couriers add column if not exists location_updated_at timestamptz;

alter table public.deliveries add column if not exists pickup_latitude double precision check(pickup_latitude between -90 and 90);
alter table public.deliveries add column if not exists pickup_longitude double precision check(pickup_longitude between -180 and 180);
alter table public.deliveries add column if not exists delivery_latitude double precision check(delivery_latitude between -90 and 90);
alter table public.deliveries add column if not exists delivery_longitude double precision check(delivery_longitude between -180 and 180);
alter table public.deliveries add column if not exists parcel_details text;
alter table public.deliveries add column if not exists route_distance_km numeric(8,2);

create table if not exists public.delivery_bids (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  courier_id uuid not null references public.couriers(id) on delete cascade,
  minimum_fee numeric(14,2) not null check(minimum_fee>=0),
  offered_fee numeric(14,2) not null check(offered_fee>=minimum_fee),
  courier_note text,
  courier_to_pickup_km numeric(8,2) not null check(courier_to_pickup_km>=0),
  pickup_to_dropoff_km numeric(8,2) not null check(pickup_to_dropoff_km>=0),
  status text not null default 'pending' check(status in ('pending','accepted','declined','withdrawn')),
  submitted_at timestamptz not null default now(),
  decided_at timestamptz,
  unique(delivery_id,courier_id)
);

create or replace function public.geo_distance_km(lat1 double precision,lng1 double precision,lat2 double precision,lng2 double precision)
returns numeric language sql immutable as $$
  select round((6371*2*asin(sqrt(power(sin(radians(lat2-lat1)/2),2)+cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2))))::numeric,2)
$$;

create or replace function public.submit_cart_payment(client_event_uuid uuid,tracking_uuid uuid,target_shop uuid,customer_name text,customer_phone text,customer_email text,target_payment_method uuid,payment_reference text,payment_proof_path text,payment_proof_text text,cart_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare new_order uuid; item jsonb; p public.products; package_qty numeric; base_qty numeric; price numeric; total numeric:=0; selected_unit text; shop_mode text;
begin
  if exists(select 1 from public.customer_orders where id=client_event_uuid) then return jsonb_build_object('order_id',client_event_uuid,'tracking_token',(select tracking_token from public.customer_orders where id=client_event_uuid)); end if;
  if nullif(trim(customer_name),'') is null or nullif(trim(customer_phone),'') is null or nullif(trim(payment_reference),'') is null then raise exception 'Customer and payment details are required'; end if;
  if nullif(trim(payment_proof_text),'') is null and nullif(trim(payment_proof_path),'') is null then raise exception 'Upload an image or enter payment proof text'; end if;
  if jsonb_typeof(cart_items)<>'array' or jsonb_array_length(cart_items)=0 then raise exception 'Cart is empty'; end if;
  if not exists(select 1 from public.shop_payment_methods where id=target_payment_method and shop_id=target_shop and enabled) then raise exception 'Payment method is not available'; end if;
  select sales_mode into shop_mode from public.shops where id=target_shop and status='active'; if shop_mode is null then raise exception 'Shop is unavailable'; end if;
  insert into public.customer_orders(id,tracking_token,shop_id,customer_user_id,customer_name,customer_phone,customer_email,payment_method_id,payment_reference,payment_proof_path,payment_proof_text,amount,delivery_requested)
  values(client_event_uuid,tracking_uuid,target_shop,auth.uid(),trim(customer_name),trim(customer_phone),nullif(lower(trim(customer_email)),''),target_payment_method,trim(payment_reference),nullif(payment_proof_path,''),nullif(payment_proof_text,''),0,false) returning id into new_order;
  for item in select * from jsonb_array_elements(cart_items) loop
    package_qty=(item->>'quantity')::numeric; selected_unit=coalesce(item->>'sale_unit','unit');
    if package_qty<=0 or selected_unit not in ('unit','case') then raise exception 'Invalid cart quantity'; end if;
    if shop_mode='wholesale' and selected_unit<>'case' then raise exception 'Wholesale shops accept cases only'; end if;
    if shop_mode='retail' and selected_unit<>'unit' then raise exception 'Retail shops accept singular units only'; end if;
    select * into p from public.products where shop_id=target_shop and sku=item->>'sku' and published and quantity>0 for share;
    if not found then raise exception 'Product % is unavailable',item->>'sku'; end if;
    if selected_unit='case' and (not p.allow_case_sales or p.case_size<=1) then raise exception 'Case sales are unavailable for %',p.sku; end if;
    base_qty=package_qty*(case when selected_unit='case' then p.case_size else 1 end);
    if p.quantity<base_qty then raise exception 'Insufficient stock for %',p.sku; end if;
    price=case when selected_unit='case' then coalesce(p.case_price,p.price*p.case_size) else p.price end;
    insert into public.customer_order_items(order_id,product_id,sku,sale_unit,package_quantity,units_per_case,base_quantity,unit_price,line_total)
    values(new_order,p.id,p.sku,selected_unit,package_qty,case when selected_unit='case' then p.case_size else 1 end,base_qty,price,round(package_qty*price,2));
    total=total+round(package_qty*price,2);
  end loop;
  update public.customer_orders set amount=total where id=new_order;
  return jsonb_build_object('order_id',new_order,'tracking_token',tracking_uuid,'amount',total);
end $$;

create or replace function public.review_customer_payment(order_uuid uuid,approve boolean,decision_note text)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.customer_orders; oi public.customer_order_items; new_sale uuid; fee_percent numeric; fee numeric; device text:='customer-cart';
begin
  select * into o from public.customer_orders where id=order_uuid for update;
  if not found or not (public.owns_shop(o.shop_id) or public.works_at_shop(o.shop_id)) then raise exception 'Order not found or access denied'; end if;
  if o.status<>'payment_submitted' then raise exception 'Payment has already been reviewed'; end if;
  if nullif(trim(decision_note),'') is null then raise exception 'Add a customer-visible confirmation note'; end if;
  if not approve then update public.customer_orders set status='payment_rejected',rejection_reason=decision_note,confirmation_note=decision_note,confirmed_by=auth.uid(),confirmed_at=now() where id=o.id; return null; end if;
  insert into public.sales(client_event_id,shop_id,sold_by,total,payment_method,source_device,sold_at)
  select o.id,o.shop_id,auth.uid(),o.amount,case pm.method_type when 'bank_transfer' then 'bank_transfer' when 'cash_on_delivery' then 'cash' else 'ecocash' end,device,now() from public.shop_payment_methods pm where pm.id=o.payment_method_id returning id into new_sale;
  for oi in select * from public.customer_order_items where order_id=o.id loop
    perform 1 from public.products where id=oi.product_id and quantity>=oi.base_quantity for update; if not found then raise exception 'Insufficient stock for %',oi.sku; end if;
    insert into public.sale_items(sale_id,product_id,sku,quantity,unit_price,sale_unit,package_quantity,base_quantity) values(new_sale,oi.product_id,oi.sku,oi.package_quantity,oi.unit_price,oi.sale_unit,oi.package_quantity,oi.base_quantity);
    update public.products set quantity=quantity-oi.base_quantity,updated_at=now() where id=oi.product_id;
    insert into public.product_movements(client_event_id,shop_id,product_id,quantity_delta,reason,device_id,created_by,occurred_at) values(gen_random_uuid(),o.shop_id,oi.product_id,-oi.base_quantity,'sale',device,auth.uid(),now());
  end loop;
  select order_fee_percent into fee_percent from public.platform_fee_rules where id=true; fee=round(o.amount*coalesce(fee_percent,0)/100,2);
  insert into public.ledger_entries(shop_id,order_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(o.shop_id,o.id,new_sale,'customer_payment','payment_clearing','sales_revenue',o.amount,'Cart payment confirmed',auth.uid());
  if fee>0 then insert into public.ledger_entries(shop_id,order_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by) values(o.shop_id,o.id,new_sale,'platform_fee','platform_fees','payment_clearing',fee,'ZWConnect transaction fee',auth.uid()); end if;
  update public.customer_orders set status='payment_confirmed',confirmation_note=decision_note,confirmed_by=auth.uid(),confirmed_at=now() where id=o.id;
  return new_sale;
end $$;

create or replace function public.get_customer_order(order_uuid uuid,tracking_uuid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('id',o.id,'status',o.status,'amount',o.amount,'shop',s.name,'confirmation_note',o.confirmation_note,'rejection_reason',o.rejection_reason,'submitted_at',o.submitted_at,'confirmed_at',o.confirmed_at,'delivery',case when d.id is null then null else jsonb_build_object('id',d.id,'status',d.status,'pickup_address',d.pickup_address,'delivery_address',d.delivery_address,'parcel_details',d.parcel_details,'bids',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'courier',c.display_name,'phone',c.phone,'minimum_fee',b.minimum_fee,'offered_fee',b.offered_fee,'note',b.courier_note,'courier_to_pickup_km',b.courier_to_pickup_km,'pickup_to_dropoff_km',b.pickup_to_dropoff_km,'status',b.status) order by b.offered_fee) from public.delivery_bids b join public.couriers c on c.id=b.courier_id where b.delivery_id=d.id and b.status in ('pending','accepted')),'[]'::jsonb)) end) from public.customer_orders o join public.shops s on s.id=o.shop_id left join public.deliveries d on d.order_id=o.id where o.id=order_uuid and o.tracking_token=tracking_uuid
$$;

create or replace function public.request_order_delivery(order_uuid uuid,tracking_uuid uuid,dropoff_address text,dropoff_lat double precision,dropoff_lng double precision,parcel_description text)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.customer_orders; s public.shops; delivery_id uuid; route_km numeric;
begin
  select * into o from public.customer_orders where id=order_uuid and tracking_token=tracking_uuid for update;
  if not found or o.status<>'payment_confirmed' then raise exception 'Delivery can be requested only after payment confirmation'; end if;
  if nullif(trim(dropoff_address),'') is null or dropoff_lat is null or dropoff_lng is null then raise exception 'Delivery address and map location are required'; end if;
  select * into s from public.shops where id=o.shop_id; route_km=public.geo_distance_km(s.latitude,s.longitude,dropoff_lat,dropoff_lng);
  insert into public.deliveries(order_id,pickup_address,delivery_address,pickup_latitude,pickup_longitude,delivery_latitude,delivery_longitude,parcel_details,route_distance_km,status)
  values(o.id,s.address,trim(dropoff_address),s.latitude,s.longitude,dropoff_lat,dropoff_lng,coalesce(nullif(trim(parcel_description),''),'Customer order'),route_km,'open') returning id into delivery_id;
  update public.customer_orders set status='delivery_requested',delivery_requested=true,delivery_address=trim(dropoff_address),delivery_latitude=dropoff_lat,delivery_longitude=dropoff_lng where id=o.id;
  return delivery_id;
end $$;

create or replace function public.submit_delivery_bid(target_delivery uuid,offered_amount numeric,bid_note text,courier_lat double precision,courier_lng double precision)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries; courier_uuid uuid; min_fee numeric; pickup_km numeric; bid_id uuid;
begin
  select id into courier_uuid from public.couriers c where c.user_id=auth.uid() and c.active and c.available;
  if courier_uuid is null or not exists(select 1 from public.courier_subscriptions where courier_id=courier_uuid and status in ('trial','active') and (ends_at is null or ends_at>now())) then raise exception 'Active subscribed courier required'; end if;
  select * into d from public.deliveries where id=target_delivery and status='open' for update; if not found then raise exception 'Delivery is no longer open'; end if;
  pickup_km=public.geo_distance_km(courier_lat,courier_lng,d.pickup_latitude,d.pickup_longitude); min_fee=public.quote_courier_fee(courier_uuid,d.route_distance_km,(select delivery_city from public.customer_orders where id=d.order_id));
  if min_fee is null then raise exception 'Delivery is outside your configured service area'; end if;
  if offered_amount<min_fee then raise exception 'Offer cannot be below your minimum fare of %',min_fee; end if;
  update public.couriers set current_latitude=courier_lat,current_longitude=courier_lng,location_updated_at=now() where id=courier_uuid;
  insert into public.delivery_bids(delivery_id,courier_id,minimum_fee,offered_fee,courier_note,courier_to_pickup_km,pickup_to_dropoff_km)
  values(d.id,courier_uuid,min_fee,offered_amount,nullif(trim(bid_note),''),pickup_km,d.route_distance_km)
  on conflict(delivery_id,courier_id) do update set minimum_fee=excluded.minimum_fee,offered_fee=excluded.offered_fee,courier_note=excluded.courier_note,courier_to_pickup_km=excluded.courier_to_pickup_km,pickup_to_dropoff_km=excluded.pickup_to_dropoff_km,status='pending',submitted_at=now() returning id into bid_id;
  return bid_id;
end $$;

create or replace function public.decide_delivery_bid(order_uuid uuid,tracking_uuid uuid,target_bid uuid,accept_bid boolean)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries; b public.delivery_bids; booking_fee numeric;
begin
  select dlv.* into d from public.deliveries dlv join public.customer_orders o on o.id=dlv.order_id where o.id=order_uuid and o.tracking_token=tracking_uuid and dlv.status='open' for update of dlv;
  if not found then raise exception 'Open delivery not found'; end if;
  select * into b from public.delivery_bids where id=target_bid and delivery_id=d.id and status='pending' for update; if not found then raise exception 'Courier offer is unavailable'; end if;
  if not accept_bid then update public.delivery_bids set status='declined',decided_at=now() where id=b.id; return b.id; end if;
  select courier_booking_fee into booking_fee from public.platform_fee_rules where id=true;
  update public.delivery_bids set status=case when id=b.id then 'accepted' else 'declined' end,decided_at=now() where delivery_id=d.id and status='pending';
  update public.deliveries set courier_id=b.courier_id,courier_fee=b.offered_fee,platform_fee=coalesce(booking_fee,0),status='accepted',accepted_at=now() where id=d.id;
  update public.customer_orders set status='courier_selected' where id=order_uuid;
  return b.id;
end $$;

alter table public.delivery_bids enable row level security;
create policy "couriers read open deliveries" on public.deliveries for select using((status='open' and public.is_courier()) or public.is_courier(courier_id) or public.is_site_admin() or exists(select 1 from public.customer_orders o where o.id=order_id and (public.owns_shop(o.shop_id) or public.works_at_shop(o.shop_id))));
create policy "couriers read own and open bids" on public.delivery_bids for select using(public.is_courier(courier_id) or exists(select 1 from public.deliveries d join public.customer_orders o on o.id=d.order_id where d.id=delivery_id and public.owns_shop(o.shop_id)) or public.is_site_admin());
create policy "workers read assigned shop orders" on public.customer_orders for select using(public.works_at_shop(shop_id));
create policy "workers read assigned order items" on public.customer_order_items for select using(exists(select 1 from public.customer_orders o where o.id=order_id and public.works_at_shop(o.shop_id)));

revoke execute on function public.submit_cart_payment(uuid,uuid,uuid,text,text,text,uuid,text,text,text,jsonb) from public;
grant execute on function public.submit_cart_payment(uuid,uuid,uuid,text,text,text,uuid,text,text,text,jsonb) to anon,authenticated;
grant execute on function public.review_customer_payment(uuid,boolean,text) to authenticated;
grant execute on function public.get_customer_order(uuid,uuid) to anon,authenticated;
grant execute on function public.request_order_delivery(uuid,uuid,text,double precision,double precision,text) to anon,authenticated;
grant execute on function public.submit_delivery_bid(uuid,numeric,text,double precision,double precision) to authenticated;
grant execute on function public.decide_delivery_bid(uuid,uuid,uuid,boolean) to anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('payment-proofs','payment-proofs',false,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "customers upload random payment proof" on storage.objects for insert to anon,authenticated with check(bucket_id='payment-proofs' and (storage.foldername(name))[1]='public');
create policy "shop team reads payment proof" on storage.objects for select to authenticated using(bucket_id='payment-proofs' and exists(select 1 from public.customer_orders o where o.payment_proof_path=name and (public.owns_shop(o.shop_id) or public.works_at_shop(o.shop_id) or public.is_site_admin())));

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='delivery_bids') then alter publication supabase_realtime add table public.delivery_bids; end if;
end $$;
