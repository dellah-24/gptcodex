-- Adds explicit singular-unit and full-case selling while keeping stock in base units.
-- Run after 20261120_full_offline_action_sync.sql.

alter table public.products add column if not exists case_size integer not null default 1 check(case_size>0);
alter table public.products add column if not exists case_price numeric(14,2) check(case_price is null or case_price>=0);
alter table public.products add column if not exists allow_case_sales boolean not null default false;
alter table public.owner_applications add column if not exists sales_mode text not null default 'retail' check(sales_mode in ('retail','wholesale','hybrid'));
alter table public.shops add column if not exists sales_mode text not null default 'retail' check(sales_mode in ('retail','wholesale','hybrid'));

update public.shops set sales_mode=case when profile_id='liquor' then 'wholesale' when profile_id in ('grocery','hardware','auto','stationery','fuel') then 'hybrid' else 'retail' end where sales_mode='retail';

update public.products p set
  case_size=case s.profile_id when 'liquor' then 6 when 'grocery' then 12 when 'butchery' then 10 when 'bakery' then 12 when 'electronics' then 10 when 'auto' then 4 when 'hardware' then 10 when 'stationery' then 12 when 'furniture' then 2 else 6 end,
  allow_case_sales=true
from public.shops s where s.id=p.shop_id and p.case_size=1 and p.allow_case_sales=false;
update public.products set case_price=round(price*case_size*.97,2) where allow_case_sales and case_price is null;

alter table public.sale_items add column if not exists sale_unit text not null default 'unit';
alter table public.sale_items add column if not exists package_quantity numeric(14,3);
alter table public.sale_items add column if not exists base_quantity numeric(14,3);
update public.sale_items set package_quantity=coalesce(package_quantity,quantity),base_quantity=coalesce(base_quantity,quantity) where package_quantity is null or base_quantity is null;
alter table public.sale_items alter column package_quantity set not null;
alter table public.sale_items alter column base_quantity set not null;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='sale_items_sale_unit_check') then alter table public.sale_items add constraint sale_items_sale_unit_check check(sale_unit in ('unit','case')); end if;
  if not exists(select 1 from pg_constraint where conname='sale_items_package_quantity_check') then alter table public.sale_items add constraint sale_items_package_quantity_check check(package_quantity>0); end if;
  if not exists(select 1 from pg_constraint where conname='sale_items_base_quantity_check') then alter table public.sale_items add constraint sale_items_base_quantity_check check(base_quantity>0); end if;
end $$;

drop function if exists public.submit_owner_application_offline(uuid,text,text,text,text,text,text,text,text,text,text,bigint);
create or replace function public.submit_owner_application_offline(client_event_uuid uuid,owner_name text,owner_email text,owner_phone text,business_name text,business_profile text,business_city text,business_address text,store_sales_mode text,uploaded_proof_path text,uploaded_proof_name text,uploaded_proof_mime text,uploaded_proof_size bigint)
returns uuid language plpgsql security definer set search_path=public as $$
declare application_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in before submitting an owner application'; end if;
  if store_sales_mode not in ('retail','wholesale','hybrid') then raise exception 'Invalid store trading model'; end if;
  select id into application_id from public.owner_applications where client_event_id=client_event_uuid;
  if found then return application_id; end if;
  insert into public.owner_applications(client_event_id,applicant_id,owner_name,email,phone,business_name,profile_id,city,address,sales_mode,proof_path,proof_name,proof_mime,proof_size)
  values(client_event_uuid,auth.uid(),owner_name,lower(owner_email),owner_phone,business_name,business_profile,business_city,business_address,store_sales_mode,uploaded_proof_path,uploaded_proof_name,uploaded_proof_mime,uploaded_proof_size)
  returning id into application_id;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'owner_application.submitted','owner_application',application_id::text,jsonb_build_object('client_event_id',client_event_uuid,'sales_mode',store_sales_mode));
  return application_id;
end $$;

create or replace function public.approve_owner_application(application_uuid uuid,shop_slug text)
returns uuid language plpgsql security definer set search_path=public as $$
declare app public.owner_applications; new_shop uuid;
begin
  if not public.is_site_admin() then raise exception 'Only a site admin may approve owners'; end if;
  select * into app from public.owner_applications where id=application_uuid and status='pending' for update;
  if not found then raise exception 'Pending application not found'; end if;
  insert into public.account_roles(user_id,role) values(app.applicant_id,'shop_owner') on conflict(user_id) do update set role='shop_owner' where public.account_roles.role='shop_owner';
  if not found then raise exception 'Applicant already has a different platform role'; end if;
  insert into public.shops(owner_id,application_id,profile_id,name,slug,phone,city,address,latitude,longitude,sales_mode,status,verified_at)
  values(app.applicant_id,app.id,app.profile_id,app.business_name,shop_slug,app.phone,app.city,app.address,coalesce(app.latitude,0),coalesce(app.longitude,0),app.sales_mode,'draft',now()) returning id into new_shop;
  update public.owner_applications set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=app.id;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'owner_application.approved','owner_application',app.id::text,new_shop,jsonb_build_object('sales_mode',app.sales_mode));
  return new_shop;
end $$;

create or replace function public.create_offline_sale(client_event_uuid uuid,target_shop uuid,cart_items jsonb,payment_method text,sale_total numeric,sold_at timestamptz,source_device text)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  new_sale uuid; item jsonb; product_row public.products;
  package_qty numeric; base_qty numeric; selling_price numeric;
  selected_unit text; selected_case_size integer; computed_total numeric:=0; shop_sales_mode text;
