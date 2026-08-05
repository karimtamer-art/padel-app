-- ============================================================================
-- EXPENSES + PROFIT & LOSS + WEEKLY REPORTS  (2026-08-06)
--
-- The Reports tab was five placeholder cards. This is the money behind it:
-- what we PAY, what we GET, and the profit between them — plus a Monday-to-
-- Sunday weekly report for super admins.
--
-- WHAT WE GET (money in), all already in the database:
--   • Store sales     — orders.total, cancelled/refunded excluded.
--   • Entry fees      — tournament_entries.paid_amount, status 'paid' and not
--                       refunded (a pair paying split counts once, on the row).
--   • Repairs         — repair_requests.quote_amount, status 'collected'
--                       (money changes hands at collection).
--
-- WHAT WE PAY (money out):
--   • Cost of goods   — AUTOMATIC. qty x product_costs.cost for everything sold
--     sold (COGS)       in the period. This is why there is no "stock" expense
--                       category: inventory is costed per product, and counting
--                       a stock purchase AND the COGS of the same racket would
--                       double the cost. Set the cost on the product.
--   • Trade-in credit — AUTOMATIC. trade_requests.offer_credit on accepted /
--                       completed offers — a racket bought from a player.
--   • Expenses        — MANUAL, the new table below: courts, prizes, marketing,
--                       salaries, delivery, software, equipment, other.
--
--   profit = money in - (COGS + trade-in credit + expenses)
--
-- WHO SEES IT
--   _can_see_finance() — super admins, plus an Analyst who holds Reports
--                        (the read-only role exists to see the numbers).
--                        Organizers never see platform finances, even if the
--                        Reports section is granted to them.
--   Recording/editing an expense is super-admin only (_is_admin()).
--
-- Weeks are Africa/Cairo Monday-to-Sunday, not UTC, so a Sunday-evening sale
-- lands in the week the admin thinks it did.
--
-- Safe to re-run.
-- ============================================================================

-- ── The ledger of what we pay ───────────────────────────────────────────────
create table if not exists public.expenses (
  id            uuid primary key default gen_random_uuid(),
  spent_on      date not null default current_date,
  category      text not null default 'other',
  amount        numeric(12,2) not null default 0,
  vendor        text,
  note          text,
  tournament_id uuid references public.tournaments(id) on delete set null,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Drift guards: on a live DB the create-table above is skipped entirely.
alter table public.expenses add column if not exists spent_on      date not null default current_date;
alter table public.expenses add column if not exists category      text not null default 'other';
alter table public.expenses add column if not exists amount        numeric(12,2) not null default 0;
alter table public.expenses add column if not exists vendor        text;
alter table public.expenses add column if not exists note          text;
alter table public.expenses add column if not exists tournament_id uuid references public.tournaments(id) on delete set null;
alter table public.expenses add column if not exists created_by    uuid references public.profiles(id);
alter table public.expenses add column if not exists created_at    timestamptz not null default now();
alter table public.expenses add column if not exists updated_at    timestamptz not null default now();

-- Categories mirror kExpenseCategories in lib/admin/data/finance_model.dart —
-- change both. Deliberately no 'stock': see the COGS note in the header.
alter table public.expenses drop constraint if exists expenses_category_chk;
alter table public.expenses add constraint expenses_category_chk check (
  category in ('court_rent','prizes','marketing','salaries','shipping',
               'software','equipment','other'));

alter table public.expenses drop constraint if exists expenses_amount_chk;
alter table public.expenses add constraint expenses_amount_chk check (amount >= 0);

create index if not exists expenses_spent_on_idx on public.expenses (spent_on desc);
create index if not exists expenses_category_idx on public.expenses (category);

comment on table public.expenses is
  'What the platform pays out, recorded by hand. Cost of goods sold and '
  'trade-in credit are derived from the orders/trade ledgers instead.';

-- Stamp the author + keep updated_at honest.
create or replace function public.expenses_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_expenses_touch on public.expenses;
create trigger trg_expenses_touch before insert or update on public.expenses
  for each row execute function public.expenses_touch();

-- ── Drift guard: repairs need a reliable "when did this happen" ─────────────
-- A repair counts as money in on the day the racket is COLLECTED, so the
-- weekly report reads repair_requests.updated_at. The live table came from
-- migrations/0003, where the create-table block that declares updated_at is
-- skipped — and nothing has ever kept it moving. Add the column and a touch
-- trigger so every status change stamps it. (Repairs collected before today
-- keep whatever timestamp they had; only new movement is dated accurately.)
alter table public.repair_requests
  add column if not exists updated_at timestamptz not null default now();
drop trigger if exists trg_repair_touch on public.repair_requests;
create trigger trg_repair_touch before update on public.repair_requests
  for each row execute function public.touch_updated_at();

-- ── Who may see the money ───────────────────────────────────────────────────
-- Super admin always; an Analyst holding Reports (read-only by definition) too.
-- Anyone else — an organizer handed the Reports section, say — is refused, so
-- granting a section can never leak platform-wide finances.
create or replace function public._can_see_finance()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select p.is_admin
        or (p.admin_role = 'analyst' and public._has_access('reports'))
      from public.profiles p
     where p.id = auth.uid()), false);
