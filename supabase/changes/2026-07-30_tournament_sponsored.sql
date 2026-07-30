-- ============================================================================
-- 2026-07-30 — "Sponsored" tournaments
--
-- Organizer/admin can mark an event as sponsored when creating/editing it; the
-- player tournament card then shows a gold "SPONSORED" ribbon. Just a flag on
-- the tournament row — no new tables or logic.
--
-- Safe to re-run.
-- ============================================================================

alter table public.tournaments add column if not exists sponsored boolean not null default false;
