-- ============================================================================
-- USED RACKETS  (2026-08-18)
--
-- A second-hand racket you buy and later sell on. One row per RACKET, not per
-- transaction, so both halves of its life sit on the same line:
--
--   buy_price   what you bought it for      → money OUT on bought_on
--   sell_price  what you sold it for        → money IN  on sold_on
--   profit      sell_price - buy_price      (per racket, and in Reports)
--
-- A racket with no sold_on is still on the shelf: its cost is booked, its sale
-- is not, and the console calls that "money on the shelf". Nothing is estimated
-- and nothing is depreciated — a racket you never sell simply stays a cost.
--
-- ── NOT THE SAME THING AS A TRADE-IN ────────────────────────────────────────
-- `trade_requests` is a SWAP: their old racket comes in, one of ours goes out,
-- and all three of its prices already reach the P&L (changes/2026-08-18_
-- trade_pl.sql). This table is the plain resale: buy a used racket, sell it on.
--
-- They meet in one place, and it is the double-count to watch. A racket taken
-- in on a trade-in has ALREADY had its acquisition booked as trade-in credit
-- (`out.trade_in`). Listing that same racket here with a buy price would charge
-- you for it twice. So `source` decides:
--
--   'bought'   — bought outright. buy_price IS money out.        (the default)
--   'trade_in' — came in on a trade-in. buy_price is recorded so you can still
--                see the racket's real margin, but it is NOT money out again;
--                the credit already was. Its SALE still counts as money in.
--
-- That is the whole rule, and it is enforced in _finance_core below, not in
-- Dart. The console explains it in the source selector.
--
-- Adds a grantable console section id 'used_rackets', so `_role_default` and
-- kSections in lib/admin/data/roles_model.dart move together.
--
-- ⚠️  ORDERING: this file redefines _finance_core INCLUDING the trade-in lines
-- from 2026-08-18_trade_pl.sql. Run that one first if you have not, or run this
-- one alone — either way you end up correct. What you must NOT do is run
-- trade_pl AFTER this file: it would replace the function with a version that
-- has no used-racket lines, and the section would silently stop reaching the
-- P&L.
--
-- Requires 2026-08-06_manual_income.sql. Safe to re-run.
-- ============================================================================

create table if not exists public.used_rackets (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  brand        text,
  condition    text,
  -- Where it came from, and what it cost. See the source note above.
  source       text not null default 'bought',
  bought_on    date not null default current_date,
  buy_price    numeric(10,2),
  bought_from  text,
  -- The sale. Null sold_on means it is still on the shelf.
  sold_on      date,
  sell_price   numeric(10,2),
  sold_to      text,
  note         text,
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Drift guards, in case an earlier draft created the table: `create table if
-- not exists` above would have been a no-op and none of these would exist.
alter table public.used_rackets add column if not exists name        text;
alter table public.used_rackets add column if not exists brand       text;
alter table public.used_rackets add column if not exists condition   text;
alter table public.used_rackets add column if not exists source      text not null default 'bought';
alter table public.used_rackets add column if not exists bought_on   date not null default current_date;
alter table public.used_rackets add column if not exists buy_price   numeric(10,2);
alter table public.used_rackets add column if not exists bought_from text;
alter table public.used_rackets add column if not exists sold_on     date;
alter table public.used_rackets add column if not exists sell_price  numeric(10,2);
alter table public.used_rackets add column if not exists sold_to     text;
alter table public.used_rackets add column if not exists note        text;
alter table public.used_rackets add column if not exists created_by  uuid references public.profiles(id);
alter table public.used_rackets add column if not exists created_at  timestamptz not null default now();
alter table public.used_rackets add column if not exists updated_at  timestamptz not null default now();

-- Mirrors kUsedSources in lib/admin/screens/admin_used_rackets_screen.dart.
alter table public.used_rackets drop constraint if exists used_rackets_source_chk;
alter table public.used_rackets add constraint used_rackets_source_chk
  check (source in ('bought', 'trade_in'));

-- Null means "not recorded", which is different from zero and must stay
-- possible — you can log a racket before you have settled on a price.
alter table public.used_rackets drop constraint if exists used_rackets_money_chk;
alter table public.used_rackets add constraint used_rackets_money_chk
  check ((buy_price  is null or buy_price  >= 0)
     and (sell_price is null or sell_price >= 0));

-- A sale needs its date: sold_on is what puts the money in a reporting period,
-- so a sell_price without one would be money that never lands in any week.
alter table public.used_rackets drop constraint if exists used_rackets_sold_chk;
alter table public.used_rackets add constraint used_rackets_sold_chk
  check (sell_price is null or sold_on is not null);

create index if not exists used_rackets_bought_idx on public.used_rackets (bought_on desc);
create index if not exists used_rackets_sold_idx   on public.used_rackets (sold_on desc);

comment on table public.used_rackets is
  'Second-hand rackets bought to sell on. buy_price is money out on bought_on '
  '(unless source = trade_in, where the trade-in credit already booked it); '
  'sell_price is money in on sold_on.';

-- ── Same eyes as the rest of the console section ────────────────────────────
alter table public.used_rackets enable row level security;

drop policy if exists "used_rackets: staff read" on public.used_rackets;
create policy "used_rackets: staff read" on public.used_rackets for select
  using (public._has_access('used_rackets'));

drop policy if exists "used_rackets: staff write" on public.used_rackets;
create policy "used_rackets: staff write" on public.used_rackets for all
  using (public._can_edit('used_rackets'))
  with check (public._can_edit('used_rackets'));

grant select, insert, update, delete on public.used_rackets to authenticated;

-- Stamps created_by / updated_at, exactly as the two hand-kept ledgers do.
drop trigger if exists trg_used_rackets_touch on public.used_rackets;
create trigger trg_used_rackets_touch before insert or update on public.used_rackets
  for each row execute function public.ledger_touch();

-- ── The new console section ────────────────────────────────────
-- Super Admin only by default; grantable to anyone from Team & Roles.
-- MUST stay in lockstep with kRoles in lib/admin/data/roles_model.dart.
create or replace function public._role_default(p_role text)
returns text[] language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin' then array['dashboard','reports','players','matches',
                                  'tournaments','formats','courts','store',
                                  'used_rackets','promotions','sponsors',
                                  'payments','requests','broadcasts','team']
    when 'organizer'   then array['tournaments','formats','courts','broadcasts']
    when 'support'     then array['players','matches','requests']
    when 'analyst'     then array['dashboard','reports']
    else '{}'::text[] end;
