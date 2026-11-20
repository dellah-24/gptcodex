-- LP Gas retail/wholesale profile, cylinder controls and attributable POS ledger postings.
-- Run after 20261120_courier_live_tracking.sql.

insert into public.business_profiles(id,title,icon,description,display_order,enabled)
values('lpg','LP Gas Retail & Wholesale','flame','Licensed LP gas refills, cylinder exchanges, wholesale supply and safety accessories.',16,true)
on conflict(id) do update set title=excluded.title,icon=excluded.icon,description=excluded.description,display_order=excluded.display_order,enabled=true;

update public.shops set sales_mode='hybrid' where profile_id='lpg' and sales_mode='retail';

create table if not exists public.lpg_shop_settings (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  licence_number text not null,
  licence_expires_on date,
  supports_refills boolean not null default true,
  supports_exchanges boolean not null default true,
  supports_new_cylinders boolean not null default true,
  supports_delivery boolean not null default false,
  safety_certified boolean not null default false,
  emergency_phone text,
  updated_by uuid references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);

create table if not exists public.lpg_product_details (
  product_id uuid primary key references public.products(id) on delete cascade,
  cylinder_size_kg numeric(7,2) check(cylinder_size_kg is null or cylinder_size_kg>0),
  offering_type text not null check(offering_type in ('refill','exchange','new_cylinder','accessory')),
  cylinder_brand text,
  requires_empty_return boolean not null default false,
  refundable_deposit numeric(14,2) not null default 0 check(refundable_deposit>=0),
  filled_cylinder_count integer check(filled_cylinder_count is null or filled_cylinder_count>=0),
  empty_cylinder_count integer check(empty_cylinder_count is null or empty_cylinder_count>=0),
  updated_at timestamptz not null default now()
);

alter table public.lpg_shop_settings enable row level security;
alter table public.lpg_product_details enable row level security;
create policy "public reads active lpg shop settings" on public.lpg_shop_settings for select using(exists(select 1 from public.shops s where s.id=shop_id and s.status='active'));
create policy "owners manage lpg shop settings" on public.lpg_shop_settings for all using(public.owns_shop(shop_id) or public.is_site_admin()) with check(public.owns_shop(shop_id) or public.is_site_admin());
create policy "public reads published lpg products" on public.lpg_product_details for select using(exists(select 1 from public.products p where p.id=product_id and p.published));
create policy "shop team manages lpg product details" on public.lpg_product_details for all using(exists(select 1 from public.products p where p.id=product_id and (public.owns_shop(p.shop_id) or public.works_at_shop(p.shop_id) or public.is_site_admin()))) with check(exists(select 1 from public.products p where p.id=product_id and (public.owns_shop(p.shop_id) or public.works_at_shop(p.shop_id) or public.is_site_admin())));

alter table public.ledger_entries add column if not exists completed_by_name text;
alter table public.ledger_entries add column if not exists completed_by_role text;
alter table public.ledger_entries drop constraint if exists ledger_entries_entry_type_check;
alter table public.ledger_entries add constraint ledger_entries_entry_type_check check(entry_type in ('pos_sale','customer_payment','platform_fee','courier_fee','refund'));

create or replace function public.stamp_ledger_actor()
returns trigger language plpgsql security definer set search_path=public,auth as $$
declare actor_name text; actor_role text;
begin
  new.posted_by=coalesce(new.posted_by,auth.uid());
  if new.posted_by is not null then
    select coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'),''),nullif(trim(u.raw_user_meta_data->>'name'),''),split_part(u.email,'@',1)),r.role::text
    into actor_name,actor_role from auth.users u left join public.account_roles r on r.user_id=u.id where u.id=new.posted_by;
  end if;
  new.completed_by_name=coalesce(new.completed_by_name,actor_name,'Customer self-service');
  new.completed_by_role=coalesce(new.completed_by_role,actor_role,'customer');
  return new;
end $$;
drop trigger if exists ledger_actor_stamp on public.ledger_entries;
create trigger ledger_actor_stamp before insert on public.ledger_entries for each row execute function public.stamp_ledger_actor();

update public.ledger_entries l set
  completed_by_name=coalesce(l.completed_by_name,(select coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'),''),nullif(trim(u.raw_user_meta_data->>'name'),''),split_part(u.email,'@',1)) from auth.users u where u.id=l.posted_by),'Customer self-service'),
  completed_by_role=coalesce(l.completed_by_role,(select r.role::text from public.account_roles r where r.user_id=l.posted_by),'customer')
where l.completed_by_name is null or l.completed_by_role is null;

create or replace function public.create_offline_sale(client_event_uuid uuid,target_shop uuid,cart_items jsonb,payment_method text,sale_total numeric,sold_at timestamptz,source_device text)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  new_sale uuid; item jsonb; product_row public.products;
  package_qty numeric; base_qty numeric; selling_price numeric;
  selected_unit text; selected_case_size integer; computed_total numeric:=0; shop_sales_mode text;
  debit_name text;
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
      selected_case_size=product_row.case_size; base_qty=package_qty*selected_case_size; selling_price=coalesce(product_row.case_price,round(product_row.price*selected_case_size,2));
    else
      selected_case_size=1; base_qty=package_qty; selling_price=product_row.price;
    end if;
    if product_row.quantity<base_qty then raise exception 'Insufficient base-unit stock for %',product_row.sku; end if;
    computed_total=computed_total+round(package_qty*selling_price,2);
    insert into public.sale_items(sale_id,product_id,sku,quantity,unit_price,sale_unit,package_quantity,base_quantity)
    values(new_sale,product_row.id,product_row.sku,package_qty,selling_price,selected_unit,package_qty,base_qty);
    update public.products set quantity=quantity-base_qty,updated_at=now() where id=product_row.id;
  end loop;

  if abs(computed_total-sale_total)>0.01 then raise exception 'Sale total does not match authoritative package pricing'; end if;
  update public.sales set total=computed_total where id=new_sale;
  debit_name=case payment_method when 'cash' then 'cash_on_hand' when 'ecocash' then 'mobile_money' when 'card' then 'card_clearing' else 'bank_clearing' end;
  insert into public.ledger_entries(shop_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by)
  values(target_shop,new_sale,'pos_sale',debit_name,'sales_revenue',computed_total,'Register sale completed',auth.uid());
  update public.client_action_receipts set entity_id=new_sale::text where client_event_id=client_event_uuid;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata)
  values(auth.uid(),'sale.created','sale',new_sale::text,target_shop,jsonb_build_object('total',computed_total,'payment_method',payment_method,'supports_case_units',true,'ledger_posted',true));
  return new_sale;
end $$;

revoke execute on function public.create_offline_sale(uuid,uuid,jsonb,text,numeric,timestamptz,text) from public,anon;
grant execute on function public.create_offline_sale(uuid,uuid,jsonb,text,numeric,timestamptz,text) to authenticated;
revoke execute on function public.stamp_ledger_actor() from public,anon,authenticated;

comment on table public.lpg_shop_settings is 'LP Gas licence, safety and service capabilities for an approved LPG shop.';
comment on table public.lpg_product_details is 'Cylinder size, refill/exchange type, deposit and filled/empty cylinder controls.';
comment on column public.ledger_entries.completed_by_name is 'Snapshot of the authenticated owner or worker name that completed the posting.';
comment on column public.ledger_entries.completed_by_role is 'Snapshot of the non-overlapping platform role at posting time.';
