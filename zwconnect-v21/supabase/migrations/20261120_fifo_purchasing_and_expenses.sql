-- Auditable delegated purchasing, FIFO inventory costing, expenses and profit.
-- Run after 20261120_lpg_profile_and_sales_ledger.sql.

alter table public.products add column if not exists latest_purchase_price numeric(14,4) check(latest_purchase_price is null or latest_purchase_price>=0);
alter table public.products add column if not exists weighted_average_cost numeric(14,4) check(weighted_average_cost is null or weighted_average_cost>=0);
alter table public.sale_items add column if not exists cost_of_goods numeric(14,2) not null default 0 check(cost_of_goods>=0);
alter table public.sale_items add column if not exists gross_profit numeric(14,2);
alter table public.sale_items add column if not exists costing_method text not null default 'fifo';
alter table public.sale_items add column if not exists costing_status text not null default 'legacy_unallocated' check(costing_status in ('legacy_unallocated','exact','estimated'));

create table if not exists public.shop_worker_permissions (
  shop_worker_id uuid primary key references public.shop_workers(id) on delete cascade,
  shop_id uuid not null references public.shops(id) on delete cascade,
  can_purchase boolean not null default false,
  can_record_expenses boolean not null default false,
  granted_by uuid not null references auth.users(id) on delete restrict,
  granted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists shop_worker_permissions_shop_idx on public.shop_worker_permissions(shop_id);

create table if not exists public.stock_purchases (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid not null references public.shops(id) on delete restrict,
  supplier_name text not null,
  supplier_invoice text not null,
  payment_source text not null check(payment_source in ('cash','bank','mobile_money','credit')),
  total_cost numeric(14,2) not null default 0 check(total_cost>=0),
  notes text,
  purchased_by uuid not null references auth.users(id) on delete restrict,
  purchased_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  unique(shop_id,supplier_name,supplier_invoice)
);

create table if not exists public.stock_purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.stock_purchases(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  sku text not null,
  quantity numeric(14,3) not null check(quantity>0),
  unit_cost numeric(14,4) not null check(unit_cost>=0),
  line_cost numeric(14,2) generated always as (round(quantity*unit_cost,2)) stored,
  selling_price_set numeric(14,2) check(selling_price_set is null or selling_price_set>=0)
);

create table if not exists public.inventory_cost_layers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  purchase_item_id uuid references public.stock_purchase_items(id) on delete restrict,
  source text not null default 'purchase' check(source in ('purchase','opening_balance_estimate','adjustment_estimate')),
  original_quantity numeric(14,3) not null check(original_quantity>0),
  remaining_quantity numeric(14,3) not null check(remaining_quantity>=0 and remaining_quantity<=original_quantity),
  unit_cost numeric(14,4) not null check(unit_cost>=0),
  received_at timestamptz not null,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists inventory_cost_layers_fifo_idx on public.inventory_cost_layers(product_id,received_at,id) where remaining_quantity>0;

create table if not exists public.sale_cost_allocations (
  id bigint generated always as identity primary key,
  sale_item_id bigint not null references public.sale_items(id) on delete cascade,
  cost_layer_id uuid not null references public.inventory_cost_layers(id) on delete restrict,
  quantity numeric(14,3) not null check(quantity>0),
  unit_cost numeric(14,4) not null check(unit_cost>=0),
  total_cost numeric(14,2) generated always as (round(quantity*unit_cost,2)) stored,
  allocated_at timestamptz not null default now(),
  unique(sale_item_id,cost_layer_id)
);

create table if not exists public.purchase_expenses (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  shop_id uuid not null references public.shops(id) on delete restrict,
  category text not null check(category in ('transport','fuel','loading','packaging','communication','other')),
  amount numeric(14,2) not null check(amount>0),
  description text not null,
  payment_source text not null check(payment_source in ('cash','bank','mobile_money')),
  expense_date date not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  recorded_at timestamptz not null default now()
);

alter table public.ledger_entries drop constraint if exists ledger_entries_entry_type_check;
alter table public.ledger_entries add constraint ledger_entries_entry_type_check check(entry_type in ('pos_sale','customer_payment','platform_fee','courier_fee','refund','stock_purchase','operating_expense','cost_of_goods'));

insert into public.inventory_cost_layers(shop_id,product_id,source,original_quantity,remaining_quantity,unit_cost,received_at)
select p.shop_id,p.id,'opening_balance_estimate',p.quantity,p.quantity,p.price,coalesce(p.updated_at,now())
from public.products p
where p.quantity>0 and not exists(select 1 from public.inventory_cost_layers l where l.product_id=p.id);
update public.products p set latest_purchase_price=coalesce(latest_purchase_price,price),weighted_average_cost=coalesce(weighted_average_cost,price);

create or replace function public.can_purchase_for_shop(target_shop uuid,for_expense boolean default false)
returns boolean language sql stable security definer set search_path=public as $$
  select public.owns_shop(target_shop) or exists(
    select 1 from public.shop_workers w join public.shop_worker_permissions p on p.shop_worker_id=w.id
    where w.shop_id=target_shop and w.user_id=auth.uid() and w.active
      and case when for_expense then p.can_record_expenses else p.can_purchase end
  )
$$;

create or replace function public.set_worker_purchasing_permission(target_shop uuid,target_worker_user uuid,worker_email text,allow_purchases boolean,allow_expenses boolean)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare worker_row public.shop_workers; resolved_user uuid;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner may grant purchasing privileges'; end if;
  resolved_user=target_worker_user;
  if resolved_user is null and nullif(lower(trim(worker_email)),'') is not null then select id into resolved_user from auth.users where lower(email)=lower(trim(worker_email)); end if;
  select * into worker_row from public.shop_workers where shop_id=target_shop and user_id=resolved_user and active;
  if not found then raise exception 'Active worker account not found for this shop'; end if;
  insert into public.shop_worker_permissions(shop_worker_id,shop_id,can_purchase,can_record_expenses,granted_by)
  values(worker_row.id,target_shop,allow_purchases,allow_expenses,auth.uid())
  on conflict(shop_worker_id) do update set can_purchase=excluded.can_purchase,can_record_expenses=excluded.can_record_expenses,granted_by=auth.uid(),granted_at=now(),updated_at=now();
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata)
  values(auth.uid(),'purchasing_permission.updated','shop_worker',worker_row.id::text,target_shop,jsonb_build_object('can_purchase',allow_purchases,'can_record_expenses',allow_expenses));
  return worker_row.id;
