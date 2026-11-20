-- Private live courier tracking and collection ETA.
-- Run after 20261120_production_portal_hardening.sql.

alter table public.delivery_bids add column if not exists pickup_eta_minutes integer check(pickup_eta_minutes is null or pickup_eta_minutes between 1 and 1440);
update public.delivery_bids set pickup_eta_minutes=greatest(1,ceil(courier_to_pickup_km/15.0*60)::integer) where pickup_eta_minutes is null;

create table if not exists public.delivery_tracking (
  delivery_id uuid primary key references public.deliveries(id) on delete cascade,
  courier_id uuid not null references public.couriers(id) on delete cascade,
  latitude double precision not null check(latitude between -90 and 90),
  longitude double precision not null check(longitude between -180 and 180),
  accuracy_m numeric(8,2) check(accuracy_m is null or accuracy_m>=0),
  speed_kph numeric(6,2) check(speed_kph is null or speed_kph between 0 and 120),
  heading numeric(6,2) check(heading is null or heading between 0 and 360),
  recorded_at timestamptz not null default now()
);
alter table public.delivery_tracking enable row level security;
create index if not exists delivery_tracking_courier_idx on public.delivery_tracking(courier_id,recorded_at desc);

create or replace function public.submit_delivery_bid(target_delivery uuid,offered_amount numeric,bid_note text,courier_lat double precision,courier_lng double precision)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries; courier_uuid uuid; min_fee numeric; pickup_km numeric; pickup_eta integer; bid_id uuid;
begin
  select id into courier_uuid from public.couriers c where c.user_id=auth.uid() and c.active and c.available;
  if courier_uuid is null or not exists(select 1 from public.courier_subscriptions where courier_id=courier_uuid and status in ('trial','active') and (ends_at is null or ends_at>now())) then raise exception 'Active subscribed courier required'; end if;
  select * into d from public.deliveries where id=target_delivery and status='open' for update;
  if not found then raise exception 'Delivery is no longer open'; end if;
  pickup_km=public.geo_distance_km(courier_lat,courier_lng,d.pickup_latitude,d.pickup_longitude);
  pickup_eta=greatest(1,ceil(pickup_km/15.0*60)::integer);
  min_fee=public.quote_courier_fee(courier_uuid,d.route_distance_km,(select delivery_city from public.customer_orders where id=d.order_id));
  if min_fee is null then raise exception 'Delivery is outside your configured service area'; end if;
  if offered_amount<min_fee then raise exception 'Offer cannot be below your minimum fare of %',min_fee; end if;
  update public.couriers set current_latitude=courier_lat,current_longitude=courier_lng,location_updated_at=now() where id=courier_uuid;
  insert into public.delivery_bids(delivery_id,courier_id,minimum_fee,offered_fee,courier_note,courier_to_pickup_km,pickup_to_dropoff_km,pickup_eta_minutes)
  values(d.id,courier_uuid,min_fee,offered_amount,nullif(trim(bid_note),''),pickup_km,d.route_distance_km,pickup_eta)
  on conflict(delivery_id,courier_id) do update set minimum_fee=excluded.minimum_fee,offered_fee=excluded.offered_fee,courier_note=excluded.courier_note,courier_to_pickup_km=excluded.courier_to_pickup_km,pickup_to_dropoff_km=excluded.pickup_to_dropoff_km,pickup_eta_minutes=excluded.pickup_eta_minutes,status='pending',submitted_at=now()
  returning id into bid_id;
  return bid_id;
end $$;

