-- ============================================================
-- Incremental change · 2026-06-16
-- Schema cleanup — drop pre-migration DRIFT (unused everywhere, all empty)
-- ------------------------------------------------------------
-- Audited read-only first: every item below was 100% empty (0 rows / all NULL)
-- AND unreferenced by the Dart code, RPCs, triggers, and RLS policies. So there
-- is no data loss and nothing in the app depends on them.
--
-- KEPT on purpose (scaffolding for planned features): device_tokens (push),
-- banners (promotions), audit_log. Also kept the wired-but-empty columns
-- (promo_code, instapay_proof_url, sale_price, rating, sku, slug, max_elo,
-- landmark) — those fill in once used.
--
-- Also folded into the canonical migration. Idempotent (if exists).
-- ============================================================

-- Drift tables superseded by the current design:
--   order_items -> orders.items (jsonb);  payments -> orders + manual InstaPay
drop table if exists public.order_items;
drop table if exists public.payments;

-- Drift columns on orders (shipping is stored in the `address` jsonb now).
alter table public.orders drop column if exists ship_name;
alter table public.orders drop column if exists ship_phone;
alter table public.orders drop column if exists ship_street;
alter table public.orders drop column if exists ship_building;
alter table public.orders drop column if exists ship_apartment;
alter table public.orders drop column if exists ship_area;
alter table public.orders drop column if exists ship_city;
alter table public.orders drop column if exists ship_governorate;
alter table public.orders drop column if exists ship_landmark;
alter table public.orders drop column if exists payment_ref;
alter table public.orders drop column if exists notes;

-- Other drift columns.
alter table public.tournament_entries drop column if exists payment_ref;
alter table public.tournaments        drop column if exists court_id;
alter table public.tournaments        drop column if exists created_by;
alter table public.tournaments        drop column if exists image_url;
alter table public.product_costs      drop column if exists supplier;
alter table public.profiles           drop column if exists last_active;

notify pgrst, 'reload schema';