end $$;

create or replace function public.record_stock_purchase(client_event_uuid uuid,target_shop uuid,supplier_name text,supplier_invoice text,payment_source text,purchased_at timestamptz,purchase_notes text,purchase_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare purchase_uuid uuid; item jsonb; product_row public.products; purchase_item_uuid uuid; qty numeric; cost numeric; new_price numeric; computed_total numeric:=0; debit_account text;
begin
  select id into purchase_uuid from public.stock_purchases where client_event_id=client_event_uuid; if found then return purchase_uuid; end if;
  if not public.can_purchase_for_shop(target_shop,false) then raise exception 'Purchasing privilege required'; end if;
  if payment_source not in ('cash','bank','mobile_money','credit') then raise exception 'Invalid purchase payment source'; end if;
  if jsonb_typeof(purchase_items)<>'array' or jsonb_array_length(purchase_items)=0 then raise exception 'Purchase requires at least one product'; end if;
  if nullif(trim(supplier_name),'') is null or nullif(trim(supplier_invoice),'') is null then raise exception 'Supplier and invoice are required'; end if;
  perform public.claim_client_action(client_event_uuid,'stock_purchase.record',target_shop);
  insert into public.stock_purchases(client_event_id,shop_id,supplier_name,supplier_invoice,payment_source,notes,purchased_by,purchased_at)
  values(client_event_uuid,target_shop,trim(supplier_name),trim(supplier_invoice),payment_source,nullif(trim(purchase_notes),''),auth.uid(),purchased_at) returning id into purchase_uuid;
  for item in select * from jsonb_array_elements(purchase_items) loop
    qty=(item->>'quantity')::numeric; cost=(item->>'unit_cost')::numeric; new_price=nullif(item->>'selling_price','')::numeric;
    if qty<=0 or cost<0 then raise exception 'Purchase quantity and unit cost are invalid'; end if;
    select * into product_row from public.products where shop_id=target_shop and sku=item->>'sku' for update;
    if not found then raise exception 'Product % not found',item->>'sku'; end if;
    insert into public.stock_purchase_items(purchase_id,product_id,sku,quantity,unit_cost,selling_price_set)
    values(purchase_uuid,product_row.id,product_row.sku,qty,cost,new_price) returning id into purchase_item_uuid;
    insert into public.inventory_cost_layers(shop_id,product_id,purchase_item_id,source,original_quantity,remaining_quantity,unit_cost,received_at,created_by)
    values(target_shop,product_row.id,purchase_item_uuid,'purchase',qty,qty,cost,purchased_at,auth.uid());
    update public.products set quantity=quantity+qty,latest_purchase_price=cost,price=coalesce(new_price,price),updated_at=now() where id=product_row.id;
    update public.products p set weighted_average_cost=(select round(sum(l.remaining_quantity*l.unit_cost)/nullif(sum(l.remaining_quantity),0),4) from public.inventory_cost_layers l where l.product_id=p.id and l.remaining_quantity>0) where p.id=product_row.id;
    insert into public.product_movements(client_event_id,shop_id,product_id,quantity_delta,reason,device_id,created_by,occurred_at)
    values(gen_random_uuid(),target_shop,product_row.id,qty,'restock','purchase-'||purchase_uuid::text,auth.uid(),purchased_at);
    computed_total=computed_total+round(qty*cost,2);
  end loop;
  update public.stock_purchases set total_cost=computed_total where id=purchase_uuid;
  debit_account=case payment_source when 'credit' then 'accounts_payable' else case payment_source when 'cash' then 'cash_on_hand' when 'bank' then 'bank' else 'mobile_money' end end;
  insert into public.ledger_entries(shop_id,entry_type,debit_account,credit_account,amount,memo,posted_by)
  values(target_shop,'stock_purchase','inventory_asset',debit_account,computed_total,'Stock purchase • '||trim(supplier_name)||' • '||trim(supplier_invoice),auth.uid());
  update public.client_action_receipts set entity_id=purchase_uuid::text where client_event_id=client_event_uuid;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'stock_purchase.recorded','stock_purchase',purchase_uuid::text,target_shop,jsonb_build_object('supplier',supplier_name,'invoice',supplier_invoice,'total',computed_total));
  return purchase_uuid;
