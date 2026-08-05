-- ============================================================================
-- MONEY IN, RECORDED BY HAND  (2026-08-06, follow-up)
--
-- The expenses ledger covers money spent outside the app. This is the other
-- half: money TAKEN outside the app, which the database has no other way of
-- knowing about —
--
--   • a racket sold in person, cash, never through the store
--   • a coaching session or a court let out for the afternoon
--   • sponsorship or a partnership payment
--   • an entry fee collected at the venue instead of through registration
--
-- Without this, every offline pound made the platform look less profitable
-- than it is: the materials were recorded, the sale they paid for was not.
--
-- It feeds the SAME P&L as store sales, entry fees and repairs (money in), so
-- the weekly report and the profit line pick it up with no further work.
--
-- Requires 2026-08-06_expenses_and_pl.sql. Safe to re-run.
-- ============================================================================

create table if not exists public.income (
  id            uuid primary key default gen_random_uuid(),
  received_on   date not null default current_date,
  category      text not null default 'other',
  amount        numeric(12,2) not null default 0,
  payer         text,
  note          text,
  tournament_id uuid references public.tournaments(id) on delete set null,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Drift guards, in case an earlier draft created the table.
alter table public.income add column if not exists received_on   date not null default current_date;
alter table public.income add column if not exists category      text not null default 'other';
alter table public.income add column if not exists amount        numeric(12,2) not null default 0;
alter table public.income add column if not exists payer         text;
alter table public.income add column if not exists note          text;
alter table public.income add column if not exists tournament_id uuid references public.tournaments(id) on delete set null;
alter table public.income add column if not exists created_by    uuid references public.profiles(id);
alter table public.income add column if not exists created_at    timestamptz not null default now();
alter table public.income add column if not exists updated_at    timestamptz not null default now();

-- Mirrors kIncomeCategories in lib/admin/data/finance_model.dart — change both.
alter table public.income drop constraint if exists income_category_chk;
alter table public.income add constraint income_category_chk check (
  category in ('cash_sale','coaching','court_hire','sponsorship','event','other'));

alter table public.income drop constraint if exists income_amount_chk;
alter table public.income add constraint income_amount_chk check (amount >= 0);

create index if not exists income_received_on_idx on public.income (received_on desc);
create index if not exists income_category_idx    on public.income (category);

comment on table public.income is
  'Money taken outside the app — cash sales, coaching, court hire, sponsorship. '
  'Store orders, entry fees and repairs are counted from their own ledgers.';

-- ── Shared stamp trigger for both hand-kept ledgers ─────────────────────────
create or replace function public.ledger_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_income_touch on public.income;
create trigger trg_income_touch before insert or update on public.income
  for each row execute function public.ledger_touch();

-- Re-point expenses at the shared function (expenses_touch stays defined, so
-- an older trigger still works if this file is run out of order).
drop trigger if exists trg_expenses_touch on public.expenses;
create trigger trg_expenses_touch before insert or update on public.expenses
  for each row execute function public.ledger_touch();

-- ── Same eyes as the rest of the finances ───────────────────────────────────
alter table public.income enable row level security;
drop policy if exists "income: finance read" on public.income;
create policy "income: finance read" on public.income
  for select using (public._can_see_finance());
drop policy if exists "income: admin write" on public.income;
create policy "income: admin write" on public.income
  for all using (public._is_admin()) with check (public._is_admin());
grant select, insert, update, delete on public.income to authenticated;

-- ============================================================================
-- Fold it into the P&L. Identical to the version in
-- 2026-08-06_expenses_and_pl.sql apart from the `manual` money-in line, which
-- is added to the money-in total and reported separately so the breakdown can
-- name it.
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

  -- Trade-ins: credit handed to a player for their racket.
  select coalesce(sum(coalesce(t.offer_credit, 0)), 0), count(*)
    into v_trade, v_trade_n
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

  v_in     := v_store + v_entries + v_repairs + v_manual;
  v_out    := v_cogs + v_trade + v_exp;
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
      'by_category',     v_incats,
      'total',           v_in),
    'out', json_build_object(
      'cogs',        v_cogs,
      'trade_in',    v_trade,
      'expenses',    v_exp,
      'by_category', v_cats,
      'total',       v_out),
    'profit', v_profit,
    'margin', case when v_in = 0 then 0
                   else round(100.0 * v_profit / v_in, 1) end,
    'counts', json_build_object(
      'orders',   v_orders,
      'entries',  v_entry_n,
      'repairs',  v_repair_n,
      'manual',   v_manual_n,
      'trade_in', v_trade_n,
      'expenses', v_exp_n)
  );
end $$;
-- Raw numbers, no guard of its own — only the guarded wrappers may reach it.
revoke all on function public._finance_core(date, date) from public;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- `in` should now carry a `manual` line alongside store / entries / repairs.
select public.admin_finance_summary() as all_time;
