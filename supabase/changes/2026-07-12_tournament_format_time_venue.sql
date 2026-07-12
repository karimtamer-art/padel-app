-- ============================================================================
-- Tournament creation: start time + format (incl. custom) (2026-07-12).
-- Run once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- Organizers can now set a start TIME (display), pick from the existing formats
-- (knockout / double-elim / groups+knockout / round-robin) OR describe a CUSTOM
-- format. Venue is picked from the courts they've added (handled client-side;
-- venue_name still stores the chosen court's name).
-- ============================================================================

alter table public.tournaments add column if not exists start_time text;
alter table public.tournaments add column if not exists format_note text;

-- Allow the new 'custom' format alongside the existing ones.
alter table public.tournaments drop constraint if exists tournaments_format_chk;
alter table public.tournaments add constraint tournaments_format_chk
  check (format in ('knockout','round_robin','group_knockout','double_elim','custom'));

notify pgrst, 'reload schema';