create or replace function public.update_courier_location(target_delivery uuid,courier_lat double precision,courier_lng double precision,location_accuracy numeric default null,courier_speed_kph numeric default null,courier_heading numeric default null)
returns timestamptz language plpgsql security definer set search_path=public as $$
declare courier_uuid uuid; update_time timestamptz:=now();
begin
  select c.id into courier_uuid from public.couriers c join public.deliveries d on d.courier_id=c.id
  where c.user_id=auth.uid() and d.id=target_delivery and d.status in ('accepted','collected','courier_completed');
  if courier_uuid is null then raise exception 'Assigned active courier job required'; end if;
  if courier_lat not between -90 and 90 or courier_lng not between -180 and 180 then raise exception 'Invalid location'; end if;
  insert into public.delivery_tracking(delivery_id,courier_id,latitude,longitude,accuracy_m,speed_kph,heading,recorded_at)
  values(target_delivery,courier_uuid,courier_lat,courier_lng,location_accuracy,case when courier_speed_kph between 0 and 120 then courier_speed_kph end,case when courier_heading between 0 and 360 then courier_heading end,update_time)
  on conflict(delivery_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,accuracy_m=excluded.accuracy_m,speed_kph=excluded.speed_kph,heading=excluded.heading,recorded_at=excluded.recorded_at;
  update public.couriers set current_latitude=courier_lat,current_longitude=courier_lng,location_updated_at=update_time where id=courier_uuid;
  return update_time;
end $$;

create or replace function public.get_customer_delivery_tracking(order_uuid uuid,tracking_uuid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'delivery_id',d.id,'status',d.status,'courier',c.display_name,'phone',c.phone,
    'latitude',t.latitude,'longitude',t.longitude,'accuracy_m',t.accuracy_m,'speed_kph',t.speed_kph,'heading',t.heading,'recorded_at',t.recorded_at,
    'pickup_latitude',d.pickup_latitude,'pickup_longitude',d.pickup_longitude,'delivery_latitude',d.delivery_latitude,'delivery_longitude',d.delivery_longitude,
    'courier_to_pickup_km',case when t.latitude is null then b.courier_to_pickup_km else public.geo_distance_km(t.latitude,t.longitude,d.pickup_latitude,d.pickup_longitude) end,
    'pickup_to_dropoff_km',d.route_distance_km,
    'pickup_eta_minutes',case when d.status='accepted' then greatest(1,ceil((case when t.latitude is null then b.courier_to_pickup_km else public.geo_distance_km(t.latitude,t.longitude,d.pickup_latitude,d.pickup_longitude) end)/(case when coalesce(t.speed_kph,0) between 5 and 80 then t.speed_kph else 15 end)*60)::integer) else 0 end,
    'delivery_eta_minutes',case when d.status in ('collected','courier_completed') and t.latitude is not null then greatest(1,ceil(public.geo_distance_km(t.latitude,t.longitude,d.delivery_latitude,d.delivery_longitude)/(case when coalesce(t.speed_kph,0) between 5 and 80 then t.speed_kph else 15 end)*60)::integer) else null end
  )
  from public.customer_orders o join public.deliveries d on d.order_id=o.id join public.couriers c on c.id=d.courier_id
  left join public.delivery_tracking t on t.delivery_id=d.id
  left join public.delivery_bids b on b.delivery_id=d.id and b.courier_id=d.courier_id and b.status='accepted'
  where o.id=order_uuid and o.tracking_token=tracking_uuid and d.status in ('accepted','collected','courier_completed','delivered')
$$;

create or replace function public.get_customer_order(order_uuid uuid,tracking_uuid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('id',o.id,'status',o.status,'amount',o.amount,'shop',s.name,'confirmation_note',o.confirmation_note,'rejection_reason',o.rejection_reason,'submitted_at',o.submitted_at,'confirmed_at',o.confirmed_at,'delivery',case when d.id is null then null else jsonb_build_object('id',d.id,'status',d.status,'pickup_address',d.pickup_address,'delivery_address',d.delivery_address,'parcel_details',d.parcel_details,'bids',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'courier',c.display_name,'phone',c.phone,'minimum_fee',b.minimum_fee,'offered_fee',b.offered_fee,'note',b.courier_note,'courier_to_pickup_km',b.courier_to_pickup_km,'pickup_to_dropoff_km',b.pickup_to_dropoff_km,'pickup_eta_minutes',b.pickup_eta_minutes,'status',b.status) order by b.offered_fee) from public.delivery_bids b join public.couriers c on c.id=b.courier_id where b.delivery_id=d.id and b.status in ('pending','accepted')),'[]'::jsonb)) end)
  from public.customer_orders o join public.shops s on s.id=o.shop_id left join public.deliveries d on d.order_id=o.id
  where o.id=order_uuid and o.tracking_token=tracking_uuid
$$;

revoke all on public.delivery_tracking from anon,authenticated;
revoke execute on function public.update_courier_location(uuid,double precision,double precision,numeric,numeric,numeric) from public;
revoke execute on function public.get_customer_delivery_tracking(uuid,uuid) from public;
grant execute on function public.update_courier_location(uuid,double precision,double precision,numeric,numeric,numeric) to authenticated;
grant execute on function public.get_customer_delivery_tracking(uuid,uuid) to anon,authenticated;

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='delivery_tracking') then alter publication supabase_realtime add table public.delivery_tracking; end if;
end $$;
