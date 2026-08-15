-- ===========================================================================
-- DEV ONLY — reset every player to a genuine V3-F5 cold start (2026-08-15)
--
-- *** THIS DESTROYS RATING DATA. IT MUST NEVER RUN AGAINST REAL USERS. ***
--
-- Deliberately NOT folded into migration_player_app.sql. That file is re-run
-- on the live project as a matter of course; a wipe living inside it would go
-- off by accident, once, silently, and there would be no way back.
--
-- WHY IT EXISTS. The test accounts carry hand-seeded state from before the
-- engine existed, and it is self-contradictory:
--
--   placement_played = 5 and placement_revealed = true, with
--   competitive_matches = 0  — impossible, both counters only ever increment
--                              together inside _settle_rating
--   tier = 'bronze' with level = 2  — tier_from_level(2.0) is 'silver', so the
--                              tier was never derived from the level
--   rating = 2.000000        — v2's prior. V3-F5's is 3.30 (rating_prior()).
--
-- Left alone, every one of those testers shows as RANKED at level 2.0 with a
-- wrong tier badge. Testing against that exercises the ranked path with
-- fabricated state and never exercises placement at all — which is the part
-- that has never run once.
--
-- AFTER THIS, a tester playing five ranked matches walks the real ladder:
--   K      1.150 -> 1.116 -> 0.847 -> 0.821 -> 0.620, then 0.293 at match 6
--   sigma  0.95 -> 0.9215 -> 0.8939 -> 0.8670 -> 0.8410 -> 0.8158 at reveal
--   the rating becomes public after match 5, still openly low-confidence
--
-- HOW TO RUN. Uncomment the single `select set_config(...)` line directly
-- below, run the whole file, then comment it back out.
--
-- It has to be IN THIS FILE rather than run as a separate query first: the
-- Supabase SQL editor pools connections, so a session setting made in one Run
-- is gone by the next — the guard would fire even though you had armed it.
-- (It did. That is why this is written the way it is.)
--
-- Uncommenting one line is still a deliberate act, which is the whole point:
-- pasting this file by mistake, or re-running it out of habit, does nothing.
-- ===========================================================================

-- ↓↓↓ UNCOMMENT THIS ONE LINE TO ARM, THEN RE-COMMENT IT AFTERWARDS ↓↓↓
-- select set_config('padel.reset_players', 'yes-wipe-all-ratings', false);
-- ↑↑↑ ------------------------------------------------------------- ↑↑↑

-- ---------------------------------------------------------------------------
-- 1. Refuse unless deliberately armed, and refuse if this looks like a real
--    userbase. Neither check can tell dev from prod with certainty, which is
--    exactly why there are two.
-- ---------------------------------------------------------------------------
do $$
declare v_players bigint; v_settled bigint;
begin
  if coalesce(current_setting('padel.reset_players', true), '')
       <> 'yes-wipe-all-ratings' then
    raise exception 'refusing to wipe ratings: this session is not armed'
      using hint = 'Uncomment the set_config line near the top of this file '
                   'and run the WHOLE file. Arming it as a separate query '
                   'does not work — the SQL editor pools connections, so the '
                   'setting is gone by the next Run.';
  end if;

  select count(*) into v_players from public.player_ratings;
  if v_players > 200 then
    raise exception '% players — that does not look like a test database', v_players
      using hint = 'If you really mean it, raise this threshold by hand and '
                   'take a backup first.';
  end if;

  select count(*) into v_settled
    from public.ranking_history where engine_version = 'v3_f5';
  if v_settled > 0 then
    raise warning '% real V3-F5 settlement(s) will be deleted', v_settled;
  end if;

  raise notice 'resetting % player(s) to a V3-F5 cold start...', v_players;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The reset.
--
--    Ratings are engine-owned and have no client grants, so this writes the
--    table directly — the same way _settle_rating does. Values match exactly
--    what a brand-new profile gets from the column defaults, so a reset player
--    is indistinguishable from one who signed up this morning.
--
--    No explicit BEGIN/COMMIT: the Supabase SQL editor may already wrap the
--    script in a transaction, and a nested begin would either warn or end its
--    transaction early at the commit. Letting the editor own the transaction
--    keeps this all-or-nothing either way.
-- ---------------------------------------------------------------------------

-- History first: none of it came from a real match, and leaving it would make
-- the next settlement's "matches before" count disagree with the counters.
delete from public.ranking_history;

update public.player_ratings set
  rating                    = null,   -- unranked; settlement coalesces to 3.30
  sigma                     = 0.95,   -- the V3-F5 prior's uncertainty
  level                     = null,
  tier                      = null,
  is_anchor                 = false,
  competitive_matches       = 0,
  placement_played          = 0,
  placement_revealed        = false,
  last_competitive_match_at = null,
  updated_at                = now();

-- Any match already marked settled would otherwise be skipped forever by the
-- rating_applied guard, so a replay could never produce a rating.
update public.matches set rating_applied = false where rating_applied;

-- ---------------------------------------------------------------------------
-- 3. Confirm the cold start is actually cold.
-- ---------------------------------------------------------------------------
do $$
declare v_bad bigint;
begin
  select count(*) into v_bad from public.player_ratings
   where rating is not null
      or sigma <> 0.95
      or level is not null
      or tier is not null
      or competitive_matches <> 0
      or placement_played <> 0
      or placement_revealed;
  if v_bad > 0 then
    raise exception '% player(s) did not reset', v_bad;
  end if;

  raise notice 'done — % player(s) unranked, sigma 0.95, no history.',
    (select count(*) from public.player_ratings);
  raise notice 'first five ranked matches now walk the real placement ladder.';
end $$;