end $$;

create or replace function public.record_purchase_expense(client_event_uuid uuid,target_shop uuid,expense_category text,expense_amount numeric,expense_description text,payment_source text,expense_date date)
returns uuid language plpgsql security definer set search_path=public as $$
declare expense_uuid uuid; credit_account text;
begin
  select id into expense_uuid from public.purchase_expenses where client_event_id=client_event_uuid; if found then return expense_uuid; end if;
  if not public.can_purchase_for_shop(target_shop,true) then raise exception 'Expense-recording privilege required'; end if;
  if expense_category not in ('transport','fuel','loading','packaging','communication','other') or payment_source not in ('cash','bank','mobile_money') or expense_amount<=0 then raise exception 'Invalid expense details'; end if;
  if nullif(trim(expense_description),'') is null then raise exception 'Expense description is required'; end if;
  perform public.claim_client_action(client_event_uuid,'purchase_expense.record',target_shop);
  insert into public.purchase_expenses(client_event_id,shop_id,category,amount,description,payment_source,expense_date,recorded_by)
  values(client_event_uuid,target_shop,expense_category,expense_amount,trim(expense_description),payment_source,expense_date,auth.uid()) returning id into expense_uuid;
  credit_account=case payment_source when 'cash' then 'cash_on_hand' when 'bank' then 'bank' else 'mobile_money' end;
  insert into public.ledger_entries(shop_id,entry_type,debit_account,credit_account,amount,memo,posted_by)
  values(target_shop,'operating_expense','purchasing_expense_'||expense_category,credit_account,expense_amount,trim(expense_description),auth.uid());
  update public.client_action_receipts set entity_id=expense_uuid::text where client_event_id=client_event_uuid;
  insert into public.audit_events(actor_id,action,entity_type,entity_id,shop_id,metadata) values(auth.uid(),'purchase_expense.recorded','purchase_expense',expense_uuid::text,target_shop,jsonb_build_object('category',expense_category,'amount',expense_amount));
  return expense_uuid;
