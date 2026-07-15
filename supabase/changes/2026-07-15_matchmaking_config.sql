-- 2026-07-15 · Matchmaking Phase 0 — tunable band config (no behavior change)
--
-- Seeds the matchmaking band constants into app_settings (the single tunable
-- config location, admin-editable, no redeploy) and adds a pure SQL helper that
-- computes the band half-width for a search of a given age. Nothing reads these
-- yet — Phase 1 (visibility lockdown + mm_find_candidate) will. Mirrored in Dart
-- by MatchmakingConfig (lib/backend/models/matchmaking_config.dart); keep the two
-- in lockstep, same discipline as RatingEngine <-> _settle_rating.
--
-- Band equation (rating scale 0..7):
--   halfwidth(ageMin) = min(mm_band_max, mm_band_base + mm_band_widen_per_min*ageMin)
--   visible(searcher, match) = |searcher.rating - match.mm_center_rating| <= halfwidth
--     AND same city AND scheduled within mm_time_window_hours AND status='open'
--
-- Idempotent (on conflict do nothing preserves admin-tuned values). Also folded
-- into migration_player_app.sql.

insert into public.app_settings (key, value) values
  ('mm_band_base',         '0.4'),   -- initial half-width around the player's rating
  ('mm_band_widen_per_min','0.05'),  -- half-width growth per minute unmatched
  ('mm_band_max',          '1.5'),   -- hard cap on the half-width
  ('mm_time_window_hours', '12'),    -- a candidate match must start within this window
  ('mm_confirm_seconds',   '120'),   -- the "Match found" 2:00 accept countdown
  ('mm_range_mode',        'city')   -- v1 range proxy (same-city); 'km' is a later upgrade
on conflict (key) do nothing;

-- Band half-width for a search that has been running age_minutes minutes.
-- coalesce() falls back to the seed defaults so the function is safe even if a
-- key is deleted. STABLE + reads only app_settings → callable from RPCs.
create or replace function public.mm_band_halfwidth(age_minutes numeric)
returns numeric
language sql stable as $$
  with c as (
    select
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_base'), 0.4)          as base,
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_widen_per_min'), 0.05) as widen,
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_max'), 1.5)           as bmax
  )
  select least(c.bmax, c.base + c.widen * greatest(coalesce(age_minutes, 0), 0)) from c;
$$;

grant execute on function public.mm_band_halfwidth(numeric) to authenticated;
