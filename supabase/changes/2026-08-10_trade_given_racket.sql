-- 2026-08-10 — Record what we handed BACK in a trade-in.
--
-- A trade-in is a swap: a racket comes in, and usually one goes out with it.
-- Only the incoming racket was ever stored, so the console could not say what
-- the player actually walked away with.
--
-- Two columns, same shape as player_id / player_name above: link the catalogue
-- product when it is something we stock, or just write down what it was.
--
-- Safe to re-run.

alter table public.trade_requests
  add column if not exists given_product_id uuid
    references public.products(id) on delete set null,
  add column if not exists given_name text;

-- ⚠️  DELIBERATELY NOT WIRED TO THE P&L OR TO STOCK.
--
-- Filling this in records a fact; it moves no money and decrements no
-- inventory. That is on purpose, because the alternative silently double-counts:
--
--   • COGS is derived from what SOLD through `orders` (product_costs.cost × qty).
--     Making a trade-in also book COGS would charge us twice for any racket
--     that was additionally rung up as an order.
--   • Trade-in credit (offer_credit on accepted/completed rows) is ALREADY the
--     money-out side of the swap in _finance_core.
--   • products.stock is hand-managed in Store & Orders, and rackets are usually
--     made_to_order anyway, where stock is never touched by design.
--
-- If the swap should hit the books, the honest way is the existing one: ring the
-- outgoing racket up as an order (COGS follows automatically) and let the
-- trade-in credit stand as the money-out against it. Decide that before wiring
-- anything here — see the "Money / Reports" notes in CLAUDE.md.