end $$;

create or replace function public.allocate_sale_item_fifo()
returns trigger language plpgsql security definer set search_path=public as $$
declare required_qty numeric:=new.base_quantity; take_qty numeric; total_cogs numeric:=0; layer public.inventory_cost_layers; product_row public.products; fallback_cost numeric; fallback_layer uuid; sale_shop uuid;
begin
  select * into product_row from public.products where id=new.product_id;
  select shop_id into sale_shop from public.sales where id=new.sale_id;
  for layer in select * from public.inventory_cost_layers where product_id=new.product_id and remaining_quantity>0 order by received_at,id for update loop
    exit when required_qty<=0; take_qty=least(required_qty,layer.remaining_quantity);
    insert into public.sale_cost_allocations(sale_item_id,cost_layer_id,quantity,unit_cost) values(new.id,layer.id,take_qty,layer.unit_cost);
    update public.inventory_cost_layers set remaining_quantity=remaining_quantity-take_qty where id=layer.id;
    total_cogs=total_cogs+round(take_qty*layer.unit_cost,2); required_qty=required_qty-take_qty;
  end loop;
  if required_qty>0 then
    fallback_cost=coalesce(product_row.weighted_average_cost,product_row.latest_purchase_price,product_row.price,0);
    insert into public.inventory_cost_layers(shop_id,product_id,source,original_quantity,remaining_quantity,unit_cost,received_at,created_by)
    values(sale_shop,new.product_id,'adjustment_estimate',required_qty,required_qty,fallback_cost,now(),auth.uid()) returning id into fallback_layer;
    insert into public.sale_cost_allocations(sale_item_id,cost_layer_id,quantity,unit_cost) values(new.id,fallback_layer,required_qty,fallback_cost);
    update public.inventory_cost_layers set remaining_quantity=0 where id=fallback_layer;
    total_cogs=total_cogs+round(required_qty*fallback_cost,2);
  end if;
  update public.sale_items set cost_of_goods=total_cogs,gross_profit=round(line_total-total_cogs,2),costing_method='fifo',costing_status=case when exists(select 1 from public.sale_cost_allocations a join public.inventory_cost_layers l on l.id=a.cost_layer_id where a.sale_item_id=new.id and l.source like '%estimate') then 'estimated' else 'exact' end where id=new.id;
  insert into public.ledger_entries(shop_id,sale_id,entry_type,debit_account,credit_account,amount,memo,posted_by)
  values(sale_shop,new.sale_id,'cost_of_goods','cost_of_goods_sold','inventory_asset',total_cogs,'FIFO cost allocation • '||new.sku,auth.uid());
  return new;
end $$;
drop trigger if exists sale_item_fifo_costing on public.sale_items;
create trigger sale_item_fifo_costing after insert on public.sale_items for each row execute function public.allocate_sale_item_fifo();

