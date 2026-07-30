-- ============================================================================
-- 2026-07-30 — Remove the "Other" gender option
--
-- Gender is now male/female only. Any legacy rows with gender='other' are nulled
-- so the tightened CHECK applies cleanly. The signup trigger also drops 'other'.
--
-- Safe to re-run.
-- ============================================================================

update public.profiles set gender = null where gender = 'other';

alter table public.profiles drop constraint if exists profiles_gender_chk;
alter table public.profiles add constraint profiles_gender_chk
  check (gender is null or gender in ('male', 'female'));
