-- 2026-08-10 — "Both sides" becomes a real court-side answer.
--
-- profiles_side_chk (from migrations/0002) only permitted ('left','right'), so
-- the app could not offer the third option padel players actually give. The
-- Dart enum worked around it by rewriting a stored 'both' to 'right' on read,
-- which quietly lost the answer.
--
-- This is the trap CLAUDE.md warns about: widen the live CHECK in the same
-- change as the new enum value, because `create table if not exists` blocks are
-- skipped on the live database and never re-apply a constraint.
--
-- Safe to re-run.

alter table public.profiles drop constraint if exists profiles_side_chk;
alter table public.profiles add  constraint profiles_side_chk
  check (preferred_court_side is null
         or preferred_court_side in ('left', 'right', 'both'));

-- Nothing to backfill: rows already holding 'both' were legal before 0002 and
-- are legal again now. Rows the app coerced to 'right' on READ were never
-- written back, so no data was actually changed by the old workaround.
--
-- Deliberately NOT touching profiles_hand_chk. Dominant hand stays
-- left/right — ambidextrous padel players exist but the onboarding question is
-- "which hand do you hold the racket in", which has one answer.