create or replace function public.get_shop_profit_summary(target_shop uuid,period_start timestamptz default null,period_end timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare revenue numeric; cogs numeric; expenses numeric; estimated_count integer;
begin
  if not public.owns_shop(target_shop) then raise exception 'Only the shop owner may view profit analysis'; end if;
  select coalesce(sum(si.line_total),0),coalesce(sum(si.cost_of_goods),0),count(*) filter(where si.costing_status<>'exact') into revenue,cogs,estimated_count
  from public.sale_items si join public.sales s on s.id=si.sale_id where s.shop_id=target_shop and (period_start is null or s.sold_at>=period_start) and (period_end is null or s.sold_at<period_end);
  select coalesce(sum(amount),0) into expenses from public.purchase_expenses where shop_id=target_shop and (period_start is null or expense_date>=period_start::date) and (period_end is null or expense_date<period_end::date);
  return jsonb_build_object('revenue',revenue,'cogs',cogs,'gross_profit',revenue-cogs,'expenses',expenses,'net_profit',revenue-cogs-expenses,'estimated_sale_items',estimated_count,'costing_method','FIFO');
end $$;

alter table public.shop_worker_permissions enable row level security;
alter table public.stock_purchases enable row level security;
alter table public.stock_purchase_items enable row level security;
alter table public.inventory_cost_layers enable row level security;
alter table public.sale_cost_allocations enable row level security;
alter table public.purchase_expenses enable row level security;
create policy "owner and worker read own purchasing permission" on public.shop_worker_permissions for select using(public.owns_shop(shop_id) or exists(select 1 from public.shop_workers w where w.id=shop_worker_id and w.user_id=auth.uid()));
create policy "authorised team reads purchases" on public.stock_purchases for select using(public.owns_shop(shop_id) or public.can_purchase_for_shop(shop_id,false));
create policy "authorised team reads purchase items" on public.stock_purchase_items for select using(exists(select 1 from public.stock_purchases p where p.id=purchase_id and (public.owns_shop(p.shop_id) or public.can_purchase_for_shop(p.shop_id,false))));
create policy "owner reads cost layers" on public.inventory_cost_layers for select using(public.owns_shop(shop_id));
create policy "owner reads cost allocations" on public.sale_cost_allocations for select using(exists(select 1 from public.sale_items si join public.sales s on s.id=si.sale_id where si.id=sale_item_id and public.owns_shop(s.shop_id)));
create policy "authorised team reads expenses" on public.purchase_expenses for select using(public.owns_shop(shop_id) or public.can_purchase_for_shop(shop_id,true));

revoke execute on function public.can_purchase_for_shop(uuid,boolean) from public,anon;
revoke execute on function public.set_worker_purchasing_permission(uuid,uuid,text,boolean,boolean) from public,anon;
revoke execute on function public.record_stock_purchase(uuid,uuid,text,text,text,timestamptz,text,jsonb) from public,anon;
revoke execute on function public.record_purchase_expense(uuid,uuid,text,numeric,text,text,date) from public,anon;
revoke execute on function public.get_shop_profit_summary(uuid,timestamptz,timestamptz) from public,anon;
revoke execute on function public.allocate_sale_item_fifo() from public,anon,authenticated;
grant execute on function public.can_purchase_for_shop(uuid,boolean) to authenticated;
grant execute on function public.set_worker_purchasing_permission(uuid,uuid,text,boolean,boolean) to authenticated;
grant execute on function public.record_stock_purchase(uuid,uuid,text,text,text,timestamptz,text,jsonb) to authenticated;
grant execute on function public.record_purchase_expense(uuid,uuid,text,numeric,text,text,date) to authenticated;
grant execute on function public.get_shop_profit_summary(uuid,timestamptz,timestamptz) to authenticated;

comment on table public.inventory_cost_layers is 'FIFO inventory layers preserve every purchase price and remaining quantity.';
comment on table public.sale_cost_allocations is 'Exact FIFO layer quantities consumed by each sale item.';
comment on table public.shop_worker_permissions is 'Shop-scoped capabilities; does not alter the worker non-overlapping platform role.';
