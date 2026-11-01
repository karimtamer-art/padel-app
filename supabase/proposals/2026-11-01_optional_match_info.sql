-- PROPOSAL, NOT APPLIED. Optional display fields; all nullable, nothing backfilled.
-- Re-runnable. The app already hides each of these when it is null.
--
-- These differ from the list requested, because of where the data actually lives:
--   matches.court          -> tournament_matches.court
--   matches.status 'live'  -> tournament_matches.result_status 'live'
--   venues.address         -> tournaments.venue_address
-- See the summary for why. tournaments.draw_at is as requested.

alter table public.tournament_matches add column if not exists court text;

-- result_status is free text with no CHECK (open|pending|confirmed|disputed so far),
-- so 'live' needs no constraint change. Nothing has to change for results either:
-- submit_tournament_result only refuses 'confirmed', and a submission overwrites
-- 'live' with 'pending'. Documented here so the comment in the schema stays true.
comment on column public.tournament_matches.result_status is
  'open|live|pending|confirmed|disputed';

alter table public.tournaments add column if not exists draw_at timestamptz;

-- No venues table exists: a tournament's venue is the free-text venue_name.
alter table public.tournaments add column if not exists venue_address text;
