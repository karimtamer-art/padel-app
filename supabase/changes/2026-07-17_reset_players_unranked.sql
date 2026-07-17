-- 2026-07-17 · OPT-IN reset: send existing players back to UNRANKED.
--
-- DESTRUCTIVE — this wipes current ratings. Run it only when you actually want
-- to reset the ladder (e.g. before launch). It does NOT run as part of the
-- canonical migration.
--
-- KEEP LIST: players you want to preserve must be marked as ANCHORS first
-- (Players console → Edit ranking → "Anchor player"), or added to the username
-- list below. Admins and anchors are skipped. To hard-keep specific people by
-- handle, list their usernames in the CTE.

-- Legacy elo/level/tier must allow NULL (older DBs created elo NOT NULL) before
-- we can clear them. Idempotent.
alter table public.profiles alter column elo   drop not null;
alter table public.profiles alter column level drop not null;
alter table public.profiles alter column tier  drop not null;

with keep as (
  select id from public.profiles
  where coalesce(is_admin, false)  = true
     or coalesce(is_anchor, false) = true
     or lower(username) = any (array[
          -- 'your_username', 'reference_player'
        ]::text[])
)
update public.profiles p
   set rating              = null,
       level               = null,
       tier                = null,
       elo                 = null,
       division_pts        = 0,
       sigma               = 0.85,   -- back to the fresh-account uncertainty
       competitive_matches = 0,
       placement_played    = 0,
       is_anchor           = false
 where p.id not in (select id from keep);

-- Note: this does not delete match history or ranking_history rows; it only
-- resets the current standing so everyone re-enters placement.
