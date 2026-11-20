-- Durable, idempotent offline actions for ZWConnect sales and management flows.
-- Run after schema.sql and the earlier 20261119 migrations.

alter table public.owner_applications add column if not exists client_event_id uuid;
alter table public.shops add column if not exists deleted_at timestamptz;
create unique index if not exists owner_applications_client_event_id_key on public.owner_applications(client_event_id);

create table if not exists public.client_action_receipts (
  client_event_id uuid primary key,
  action_type text not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  shop_id uuid references public.shops(id) on delete set null,
  entity_id text,
  processed_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid not null references public.shops(id) on delete restrict,
  sold_by uuid not null references auth.users(id) on delete restrict,
  total numeric(14,2) not null check(total>=0),
  payment_method text not null check(payment_method in ('cash','ecocash','card','bank_transfer')),
  source_device text not null check(char_length(source_device) between 1 and 200),
  sold_at timestamptz not null,
  synced_at timestamptz not null default now()
);

create table if not exists public.sale_items (
  id bigint generated always as identity primary key,
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  sku text not null,
  quantity numeric(14,3) not null check(quantity>0),
  unit_price numeric(14,2) not null check(unit_price>=0),
  line_total numeric(14,2) generated always as (round(quantity*unit_price,2)) stored
);

create table if not exists public.worker_invitation_requests (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  email text not null,
  job public.worker_job not null,
  status text not null default 'pending' check(status in ('pending','sent','accepted','failed','cancelled')),
  requested_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create or replace function public.claim_client_action(event_id uuid,event_type text,target_shop uuid default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare inserted_rows integer;
begin
  insert into public.client_action_receipts(client_event_id,action_type,actor_id,shop_id)
  values(event_id,event_type,auth.uid(),target_shop) on conflict(client_event_id) do nothing;
  get diagnostics inserted_rows=row_count;
  return inserted_rows=1;
end $$;
revoke execute on function public.claim_client_action(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.submit_owner_application_offline(client_event_uuid uuid,owner_name text,owner_email text,owner_phone text,business_name text,business_profile text,business_city text,business_address text,uploaded_proof_path text,uploaded_proof_name text,uploaded_proof_mime text,uploaded_proof_size bigint)
returns uuid language plpgsql security definer set search_path=public as $$
declare application_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in before submitting an owner application'; end if;
  select id into application_id from public.owner_applications where client_event_id=client_event_uuid;
  if found then return application_id; end if;
  insert into public.owner_applications(client_event_id,applicant_id,owner_name,email,phone,business_name,profile_id,city,address,proof_path,proof_name,proof_mime,proof_size)
  values(client_event_uuid,auth.uid(),owner_name,lower(owner_email),owner_phone,business_name,business_profile,business_city,business_address,uploaded_proof_path,uploaded_proof_name,uploaded_proof_mime,uploaded_proof_size)
  returning id into application_id;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'owner_application.submitted','owner_application',application_id::text,jsonb_build_object('client_event_id',client_event_uuid));
  return application_id;
end $$;

create or replace function public.create_offline_sale(client_event_uuid uuid,target_shop uuid,cart_items jsonb,payment_method text,sale_total numeric,sold_at timestamptz,source_device text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_sale uuid; item jsonb; product_row public.products; qty numeric; computed_total numeric:=0;
begin
  if not (public.owns_shop(target_shop) or public.works_at_shop(target_shop)) then raise exception 'Not authorised to sell for this shop'; end if;
  if payment_method not in ('cash','ecocash','card','bank_transfer') then raise exception 'Invalid payment method'; end if;
  if jsonb_typeof(cart_items)<>'array' or jsonb_array_length(cart_items)=0 then raise exception 'Sale requires at least one item'; end if;
  if not public.claim_client_action(client_event_uuid,'sale.create',target_shop) then select id into new_sale from public.sales where client_event_id=client_event_uuid; return new_sale; end if;
  insert into public.sales(client_event_id,shop_id,sold_by,total,payment_method,source_device,sold_at)
  values(client_event_uuid,target_shop,auth.uid(),sale_total,payment_method,left(source_device,200),sold_at) returning id into new_sale;
  for item in select * from jsonb_array_elements(cart_items) loop
    qty=(item->>'quantity')::numeric;
    if qty<=0 then raise exception 'Sale quantity must be positive'; end if;
    select * into product_row from public.products where shop_id=target_shop and sku=item->>'sku' for update;
    if not found then raise exception 'Product % not found',item->>'sku'; end if;
    if product_row.quantity<qty then raise exception 'Insufficient stock for %',product_row.sku; end if;
    computed_total=computed_total+round(qty*product_row.price,2);
    insert into public.sale_items(sale_id,product_id,sku,quantity,unit_price) values(new_sale,product_row.id,product_row.sku,qty,product_row.price);
    update public.products set quantity=quantity-qty,updated_at=now() where id=product_row.id;
    insert into public.product_movements(client_event_id,shop_id,product_id,quantity_delta,reason,device_id,created_by,occurred_at)
    values(gen_random_uuid(),target_shop,product_row.id,-qty,'sale',left(source_device,200),auth.uid(),sold_at);
  end loop;
  if abs(computed_total-sale_total)>0.01 then raise exception 'Sale total does not match current product prices'; end if;
  update public.client_action_receipts set entity_id=new_sale::text where client_event_id=client_event_uuid;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'sale.synced','sale',new_sale::text,target_shop,jsonb_build_object('total',computed_total,'payment_method',payment_method));
  return new_sale;
end $$;

create or replace function public.queue_worker_invitation(client_event_uuid uuid,target_shop uuid,worker_name text,worker_email text,worker_job public.worker_job)
returns uuid language plpgsql security definer set search_path=public as $$
declare invitation_id uuid;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner may invite workers'; end if;
  if (select count(*) from public.shop_workers where shop_id=target_shop and active)+(select count(*) from public.worker_invitation_requests where shop_id=target_shop and status in ('pending','sent'))>=7 then raise exception 'This shop has reached the 7-worker limit'; end if;
  if not public.claim_client_action(client_event_uuid,'worker.invite',target_shop) then select id into invitation_id from public.worker_invitation_requests where client_event_id=client_event_uuid; return invitation_id; end if;
  insert into public.worker_invitation_requests(client_event_id,shop_id,name,email,job,requested_by) values(client_event_uuid,target_shop,worker_name,lower(worker_email),worker_job,auth.uid()) returning id into invitation_id;
  update public.client_action_receipts set entity_id=invitation_id::text where client_event_id=client_event_uuid;
  return invitation_id;
end $$;

create or replace function public.review_owner_application_offline(client_event_uuid uuid,application_uuid uuid,decision text,rejection_note text default null,requested_slug text default null)
returns text language plpgsql security definer set search_path=public as $$
declare result_id text;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may review applications'; end if;
  if decision not in ('approved','rejected') then raise exception 'Invalid review decision'; end if;
  if not public.claim_client_action(client_event_uuid,'application.review',null) then select entity_id into result_id from public.client_action_receipts where client_event_id=client_event_uuid; return result_id; end if;
  if decision='approved' then result_id=public.approve_owner_application(application_uuid,requested_slug)::text;
  else update public.owner_applications set status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),rejection_reason=rejection_note where id=application_uuid and status='pending' returning id::text into result_id;
  end if;
  if result_id is null then raise exception 'Pending application not found'; end if;
  update public.client_action_receipts set entity_id=result_id where client_event_id=client_event_uuid;
  return result_id;
end $$;

create or replace function public.update_shop_offline(client_event_uuid uuid,target_shop uuid,shop_changes jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not (public.owns_shop(target_shop) or public.is_site_admin()) then raise exception 'Not authorised to update this shop'; end if;
  if not public.claim_client_action(client_event_uuid,'shop.update',target_shop) then return target_shop; end if;
  update public.shops set name=coalesce(nullif(shop_changes->>'name',''),name),phone=coalesce(shop_changes->>'phone',phone),city=coalesce(nullif(shop_changes->>'city',''),city),address=coalesce(nullif(shop_changes->>'address',''),address),image_url=coalesce(shop_changes->>'image_url',image_url),opening_hours=coalesce(shop_changes->'opening_hours',opening_hours) where id=target_shop;
  update public.client_action_receipts set entity_id=target_shop::text where client_event_id=client_event_uuid;
  return target_shop;
end $$;

create or replace function public.delete_shop_offline(client_event_uuid uuid,target_shop uuid)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may delete shops'; end if;
  if not public.claim_client_action(client_event_uuid,'shop.delete',target_shop) then return target_shop; end if;
  -- Preserve sales, audit and subscription history while removing public access.
  update public.shops set status='suspended',deleted_at=now() where id=target_shop;
  update public.client_action_receipts set entity_id=target_shop::text where client_event_id=client_event_uuid;
  return target_shop;
end $$;

create or replace function public.set_shop_subscription_offline(client_event_uuid uuid,target_shop uuid,subscription_amount numeric,subscription_duration_days integer,trial_days integer,new_status public.subscription_status)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may manage subscriptions'; end if;
  if not public.claim_client_action(client_event_uuid,'subscription.update',target_shop) then return target_shop; end if;
  perform public.set_shop_subscription(target_shop,subscription_amount,subscription_duration_days,trial_days,new_status);
  update public.client_action_receipts set entity_id=target_shop::text where client_event_id=client_event_uuid;
  return target_shop;
end $$;

grant execute on function public.create_offline_sale(uuid,uuid,jsonb,text,numeric,timestamptz,text) to authenticated;
grant execute on function public.submit_owner_application_offline(uuid,text,text,text,text,text,text,text,text,text,text,bigint) to authenticated;
grant execute on function public.queue_worker_invitation(uuid,uuid,text,text,public.worker_job) to authenticated;
grant execute on function public.review_owner_application_offline(uuid,uuid,text,text,text) to authenticated;
grant execute on function public.update_shop_offline(uuid,uuid,jsonb) to authenticated;
grant execute on function public.delete_shop_offline(uuid,uuid) to authenticated;
grant execute on function public.set_shop_subscription_offline(uuid,uuid,numeric,integer,integer,public.subscription_status) to authenticated;

alter table public.client_action_receipts enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.worker_invitation_requests enable row level security;
create policy "actors read own action receipts" on public.client_action_receipts for select using(actor_id=auth.uid() or public.is_site_admin());
create policy "shop team reads sales" on public.sales for select using(public.owns_shop(shop_id) or public.works_at_shop(shop_id) or public.is_site_admin());
create policy "shop team reads sale items" on public.sale_items for select using(exists(select 1 from public.sales s where s.id=sale_id and (public.owns_shop(s.shop_id) or public.works_at_shop(s.shop_id) or public.is_site_admin())));
create policy "owners read invitation requests" on public.worker_invitation_requests for select using(public.owns_shop(shop_id) or public.is_site_admin());

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='sales') then alter publication supabase_realtime add table public.sales; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='worker_invitation_requests') then alter publication supabase_realtime add table public.worker_invitation_requests; end if;
end $$;
