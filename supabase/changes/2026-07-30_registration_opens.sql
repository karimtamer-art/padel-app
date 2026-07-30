-- ============================================================================
-- 2026-07-30 — Registration-opens date (auto flow: upcoming → open → …)
--
-- Organizers now set a day registration opens. In the auto status flow the card
-- reads 'upcoming' (no Register button) until that day, then flips to 'open',
-- then the usual full → live → completed. Null = open immediately (legacy).
--
-- The server-side guard ("Registration hasn't opened yet") lives inside
-- register_for_tournament, delivered by 2026-07-29_split_entry_payment.sql and
-- the canonical migration. This delta just guarantees the column exists.
--
-- Safe to re-run.
-- ============================================================================

alter table public.tournaments add column if not exists registration_opens date;