$$;
grant execute on function public._can_see_finance() to authenticated;

alter table public.expenses enable row level security;
drop policy if exists "expenses: finance read" on public.expenses;
create policy "expenses: finance read" on public.expenses
  for select using (public._can_see_finance());
drop policy if exists "expenses: admin write" on public.expenses;
create policy "expenses: admin write" on public.expenses
  for all using (public._is_admin()) with check (public._is_admin());
grant select, insert, update, delete on public.expenses to authenticated;

-- ============================================================================
-- The P&L engine. One core function; the summary, the weekly report and any
-- future export all go through it so the numbers can never disagree.
--
-- [p_from, p_to) — Africa/Cairo local dates, from inclusive, to exclusive.
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
  v_trade numeric := 0;   v_trade_n int := 0;
  v_exp numeric := 0;     v_exp_n int := 0;
  v_cats json := '[]'::json;
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

  v_in     := v_store + v_entries + v_repairs;
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
      'trade_in', v_trade_n,
      'expenses', v_exp_n)
  );
end $$;
-- The core has no guard of its own — it is the raw numbers. Postgres grants
-- EXECUTE to PUBLIC by default, which would let ANY signed-in player read the
-- platform's finances. Only the guarded wrappers below may reach it (they are
-- SECURITY DEFINER, so they call it as the owner).
revoke all on function public._finance_core(date, date) from public;

-- One period's full picture. Null dates = all time.
create or replace function public.admin_finance_summary(
  p_from date default null,
  p_to   date default null)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;
  return public._finance_core(
    coalesce(p_from, date '2000-01-01'),
    coalesce(p_to, ((now() at time zone 'Africa/Cairo')::date + 1)));
end $$;
grant execute on function public.admin_finance_summary(date, date) to authenticated;

-- The weekly report: the last [p_weeks] Monday-to-Sunday weeks, newest first,
-- each carrying the same breakdown as the summary above. The current week is
-- included and is partial by definition.
create or replace function public.admin_weekly_finance(p_weeks int default 8)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_n     int;
  v_this  date;
  v_first date;
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;
  v_n     := least(greatest(coalesce(p_weeks, 8), 1), 26);
  v_this  := date_trunc('week', (now() at time zone 'Africa/Cairo'))::date;
  v_first := v_this - ((v_n - 1) * 7);
  return (
    select coalesce(json_agg(w order by w.week_start desc), '[]'::json)
      from (
        select ws::date              as week_start,
               (ws + 6)::date        as week_end,
               ws::date = v_this     as is_current,
               public._finance_core(ws::date, (ws + 7)::date) as report
          from generate_series(v_first::timestamp, v_this::timestamp,
                               interval '7 day') ws
      ) w
  );
end $$;
grant execute on function public.admin_weekly_finance(int) to authenticated;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Run as a super admin. First row = this week's P&L; second = all time.
select public.admin_weekly_finance(4) as last_4_weeks;
select public.admin_finance_summary() as all_time;
