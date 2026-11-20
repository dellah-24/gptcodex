-- Production portal controls: bulk subscriptions, profile CRUD, support retention,
-- shop media limits, owner subscription requests and courier delivery handoff.
-- Run after 20261120_cart_delivery_bidding.sql.

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid unique,
  requester_id uuid references auth.users(id) on delete set null,
  requester_role text not null default 'public' check(requester_role in ('public','shop_owner','worker','courier')),
  requester_name text not null,
  requester_email text,
  requester_phone text,
  category text not null check(category in ('request','complaint','billing','shop','courier','technical','other')),
  subject text not null check(char_length(subject) between 3 and 160),
  message text not null check(char_length(message) between 5 and 5000),
  status text not null default 'pending' check(status in ('pending','in_progress','attended')),
  priority text not null default 'normal' check(priority in ('low','normal','high','urgent')),
  assigned_to uuid references auth.users(id) on delete set null,
  admin_note text,
  created_at timestamptz not null default now(),
  attended_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_status_created_idx on public.support_tickets(status,created_at desc);

create or replace function public.prune_attended_support_tickets()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  delete from public.support_tickets where status='attended' and id not in (
    select id from public.support_tickets where status='attended' order by attended_at desc nulls last,updated_at desc limit 20
  );
  return null;
end $$;
drop trigger if exists support_ticket_retention on public.support_tickets;
create trigger support_ticket_retention after insert or update of status,attended_at on public.support_tickets for each statement execute function public.prune_attended_support_tickets();
delete from public.support_tickets where status='attended' and id not in (select id from public.support_tickets where status='attended' order by attended_at desc nulls last,updated_at desc limit 20);

create or replace function public.prune_audit_events()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  delete from public.audit_events where id not in (select id from public.audit_events order by created_at desc,id desc limit 20);
  return null;
end $$;
drop trigger if exists audit_event_retention on public.audit_events;
create trigger audit_event_retention after insert on public.audit_events for each statement execute function public.prune_audit_events();
delete from public.audit_events where id not in (select id from public.audit_events order by created_at desc,id desc limit 20);

create table if not exists public.shop_images (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  storage_path text not null unique,
  public_url text,
  alt_text text not null default '',
  position smallint not null check(position between 1 and 3),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(shop_id,position)
);

create or replace function public.enforce_shop_image_limit()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if (select count(*) from public.shop_images where shop_id=new.shop_id and id<>new.id)>=3 then raise exception 'A shop profile may contain no more than 3 images'; end if;
  return new;
end $$;
drop trigger if exists shop_image_limit on public.shop_images;
create trigger shop_image_limit before insert or update of shop_id on public.shop_images for each row execute function public.enforce_shop_image_limit();

