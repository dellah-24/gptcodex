-- Adds idempotent offline inventory movements and Supabase Realtime updates.

create table if not exists public.product_movements (
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

create or replace function public.apply_product_movement(
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

alter table public.product_movements enable row level security;
drop policy if exists "shop team reads product movements" on public.product_movements;
create policy "shop team reads product movements" on public.product_movements for select
using(shop_id is not null and (public.owns_shop(shop_id) or public.works_at_shop(shop_id) or public.is_site_admin()));

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='products') then
    alter publication supabase_realtime add table public.products;
  end if;
end $$;