$$;
grant execute on function public._role_default(text) to authenticated;

-- ============================================================================
-- _finance_core — the platform's single profit definition. This version is the
-- 2026-08-18_trade_pl one plus the two used-racket lines; everything else is
-- byte-for-byte the same on purpose.
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
  v_used_buy numeric := 0;   v_used_bought_n int := 0;
  v_used_sell numeric := 0;  v_used_sold_n int := 0;
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
  -- actually recorded — `sum` skips nulls, so an unfilled trade contributes
  -- nothing rather than reading as a giveaway.
  select coalesce(sum(t.given_price), 0),
         coalesce(sum(t.given_cost), 0),
         count(*) filter (where t.given_price is not null
                             or t.given_cost is not null)
    into v_tsales, v_tcost, v_deal_n
    from public.trade_requests t
   where t.status in ('accepted', 'completed')
     and t.created_at >= v_a and t.created_at < v_b;

  -- Used rackets bought to sell on. The cost lands on the day it was bought,
  -- whether or not it has sold yet — a racket sitting on the shelf is money
  -- spent. `source = 'trade_in'` is excluded because the trade-in credit above
  -- already booked that acquisition; counting it here too would pay for the
  -- same racket twice.
  select coalesce(sum(u.buy_price), 0), count(*)
    into v_used_buy, v_used_bought_n
    from public.used_rackets u
   where u.source = 'bought'
     and u.buy_price is not null
     and u.bought_on >= p_from and u.bought_on < p_to;

  -- The sale, on the day it sold. Counted whatever the source: a trade-in
  -- racket sold on is real money in, it is only its COST that was already
  -- accounted for.
  select coalesce(sum(u.sell_price), 0), count(*)
    into v_used_sell, v_used_sold_n
    from public.used_rackets u
   where u.sold_on is not null
     and u.sell_price is not null
     and u.sold_on >= p_from and u.sold_on < p_to;

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

  v_in     := v_store + v_entries + v_repairs + v_manual + v_tsales + v_used_sell;
  v_out    := v_cogs + v_trade + v_tcost + v_exp + v_used_buy;
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
      'used_sales',      v_used_sell,
      'by_category',     v_incats,
      'total',           v_in),
    'out', json_build_object(
      'cogs',        v_cogs,
      'trade_in',    v_trade,
      'trade_cost',  v_tcost,
      'used_buy',    v_used_buy,
      'expenses',    v_exp,
      'by_category', v_cats,
      'total',       v_out),
    'profit', v_profit,
    'margin', case when v_in = 0 then 0
                   else round(100.0 * v_profit / v_in, 1) end,
    'counts', json_build_object(
      'orders',       v_orders,
      'entries',      v_entry_n,
      'repairs',      v_repair_n,
      'manual',       v_manual_n,
      'trade_in',     v_trade_n,
      'trade_deals',  v_deal_n,
      'used_bought',  v_used_bought_n,
      'used_sold',    v_used_sold_n,
      'expenses',     v_exp_n)
  );
end $$;
-- Raw numbers, no guard of its own — only the guarded wrappers may reach it.
revoke all on function public._finance_core(date, date) from public;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Call _finance_core, NOT admin_finance_summary(): the wrapper checks
-- _can_see_finance(), which reads auth.uid() — there is no JWT in the SQL
-- editor, so it would answer {"error":"not_allowed"} and tell you nothing.
-- The editor shows only the LAST result set, so run these one at a time.
--
-- `in` should now carry `used_sales`, `out` a `used_buy`.
select public._finance_core(date '2000-01-01',
                            (now() at time zone 'Africa/Cairo')::date + 1)
       as all_time;

-- The shelf: what you own, what it cost, what it made.
select u.name,
       u.brand,
       u.source,
       u.bought_on,
       u.buy_price,
       u.sold_on,
       u.sell_price,
       case when u.sold_on is null then null
            else coalesce(u.sell_price, 0) - coalesce(u.buy_price, 0) end as profit,
       case when u.sold_on is null then 'on the shelf' else 'sold' end as state
  from public.used_rackets u
 order by u.sold_on is not null, u.bought_on desc;