create table if not exists public.subscription_requests (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid not null references public.shops(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete restrict,
  request_type text not null check(request_type in ('renew','extend','cancel')),
  requested_days integer check(requested_days is null or requested_days between 1 and 3650),
  owner_note text,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  admin_note text,
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists one_pending_subscription_request_per_shop on public.subscription_requests(shop_id) where status='pending';

alter table public.deliveries drop constraint if exists deliveries_status_check;
alter table public.deliveries add constraint deliveries_status_check check(status in ('open','accepted','collected','courier_completed','delivered','cancelled'));
alter table public.deliveries add column if not exists collected_at timestamptz;
alter table public.deliveries add column if not exists courier_completed_at timestamptz;
alter table public.deliveries add column if not exists customer_received_at timestamptz;
create unique index if not exists one_active_delivery_per_courier on public.deliveries(courier_id) where courier_id is not null and status in ('accepted','collected','courier_completed');
create index if not exists deliveries_status_created_idx on public.deliveries(status,created_at desc);
create index if not exists subscription_requests_status_created_idx on public.subscription_requests(status,created_at desc);
create index if not exists shop_images_shop_position_idx on public.shop_images(shop_id,position);

create or replace function public.enforce_courier_single_job_bidding()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.deliveries where courier_id=new.courier_id and status in ('accepted','collected','courier_completed')) then raise exception 'Complete the active delivery before bidding for another job'; end if;
  return new;
end $$;
drop trigger if exists courier_single_job_bidding on public.delivery_bids;
create trigger courier_single_job_bidding before insert or update of offered_fee,courier_id on public.delivery_bids for each row execute function public.enforce_courier_single_job_bidding();

create or replace function public.set_all_platform_subscriptions(
  apply_to_shops boolean,apply_to_couriers boolean,shop_amount numeric,courier_amount numeric,
  subscription_duration_days integer,trial_days integer,new_status public.subscription_status
) returns jsonb language plpgsql security definer set search_path=public as $$
declare shop_count integer:=0; courier_count integer:=0;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may manage subscriptions'; end if;
  if not apply_to_shops and not apply_to_couriers then raise exception 'Choose shops, couriers or both'; end if;
  if shop_amount<0 or courier_amount<0 or subscription_duration_days<1 or trial_days<0 then raise exception 'Invalid subscription values'; end if;
  if apply_to_shops then
    insert into public.shop_subscriptions(shop_id,amount,duration_days,trial_ends_at,starts_at,ends_at,status,updated_by,updated_at)
    select s.id,shop_amount,subscription_duration_days,case when trial_days>0 then now()+make_interval(days=>trial_days) end,now(),now()+make_interval(days=>subscription_duration_days),new_status,auth.uid(),now() from public.shops s where s.deleted_at is null
    on conflict(shop_id) do update set amount=excluded.amount,duration_days=excluded.duration_days,trial_ends_at=excluded.trial_ends_at,starts_at=excluded.starts_at,ends_at=excluded.ends_at,status=excluded.status,updated_by=excluded.updated_by,updated_at=now();
    get diagnostics shop_count=row_count;
  end if;
  if apply_to_couriers then
    insert into public.courier_subscriptions(courier_id,amount,duration_days,trial_ends_at,starts_at,ends_at,status,updated_by,updated_at)
    select c.id,courier_amount,subscription_duration_days,case when trial_days>0 then now()+make_interval(days=>trial_days) end,now(),now()+make_interval(days=>subscription_duration_days),new_status,auth.uid(),now() from public.couriers c where c.active
    on conflict(courier_id) do update set amount=excluded.amount,duration_days=excluded.duration_days,trial_ends_at=excluded.trial_ends_at,starts_at=excluded.starts_at,ends_at=excluded.ends_at,status=excluded.status,updated_by=excluded.updated_by,updated_at=now();
    get diagnostics courier_count=row_count;
  end if;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'subscriptions.bulk_updated','platform','subscriptions',jsonb_build_object('shops',shop_count,'couriers',courier_count,'duration_days',subscription_duration_days,'trial_days',trial_days,'status',new_status));
  return jsonb_build_object('shops_updated',shop_count,'couriers_updated',courier_count);
end $$;

create or replace function public.admin_create_business_profile(profile_id text,profile_title text,profile_icon text,profile_description text,profile_order integer default 0)
returns text language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Site admin access required'; end if;
  if profile_id!~'^[a-z][a-z0-9-]{1,48}$' then raise exception 'Profile ID must be a lowercase slug'; end if;
  insert into public.business_profiles(id,title,icon,description,display_order,enabled) values(profile_id,trim(profile_title),trim(profile_icon),trim(profile_description),profile_order,true)
  on conflict(id) do update set title=excluded.title,icon=excluded.icon,description=excluded.description,display_order=excluded.display_order,enabled=true;
  insert into public.audit_events(actor_id,action,entity_type,entity_id) values(auth.uid(),'business_profile.created','business_profile',profile_id);
  return profile_id;
end $$;

create or replace function public.admin_update_business_profile(profile_id text,profile_title text,profile_icon text,profile_description text,profile_order integer,profile_enabled boolean)
returns text language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Site admin access required'; end if;
  update public.business_profiles set title=trim(profile_title),icon=trim(profile_icon),description=trim(profile_description),display_order=profile_order,enabled=profile_enabled where id=profile_id;
  if not found then raise exception 'Business profile not found'; end if;
  insert into public.audit_events(actor_id,action,entity_type,entity_id) values(auth.uid(),'business_profile.updated','business_profile',profile_id);
  return profile_id;
