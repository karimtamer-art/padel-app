-- 2026-08-10 — The money in a trade-in swap, so the deal's profit is visible.
--
-- A swap has three amounts the console could not record:
--   given_price — the ticket price of the racket handed over
--   paid_amount — what the player actually handed over in cash, i.e. the price
--                 after their trade-in credit came off
--   given_cost  — what that racket cost US
--
-- Deal profit = paid_amount - given_cost, shown in the console.
--
-- Safe to re-run.

alter table public.trade_requests
  add column if not exists given_price numeric(10,2),
  add column if not exists paid_amount numeric(10,2),
  add column if not exists given_cost  numeric(10,2);

-- Amounts are never negative; null means "not recorded", which is different
-- from zero and must stay possible (every existing row is null).
alter table public.trade_requests drop constraint if exists trade_requests_money_chk;
alter table public.trade_requests
  add constraint trade_requests_money_chk
  check ((given_price is null or given_price >= 0)
     and (paid_amount is null or paid_amount >= 0)
     and (given_cost  is null or given_cost  >= 0));

-- ⚠️  STILL NOT WIRED INTO _finance_core. These columns are recorded and shown
-- on the trade itself; the platform P&L does not read them.
--
-- That is not an oversight, it is the double-counting boundary. Today the P&L
-- already counts offer_credit on accepted/completed trades as money OUT, and
-- derives COGS from what sold through `orders`. Feeding paid_amount in as money
-- IN and given_cost in as a cost would double-count the moment the same racket
-- is also rung up as an order — which is currently the documented way to make a
-- swap hit the books.
--
-- ASKED AND DECIDED (2026-08-10): keep these on the trade. The platform P&L
-- carries on as it is — offer_credit as money out, COGS from orders — and a
-- swap that should move platform profit gets the outgoing racket rung up as an
-- order. This is not a TODO. Reversing it means retiring the order route for
-- swaps in the same change, or the racket is counted twice.
-- See the "Money / Reports (P&L)" notes in CLAUDE.md.
