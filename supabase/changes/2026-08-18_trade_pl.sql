-- ============================================================================
-- A TRADE-IN SWAP NOW MOVES THE P&L BY ITSELF  (2026-08-18)
--
-- A swap has three prices, and until now the P&L only knew one of them:
--
--   offer_credit — what we paid for the USED racket (credit handed over)
--   given_cost   — what the NEW racket cost US
--   given_price  — what we SOLD the new racket for
--
--   deal profit  = given_price - given_cost - offer_credit
--
-- offer_credit has been money OUT since 2026-08-06. The other two were recorded
-- on the trade and read by nothing, so a swap always looked like a pure loss in
-- Reports: the credit went out, the sale never came in.
--
-- This adds the missing two sides:
--   in.trade_sales  += given_price   (accepted / completed trades)
--   out.trade_cost  += given_cost    (accepted / completed trades)
--
-- and leaves out.trade_in (offer_credit) exactly as it was, so the arithmetic
-- above falls out of the P&L on its own.
--
-- ── THIS REVERSES THE 2026-08-10 DECISION, DELIBERATELY ─────────────────────
-- changes/2026-08-10_trade_deal_money.sql chose NOT to wire these up, because
-- the documented way to make a swap hit the books was to ring the outgoing
-- racket up as an ORDER — which books the sale (orders.total) and its cost
-- (product_costs.cost) automatically. Doing both would count the same racket
-- twice.
--
-- That route is now RETIRED for swaps. As of this file:
--
--   *** A racket handed over in a trade-in is recorded ON THE TRADE-IN, and
--       must NOT also be rung up as a store order. ***
--
-- The console says so in the trade sheet, and CLAUDE.md's "Money / Reports"
-- notes carry the rule. Only rows where given_price / given_cost are actually
-- filled in contribute, so a trade-in that is just a purchase (racket in,
-- credit out, nothing handed back) is unaffected and still books credit only.
--
-- BEFORE RUNNING: if any swap between 2026-08-10 and today was ALSO rung up as
-- an order, cancel that order or blank the trade's given_price/given_cost —
-- otherwise that one racket is counted twice from here on. The verify block at
-- the bottom lists the trades that now carry money, newest first, so they can
-- be checked against the orders list.
--
-- Requires 2026-08-06_manual_income.sql (the _finance_core this supersedes) and
-- 2026-08-10_trade_deal_money.sql (the columns). Safe to re-run.
-- ============================================================================

-- The columns already exist; this only corrects the comment that told the next
-- reader the P&L ignores them.
comment on column public.trade_requests.given_price is
  'What we sold the racket handed over in the swap for. Money IN on the P&L '
  '(accepted/completed only). Do NOT also ring the racket up as an order.';
comment on column public.trade_requests.given_cost is
  'What the racket handed over in the swap cost us. Money OUT on the P&L '
  '(accepted/completed only).';
comment on column public.trade_requests.paid_amount is
  'Cash the player actually handed over. A record of the transaction only — '
  'the P&L reads given_price and offer_credit, never this, so a part payment '
  'or a haggled number cannot quietly change the platform profit.';

-- ============================================================================
-- _finance_core — identical to the 2026-08-06_manual_income version except for
-- the two trade lines. Everything else is byte-for-byte the same on purpose:
-- this function is the single definition of the platform's profit, and the
-- weekly emailed report reads the very same one.
-- ============================================================================
create or replace function public._finance_core(p_from date, p_to date)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_a timestamptz := (p_from::timestamp) at time zone 'Africa/Cairo';
  v_b timestamptz := (p_to::timestamp)   at time zone 'Africa/Cairo';
  v_store numeric := 0; v_collected numeric := 0; v_orders int := 0;
  v_cogs numeric := 0;
  v_entries numeric := 0; v_entry_n int := 0;
  v_repairs numeric := 0; v_repair_n int := 0;
  v_manual numeric := 0;  v_manual_n int := 0;
  v_trade numeric := 0;   v_trade_n int := 0;
  v_tsales numeric := 0;  v_tcost numeric := 0; v_deal_n int := 0;
  v_exp numeric := 0;     v_exp_n int := 0;
  v_cats json := '[]'::json;
  v_incats json := '[]'::json;
  v_in numeric; v_out numeric; v_profit numeric;