end $$;

create or replace function public.admin_delete_business_profile(target_profile text)
returns text language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Site admin access required'; end if;
  if exists(select 1 from public.shops where profile_id=target_profile) or exists(select 1 from public.owner_applications where profile_id=target_profile) then raise exception 'Reassign linked shops and applications before deleting this profile'; end if;
  delete from public.business_profiles where id=target_profile;
  insert into public.audit_events(actor_id,action,entity_type,entity_id) values(auth.uid(),'business_profile.deleted','business_profile',target_profile);
  return target_profile;
end $$;

create or replace function public.submit_support_ticket(client_event_uuid uuid,requester_name text,requester_email text,requester_phone text,ticket_category text,ticket_subject text,ticket_message text,requester_role text default 'public')
returns uuid language plpgsql security definer set search_path=public as $$
declare ticket_id uuid;
begin
  select id into ticket_id from public.support_tickets where client_event_id=client_event_uuid;
  if found then return ticket_id; end if;
  if nullif(trim(requester_name),'') is null or nullif(trim(ticket_subject),'') is null or nullif(trim(ticket_message),'') is null then raise exception 'Name, subject and message are required'; end if;
  insert into public.support_tickets(client_event_id,requester_id,requester_role,requester_name,requester_email,requester_phone,category,subject,message)
  values(client_event_uuid,auth.uid(),case when requester_role in ('public','shop_owner','worker','courier') then requester_role else 'public' end,trim(requester_name),nullif(lower(trim(requester_email)),''),nullif(trim(requester_phone),''),ticket_category,trim(ticket_subject),trim(ticket_message)) returning id into ticket_id;
  return ticket_id;
end $$;

create or replace function public.admin_update_support_ticket(ticket_id uuid,new_status text,decision_note text,priority_level text default 'normal')
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Site admin access required'; end if;
  if new_status not in ('pending','in_progress','attended') or priority_level not in ('low','normal','high','urgent') then raise exception 'Invalid ticket status or priority'; end if;
  update public.support_tickets set status=new_status,priority=priority_level,admin_note=nullif(trim(decision_note),''),assigned_to=auth.uid(),attended_at=case when new_status='attended' then now() else null end,updated_at=now() where id=ticket_id;
  if not found then raise exception 'Support ticket not found'; end if;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'support_ticket.updated','support_ticket',ticket_id::text,jsonb_build_object('status',new_status,'priority',priority_level));
  return ticket_id;
end $$;

