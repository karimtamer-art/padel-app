-- 2026-08-10 — ONE-OFF DATA WIPE. Not a migration. Never re-run by habit.
--
-- ⚠️  THIS DESTROYS DATA AND CANNOT BE UNDONE. Take a backup first:
--     Supabase dashboard → Database → Backups (or `pg_dump`).
--
-- ⚠️  DO NOT paste any of this into supabase/migration_player_app.sql. That
--     file is re-run against live on purpose; a TRUNCATE living in it would
--     empty the database every single time somebody applied the schema.
--
-- WHAT IT DOES
--   1. Empties every table in `public` EXCEPT the keep-list below.
--   2. Resets each profile's rating/uncertainty so nobody carries a rating
--      earned in matches that no longer exist.
--
-- WHAT SURVIVES
--   • auth.users — accounts, passwords and sessions are untouched.
--   • profiles   — including is_admin / admin_role / admin_access / is_owner,
--                  so console access is not lost.
--   • catalog + configuration — see `keep` below.
--   • Storage buckets. Avatars and product images are FILES, not rows; this
--     script cannot and does not delete them. Orphaned avatars will simply be
--     re-pointed the next time a profile uploads one.
--
-- HOW TO RUN IT
--   Leave v_dry_run = true and run it once: it truncates NOTHING and prints
--   the exact table list it would empty, so you can check it against the live
--   schema. Then set v_dry_run = false and run it again for real.

do $$
declare
  -- ── FLIP THIS TO false TO ACTUALLY DELETE ────────────────────────────────
  v_dry_run boolean := true;

  -- Tables whose CONTENTS are preserved. Everything else in `public` is
  -- emptied. Note `saved_formats` is NOT here — admin-built tournament format
  -- templates will be wiped; move it into this list if you want to keep them.
  keep text[] := array[
    'profiles',                                      -- accounts + admin rights
    'products', 'product_images', 'product_costs',   -- store catalog + costs
    'sponsors',                                      -- partners page
    'app_settings', 'courts', 'banners', 'promo_codes',
    'seasons', 'season_rules',                       -- season configuration
    'report_recipients'                              -- weekly-report mailing list
  ];

  v_list text;
  v_count int;
begin
  select string_agg(format('public.%I', tablename), ', ' order by tablename),
         count(*)
    into v_list, v_count
  from pg_tables
  where schemaname = 'public'
    and tablename <> all (keep);

  if v_list is null then
    raise notice 'Nothing to truncate — every public table is in the keep list.';
    return;
  end if;

  raise notice '% table(s) would be emptied:', v_count;
  raise notice '%', v_list;

  if v_dry_run then
    raise notice '--- DRY RUN: nothing was deleted. Set v_dry_run := false to execute. ---';
    return;
  end if;

  -- One statement, so foreign keys between these tables are satisfied by
  -- construction. Deliberately NO CASCADE: if a table we are KEEPING turns out
  -- to reference one of these, this errors loudly instead of quietly emptying
  -- the kept table too. If that happens, read the error and decide — do not
  -- just add CASCADE.
  execute 'truncate table ' || v_list || ' restart identity';

  raise notice 'Truncated % table(s).', v_count;
end $$;

-- ── Reset the rating model on every profile ─────────────────────────────────
-- Only runs for real; harmless to run twice. `reliability` and `is_provisional`
-- are GENERATED columns and must not be assigned — they recompute themselves
-- from sigma and competitive_matches (0.85 and 0 make everyone provisional
-- again, which is correct for a player with no match history).
--
-- 2.0 is the engine's own fallback for an unrated player (`coalesce(rating,
-- 2.0)` throughout _settle_rating), so it is the neutral starting point. If you
-- would rather leave players genuinely unrated, set rating and level to null
-- instead — the engine treats null as 2.0 anyway, but the app will display it
-- as empty rather than as a 2.0.
--
-- `is_anchor` is deliberately NOT reset: admin-calibrated anchor players are
-- configuration, not match history. `elo` is legacy/backfill only and ignored.
update public.profiles
   set rating                    = 2.0,
       level                     = 2.0,   -- display mirror of rating
       sigma                     = 0.85,
       competitive_matches       = 0,
       last_competitive_match_at = null;

-- ── Check it did what you expected ──────────────────────────────────────────
select (select count(*) from public.profiles)          as profiles_kept,
       (select count(*) from public.products)          as products_kept,
       (select count(*) from public.matches)           as matches_left,
       (select count(*) from public.orders)            as orders_left,
       (select count(*) from public.expenses)          as expenses_left,
       (select count(*) from public.report_recipients) as recipients_kept;