begin
  -- Store sales. `delivered` is the subset actually banked; the rest is booked
  -- but still in flight (cash on delivery collects at the door).
  select coalesce(sum(o.total), 0),
         coalesce(sum(o.total) filter (where o.status = 'delivered'), 0),
         count(*)
    into v_store, v_collected, v_orders
    from public.orders o
   where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
     and o.created_at >= v_a and o.created_at < v_b;

  -- Cost of the goods in those same orders (unpriced products cost 0).
  with li as (
    select coalesce((it->>'qty')::int, 0)        as qty,
           nullif(it->>'product_id', '')::uuid   as pid
      from public.orders o,
           lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) it
     where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
       and o.created_at >= v_a and o.created_at < v_b
  )
  select coalesce(sum(li.qty * coalesce(pc.cost, 0)), 0)
    into v_cogs
    from li
    left join public.product_costs pc on pc.product_id = li.pid;

  -- Tournament entry fees, verified and not refunded.
  select coalesce(sum(coalesce(te.paid_amount, 0)), 0), count(*)
    into v_entries, v_entry_n
    from public.tournament_entries te
   where te.status = 'paid'
     and coalesce(te.refund_status, 'none') <> 'refunded'
     and te.created_at >= v_a and te.created_at < v_b;

  -- Repairs: charged when the player collects the racket.
  select coalesce(sum(coalesce(r.quote_amount, 0)), 0), count(*)
    into v_repairs, v_repair_n
    from public.repair_requests r
   where r.status = 'collected'
     and coalesce(r.updated_at, r.created_at) >= v_a
     and coalesce(r.updated_at, r.created_at) <  v_b;

  -- Money taken outside the app, recorded by hand.
  select coalesce(sum(i.amount), 0), count(*)
    into v_manual, v_manual_n
    from public.income i
   where i.received_on >= p_from and i.received_on < p_to;

  select coalesce(json_agg(y order by y.amount desc), '[]'::json)
    into v_incats
    from (select i.category,
                 sum(i.amount)::numeric as amount,
                 count(*)::int          as n
            from public.income i
           where i.received_on >= p_from and i.received_on < p_to
           group by i.category) y;

  -- Trade-ins: credit handed to a player for their racket. This is what we
  -- paid for the USED racket, and it has been money out since 2026-08-06.
  select coalesce(sum(coalesce(t.offer_credit, 0)), 0), count(*)
    into v_trade, v_trade_n
    from public.trade_requests t
   where t.status in ('accepted', 'completed')
     and t.created_at >= v_a and t.created_at < v_b;

  -- The other half of the same swap: the racket we handed BACK. Sold for
  -- given_price, cost us given_cost. Counted only where the figure was
  -- actually recorded — coalesce(...,0) would make an unfilled trade look
  -- like a giveaway rather than an unknown, and `sum` skips nulls anyway.
  -- v_deal_n counts trades carrying either figure, so the console can say how
  -- many swaps are behind the line.
  select coalesce(sum(t.given_price), 0),
         coalesce(sum(t.given_cost), 0),
         count(*) filter (where t.given_price is not null
                             or t.given_cost is not null)
    into v_tsales, v_tcost, v_deal_n
    from public.trade_requests t
   where t.status in ('accepted', 'completed')
     and t.created_at >= v_a and t.created_at < v_b;

  -- Hand-recorded expenses, and the same money split by category.
  select coalesce(sum(e.amount), 0), count(*)
    into v_exp, v_exp_n
    from public.expenses e
   where e.spent_on >= p_from and e.spent_on < p_to;

  select coalesce(json_agg(x order by x.amount desc), '[]'::json)
    into v_cats
    from (select e.category,
                 sum(e.amount)::numeric as amount,
                 count(*)::int          as n
            from public.expenses e
           where e.spent_on >= p_from and e.spent_on < p_to
           group by e.category) x;

  v_in     := v_store + v_entries + v_repairs + v_manual + v_tsales;
  v_out    := v_cogs + v_trade + v_tcost + v_exp;
  v_profit := v_in - v_out;

  return json_build_object(
    'from', p_from,
    'to',   p_to - 1,                       -- inclusive last day, for display
    'in', json_build_object(
      'store',           v_store,
      'store_collected', v_collected,
      'entries',         v_entries,
      'repairs',         v_repairs,
      'manual',          v_manual,
      'trade_sales',     v_tsales,
      'by_category',     v_incats,
      'total',           v_in),
    'out', json_build_object(
      'cogs',        v_cogs,
      'trade_in',    v_trade,
      'trade_cost',  v_tcost,
      'expenses',    v_exp,
      'by_category', v_cats,
      'total',       v_out),
    'profit', v_profit,
    'margin', case when v_in = 0 then 0
                   else round(100.0 * v_profit / v_in, 1) end,
    'counts', json_build_object(
      'orders',      v_orders,
      'entries',     v_entry_n,
      'repairs',     v_repair_n,
      'manual',      v_manual_n,
      'trade_in',    v_trade_n,
      'trade_deals', v_deal_n,
      'expenses',    v_exp_n)
  );
end $$;
-- Raw numbers, no guard of its own — only the guarded wrappers may reach it.
revoke all on function public._finance_core(date, date) from public;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- `in` should now carry a `trade_sales` line and `out` a `trade_cost` line.
--
-- NOTE: call _finance_core, NOT admin_finance_summary(), when running this by
-- hand. The wrapper checks _can_see_finance(), which reads auth.uid() — in the
-- SQL editor there is no JWT, so it returns {"error":"not_allowed"} and tells
-- you nothing about whether this file worked. The editor also shows only the
-- LAST result set, so run these two selects one at a time.
select public._finance_core(date '2000-01-01',
                            (now() at time zone 'Africa/Cairo')::date + 1)
       as all_time;

-- Every swap that now moves the P&L, newest first. Check these against the
-- store orders list: if one of these rackets was ALSO rung up as an order, it
-- is being counted twice — cancel the order, or blank the two figures here.
select t.created_at::date as on_day,
       coalesce(p.name, t.player_name) as who,
       t.racket_desc,
       t.given_name,
       t.offer_credit               as we_paid_for_used,
       t.given_cost                 as new_cost_us,
       t.given_price                as new_sold_for,
       coalesce(t.given_price, 0)
         - coalesce(t.given_cost, 0)
         - coalesce(t.offer_credit, 0) as deal_profit
  from public.trade_requests t
  left join public.profiles p on p.id = t.player_id
 where t.status in ('accepted', 'completed')
   and (t.given_price is not null or t.given_cost is not null)
 order by t.created_at desc;
