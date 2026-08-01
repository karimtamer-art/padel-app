-- ============================================================================
-- MADE-TO-ORDER PRODUCTS + PER-PRODUCT SALES  (2026-08-01)
--
-- Rackets aren't held in stock — they're sourced once a customer buys. Until
-- now the only way to keep one sellable was to type a huge fake stock number,
-- which made "units on hand" and "stock value" meaningless.
--
--   • products.made_to_order — the item is always sellable, stock is not
--     tracked, and the stock triggers leave it alone.
--   • admin_product_sales() — what actually matters instead: units sold,
--     revenue, cost, profit and order count per product, straight from the
--     orders ledger.
--
-- Safe to re-run.
-- ============================================================================

alter table public.products
  add column if not exists made_to_order boolean not null default false;

comment on column public.products.made_to_order is
  'Sourced per order — never out of stock, and stock is not decremented.';

-- ── stock_status: a made-to-order item is never "low" or "out" ──────────────
-- Generated columns cannot be altered in place, so drop and re-add. It is
-- derived, so nothing is lost; `get_home_products` has a string body and so
-- holds no dependency on it.
alter table public.products drop column if exists stock_status;
alter table public.products add column stock_status text
  generated always as (
    case when made_to_order then 'in'
         when stock = 0     then 'out'
         when stock <= 5    then 'low'
         else 'in' end
  ) stored;

-- ── stock movements skip made-to-order items ────────────────────────────────
create or replace function public.decrement_stock_on_order()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
    update public.products
       set stock = greatest(0, coalesce(stock, 0) - coalesce((it->>'qty')::int, 0))
     where id = nullif(it->>'product_id', '')::uuid
       and coalesce(made_to_order, false) = false;
  end loop;
  return new;
end $$;

create or replace function public.restock_on_void()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  if new.status in ('cancelled', 'refunded')
     and old.status not in ('cancelled', 'refunded') then
    for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
      update public.products
         set stock = coalesce(stock, 0) + coalesce((it->>'qty')::int, 0)
       where id = nullif(it->>'product_id', '')::uuid
         and coalesce(made_to_order, false) = false;
    end loop;
    new.voided_at := now();
    new.voided_by := auth.uid();
  end if;
  return new;
end $$;

-- ============================================================================
-- What each product has actually sold. Cancelled and refunded orders are
-- excluded entirely; `delivered_*` is the subset that has reached the customer,
-- so the console can separate money banked from money still in flight.
-- ============================================================================
create or replace function public.admin_product_sales()
returns table (
  product_id        uuid,
  units             int,
  revenue           numeric,
  delivered_units   int,
  delivered_revenue numeric,
  unit_cost         numeric,
  profit            numeric,
  order_count       int,
  last_sold_at      timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then return; end if;
  return query
    with li as (
      select o.id as order_id, o.status, o.created_at,
             nullif(it->>'product_id', '')::uuid          as pid,
             coalesce((it->>'qty')::int, 0)               as qty,
             coalesce((it->>'unit_price')::numeric, 0)    as unit_price
        from public.orders o,
             lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) it
       where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
    )
    select li.pid,
           coalesce(sum(li.qty), 0)::int,
           coalesce(sum(li.qty * li.unit_price), 0)::numeric,
           coalesce(sum(li.qty) filter (where li.status = 'delivered'), 0)::int,
           coalesce(sum(li.qty * li.unit_price)
                      filter (where li.status = 'delivered'), 0)::numeric,
           coalesce(pc.cost, 0)::numeric,
           (coalesce(sum(li.qty * li.unit_price), 0)
              - coalesce(sum(li.qty), 0) * coalesce(pc.cost, 0))::numeric,
           count(distinct li.order_id)::int,
           max(li.created_at)
      from li
      left join public.product_costs pc on pc.product_id = li.pid
     where li.pid is not null
     group by li.pid, pc.cost;
end $$;
grant execute on function public.admin_product_sales() to authenticated;

notify pgrst, 'reload schema';