create or replace function public.save_shop_image(image_uuid uuid,target_shop uuid,object_path text,alt_text text,requested_position integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare image_id uuid;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner can manage profile images'; end if;
  if requested_position not between 1 and 3 then raise exception 'Image position must be 1, 2 or 3'; end if;
  select id into image_id from public.shop_images where id=image_uuid and shop_id=target_shop;
  if found then return image_id; end if;
  insert into public.shop_images(id,shop_id,storage_path,public_url,alt_text,position,created_by) values(image_uuid,target_shop,object_path,null,coalesce(trim(alt_text),''),requested_position,auth.uid()) returning id into image_id;
  return image_id;
end $$;

create or replace function public.delete_shop_image(image_uuid uuid)
returns text language plpgsql security definer set search_path=public as $$
declare stored_path text;
begin
  delete from public.shop_images i where i.id=image_uuid and public.owns_shop(i.shop_id) returning storage_path into stored_path;
  if stored_path is null then raise exception 'Shop image not found or access denied'; end if;
  return stored_path;
end $$;

create or replace function public.submit_subscription_request(client_event_uuid uuid,target_shop uuid,request_kind text,extension_days integer,request_note text)
returns uuid language plpgsql security definer set search_path=public as $$
declare request_id uuid;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner can change this subscription'; end if;
  select id into request_id from public.subscription_requests where client_event_id=client_event_uuid and requested_by=auth.uid();
  if found then return request_id; end if;
  if request_kind not in ('renew','extend','cancel') then raise exception 'Invalid subscription request'; end if;
  if request_kind='extend' and coalesce(extension_days,0)<1 then raise exception 'Extension days are required'; end if;
  select id into request_id from public.subscription_requests where shop_id=target_shop and status='pending' order by created_at desc limit 1;
  if found then return request_id; end if;
  insert into public.subscription_requests(client_event_id,shop_id,requested_by,request_type,requested_days,owner_note) values(client_event_uuid,target_shop,auth.uid(),request_kind,case when request_kind='extend' then extension_days end,nullif(trim(request_note),'')) returning id into request_id;
  return request_id;
end $$;

create or replace function public.admin_review_subscription_request(request_uuid uuid,approve boolean,decision_note text)
returns uuid language plpgsql security definer set search_path=public as $$
declare r public.subscription_requests;
begin
  if not public.is_site_admin() then raise exception 'Site admin access required'; end if;
  select * into r from public.subscription_requests where id=request_uuid for update;
  if not found then raise exception 'Subscription request not found'; end if;
  if r.status<>'pending' then return r.id; end if;
  if nullif(trim(decision_note),'') is null then raise exception 'Add an owner-visible decision note'; end if;
  if approve and r.request_type='cancel' then update public.shop_subscriptions set status='cancelled',updated_by=auth.uid(),updated_at=now() where shop_id=r.shop_id; end if;
  if approve and r.request_type in ('renew','extend') then update public.shop_subscriptions set status='active',starts_at=case when r.request_type='renew' then now() else starts_at end,ends_at=greatest(coalesce(ends_at,now()),now())+make_interval(days=>coalesce(r.requested_days,duration_days)),updated_by=auth.uid(),updated_at=now() where shop_id=r.shop_id; end if;
  update public.subscription_requests set status=case when approve then 'approved' else 'rejected' end,admin_note=decision_note,reviewed_by=auth.uid(),reviewed_at=now() where id=r.id;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'subscription_request.reviewed','subscription_request',r.id::text,r.shop_id,jsonb_build_object('approved',approve,'type',r.request_type));
  return r.id;
end $$;

create or replace function public.courier_update_delivery_status(delivery_uuid uuid,new_status text)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries;
begin
  select * into d from public.deliveries where id=delivery_uuid and public.is_courier(courier_id) for update;
  if not found then raise exception 'Assigned delivery not found'; end if;
  if d.status=new_status then return d.id; end if;
  if not ((d.status='accepted' and new_status='collected') or (d.status='collected' and new_status='courier_completed')) then raise exception 'Invalid delivery status transition'; end if;
  update public.deliveries set status=new_status,collected_at=case when new_status='collected' then now() else collected_at end,courier_completed_at=case when new_status='courier_completed' then now() else courier_completed_at end where id=d.id;
  update public.customer_orders set status='dispatched' where id=d.order_id and new_status in ('collected','courier_completed');
  return d.id;
end $$;