begin
  if not (public.owns_shop(target_shop) or public.works_at_shop(target_shop)) then raise exception 'Not authorised to sell for this shop'; end if;
  select sales_mode into shop_sales_mode from public.shops where id=target_shop;
  if shop_sales_mode is null then raise exception 'Shop not found'; end if;
  if payment_method not in ('cash','ecocash','card','bank_transfer') then raise exception 'Invalid payment method'; end if;
  if jsonb_typeof(cart_items)<>'array' or jsonb_array_length(cart_items)=0 then raise exception 'Sale requires at least one item'; end if;
  if not public.claim_client_action(client_event_uuid,'sale.create',target_shop) then select id into new_sale from public.sales where client_event_id=client_event_uuid; return new_sale; end if;

  insert into public.sales(client_event_id,shop_id,sold_by,total,payment_method,source_device,sold_at)
  values(client_event_uuid,target_shop,auth.uid(),sale_total,payment_method,left(source_device,200),sold_at) returning id into new_sale;

  for item in select * from jsonb_array_elements(cart_items) loop
    package_qty=(item->>'quantity')::numeric;
    selected_unit=coalesce(item->>'sale_unit','unit');
    if package_qty<=0 or selected_unit not in ('unit','case') then raise exception 'Invalid sale quantity or package type'; end if;
    if shop_sales_mode='wholesale' and selected_unit<>'case' then raise exception 'This shop permits wholesale case sales only'; end if;
    if shop_sales_mode='retail' and selected_unit<>'unit' then raise exception 'This shop permits retail unit sales only'; end if;

    select * into product_row from public.products where shop_id=target_shop and sku=item->>'sku' for update;
    if not found then raise exception 'Product % not found',item->>'sku'; end if;

    if selected_unit='case' then
      if not product_row.allow_case_sales or product_row.case_size<=1 then raise exception 'Case sales are not enabled for %',product_row.sku; end if;
      selected_case_size=product_row.case_size;
      base_qty=package_qty*selected_case_size;
      selling_price=coalesce(product_row.case_price,round(product_row.price*selected_case_size,2));
    else
      selected_case_size=1;
      base_qty=package_qty;
      selling_price=product_row.price;
    end if;

    if product_row.quantity<base_qty then raise exception 'Insufficient base-unit stock for %',product_row.sku; end if;
    computed_total=computed_total+round(package_qty*selling_price,2);
    insert into public.sale_items(sale_id,product_id,sku,quantity,unit_price,sale_unit,package_quantity,base_quantity)
    values(new_sale,product_row.id,product_row.sku,package_qty,selling_price,selected_unit,package_qty,base_qty);
    update public.products set quantity=quantity-base_qty,updated_at=now() where id=product_row.id;
  end loop;

  if abs(computed_total-sale_total)>0.01 then raise exception 'Sale total does not match authoritative package pricing'; end if;
  update public.sales set total=computed_total where id=new_sale;
  update public.client_action_receipts set entity_id=new_sale::text where client_event_id=client_event_uuid;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata)
  values(auth.uid(),'sale.created','sale',new_sale::text,target_shop,jsonb_build_object('total',computed_total,'payment_method',payment_method,'supports_case_units',true));
  return new_sale;
end $$;

create or replace function public.update_shop_offline(client_event_uuid uuid,target_shop uuid,shop_changes jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare requested_mode text;
begin
  if not (public.owns_shop(target_shop) or public.is_site_admin()) then raise exception 'Not authorised to update this shop'; end if;
  requested_mode=shop_changes->>'sales_mode';
  if requested_mode is not null and requested_mode not in ('retail','wholesale','hybrid') then raise exception 'Invalid store trading model'; end if;
  if not public.claim_client_action(client_event_uuid,'shop.update',target_shop) then return target_shop; end if;
  update public.shops set name=coalesce(nullif(shop_changes->>'name',''),name),phone=coalesce(shop_changes->>'phone',phone),city=coalesce(nullif(shop_changes->>'city',''),city),address=coalesce(nullif(shop_changes->>'address',''),address),image_url=coalesce(shop_changes->>'image_url',image_url),opening_hours=coalesce(shop_changes->'opening_hours',opening_hours),sales_mode=coalesce(requested_mode,sales_mode) where id=target_shop;
  update public.client_action_receipts set entity_id=target_shop::text where client_event_id=client_event_uuid;
  return target_shop;
end $$;

revoke execute on function public.create_offline_sale(uuid,uuid,jsonb,text,numeric,timestamptz,text) from public,anon;
grant execute on function public.create_offline_sale(uuid,uuid,jsonb,text,numeric,timestamptz,text) to authenticated;
grant execute on function public.submit_owner_application_offline(uuid,text,text,text,text,text,text,text,text,text,text,text,bigint) to authenticated;

comment on column public.products.quantity is 'Stock held in base singular units. Case sales deduct case_size multiplied by cases sold.';
comment on column public.shops.sales_mode is 'Trading model: retail accepts singular units, wholesale accepts full cases, and hybrid accepts both.';
comment on column public.sale_items.package_quantity is 'Number of singular units or cases selected on the receipt.';
comment on column public.sale_items.base_quantity is 'Total singular units deducted from inventory.';
