-- 2026-07-15 · One-time "placement complete" reveal gate
--
-- Home shows a one-time celebration hero the first time a player becomes placed
-- (finishes their 5 placement matches). This flag records that the reveal has
-- been shown so it fires exactly once. It is display-only — the client flips it
-- to true when the player taps "See what's next"; it never affects rating/level.
--
-- Safe to re-run (idempotent). Also folded into migration_player_app.sql.

alter table public.profiles
  add column if not exists placement_revealed boolean not null default false;

-- Backfill: anyone already placed before this shipped shouldn't get a
-- retroactive celebration — only new placements (going forward) trigger it.
update public.profiles
   set placement_revealed = true
 where coalesce(placement_played, 0) >= 5
   and placement_revealed is not true;