create or replace function public.customer_confirm_delivery(order_uuid uuid,tracking_uuid uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries;
begin
  select dlv.* into d from public.deliveries dlv join public.customer_orders o on o.id=dlv.order_id where o.id=order_uuid and o.tracking_token=tracking_uuid and dlv.status in ('courier_completed','delivered') for update of dlv;
  if not found then raise exception 'Delivery is not awaiting customer receipt'; end if;
  if d.status='delivered' then return d.id; end if;
  update public.deliveries set status='delivered',customer_received_at=now(),delivered_at=now() where id=d.id;
  update public.customer_orders set status='completed' where id=order_uuid;
  return d.id;
end $$;

-- Replace bid acceptance with the one-active-job guard.
create or replace function public.decide_delivery_bid(order_uuid uuid,tracking_uuid uuid,target_bid uuid,accept_bid boolean)
returns uuid language plpgsql security definer set search_path=public as $$
declare d public.deliveries; b public.delivery_bids; booking_fee numeric;
begin
  select dlv.* into d from public.deliveries dlv join public.customer_orders o on o.id=dlv.order_id where o.id=order_uuid and o.tracking_token=tracking_uuid and dlv.status='open' for update of dlv;
  if not found then raise exception 'Open delivery not found'; end if;
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

alter table public.support_tickets enable row level security;
alter table public.shop_images enable row level security;
alter table public.subscription_requests enable row level security;
create policy "admins read support tickets" on public.support_tickets for select using(public.is_site_admin());
create policy "admins read all business profiles" on public.business_profiles for select using(public.is_site_admin() or enabled);
create policy "public reads shop images" on public.shop_images for select using(true);
create policy "owners manage shop images" on public.shop_images for all using(public.owns_shop(shop_id)) with check(public.owns_shop(shop_id));
create policy "owners and admins read subscription requests" on public.subscription_requests for select using(public.owns_shop(shop_id) or public.is_site_admin());

revoke execute on function public.set_all_platform_subscriptions(boolean,boolean,numeric,numeric,integer,integer,public.subscription_status) from public,anon,authenticated;
revoke execute on function public.admin_create_business_profile(text,text,text,text,integer) from public,anon,authenticated;
revoke execute on function public.admin_update_business_profile(text,text,text,text,integer,boolean) from public,anon,authenticated;
revoke execute on function public.admin_delete_business_profile(text) from public,anon,authenticated;
revoke execute on function public.submit_support_ticket(uuid,text,text,text,text,text,text,text) from public,anon,authenticated;
revoke execute on function public.admin_update_support_ticket(uuid,text,text,text) from public,anon,authenticated;
revoke execute on function public.save_shop_image(uuid,uuid,text,text,integer) from public,anon,authenticated;
revoke execute on function public.delete_shop_image(uuid) from public,anon,authenticated;
revoke execute on function public.submit_subscription_request(uuid,uuid,text,integer,text) from public,anon,authenticated;
revoke execute on function public.admin_review_subscription_request(uuid,boolean,text) from public,anon,authenticated;
revoke execute on function public.courier_update_delivery_status(uuid,text) from public,anon,authenticated;
revoke execute on function public.customer_confirm_delivery(uuid,uuid) from public,anon,authenticated;
grant execute on function public.set_all_platform_subscriptions(boolean,boolean,numeric,numeric,integer,integer,public.subscription_status) to authenticated;
grant execute on function public.admin_create_business_profile(text,text,text,text,integer) to authenticated;
grant execute on function public.admin_update_business_profile(text,text,text,text,integer,boolean) to authenticated;
grant execute on function public.admin_delete_business_profile(text) to authenticated;
grant execute on function public.submit_support_ticket(uuid,text,text,text,text,text,text,text) to anon,authenticated;
grant execute on function public.admin_update_support_ticket(uuid,text,text,text) to authenticated;
grant execute on function public.save_shop_image(uuid,uuid,text,text,integer) to authenticated;
grant execute on function public.delete_shop_image(uuid) to authenticated;
grant execute on function public.submit_subscription_request(uuid,uuid,text,integer,text) to authenticated;
grant execute on function public.admin_review_subscription_request(uuid,boolean,text) to authenticated;
grant execute on function public.courier_update_delivery_status(uuid,text) to authenticated;
grant execute on function public.customer_confirm_delivery(uuid,uuid) to anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('shop-images','shop-images',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "owners upload shop images" on storage.objects for insert to authenticated with check(bucket_id='shop-images' and public.owns_shop(((storage.foldername(name))[1])::uuid));
create policy "owners update shop images" on storage.objects for update to authenticated using(bucket_id='shop-images' and public.owns_shop(((storage.foldername(name))[1])::uuid)) with check(bucket_id='shop-images' and public.owns_shop(((storage.foldername(name))[1])::uuid));
create policy "owners delete shop images" on storage.objects for delete to authenticated using(bucket_id='shop-images' and public.owns_shop(((storage.foldername(name))[1])::uuid));

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='support_tickets') then alter publication supabase_realtime add table public.support_tickets; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='subscription_requests') then alter publication supabase_realtime add table public.subscription_requests; end if;
end $$;
