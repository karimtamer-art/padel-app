-- ============================================================================
-- EXPENSES: a "Materials & supplies" category  (2026-08-06, follow-up)
--
-- The expenses ledger from 2026-08-06_expenses_and_pl.sql is for money spent
-- OUTSIDE the app — cash at a shop, a bank transfer to a supplier, anything the
-- database can't see for itself. The one thing it had no home for was the most
-- common purchase of all: materials. Strings, grips, balls, packaging, glue —
-- things you buy, use up, and never sell as a product.
--
-- That is a genuine cost with nothing else counting it (a repair charges the
-- player a quote; the string it consumed was invisible), so it belongs in the
-- P&L exactly like any other expense.
--
-- Still NOT here: buying stock to resell. A racket you buy to sell already
-- reaches the P&L through the product's cost when it sells (cost of goods
-- sold). Logging the purchase here as well would count that racket twice and
-- understate profit. Set the cost on the product in Store & Orders instead.
--
-- Safe to re-run. Only this file needs running if you already ran
-- 2026-08-06_expenses_and_pl.sql.
-- ============================================================================

alter table public.expenses drop constraint if exists expenses_category_chk;
alter table public.expenses add constraint expenses_category_chk check (
  category in ('materials','court_rent','prizes','marketing','salaries',
               'shipping','software','equipment','other'));

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Should list 'materials' among the allowed values.
select pg_get_constraintdef(oid) as allowed_categories
  from pg_constraint
 where conname = 'expenses_category_chk';
