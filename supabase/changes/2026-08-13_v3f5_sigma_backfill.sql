-- ===========================================================================
-- V3-F5 sigma backfill (2026-08-13) — run AFTER 2026-08-13_rating_engine_v3f5.sql
--
-- WHY. The engine migration preserved every existing sigma. Those sigmas came
-- off v2's 0.92-per-match curve, which falls roughly three times faster than
-- V3-F5's. A 10-match player therefore carries sigma ~0.43 where V3-F5 expects
-- 0.74 — and K is sigma-driven, so they correct at ~55% of the intended rate.
-- Early adopters would have got a materially weaker engine than new signups,
-- which defeats much of the point of the migration for exactly the people who
-- were here first.
--
-- WHAT THIS DOES. Re-derives sigma from `competitive_matches` using the V3-F5
-- deterministic curve. That is legitimate precisely BECAUSE V3-F5's sigma
-- carries no player-specific information — it is a pure function of match
-- count (`adaptiveSigma` is off), so "what sigma should this player have"
-- has one correct answer given n.
--
-- WHAT IT DOES NOT TOUCH: `rating`, `level`, `tier`, `competitive_matches`,
-- `placement_played`, `is_anchor`, or any existing `ranking_history` row.
-- Nobody's rating moves and nobody's placement restarts.
--
-- ---------------------------------------------------------------------------
-- THE TAPER, and why it stops where it stops.
--
-- Below 20 matches the full V3-F5 curve is applied — this is the band the
-- problem lives in and where the correction matters most.
--
-- From 20 matches the change is blended linearly toward "leave it alone",
-- reaching no-change at 72. Both endpoints are read off the engine rather
-- than chosen:
--
--   20 — V3-F5's own established boundary (the end of `postStageEnds`, and
--        where `is_provisional` clears). Past it the engine stops treating a
--        player as still calibrating.
--   72 — where the V3-F5 curve reaches the 0.12 sigma floor, i.e. the point at
--        which V3-F5 and v2 agree anyway and there is nothing left to correct.
--
-- The taper answers the fair objection to a flat re-derivation: a 30-match
-- player genuinely HAS 30 matches of evidence, and tripling their volatility
-- overnight is not obviously right. It also avoids the alternative's cliff —
-- cutting the fix off hard at 20 would leave a 19-match player on sigma 0.587
-- and a 20-match player on 0.189, i.e. 2.1x the K for having played one match
-- FEWER, an inversion nothing later removes.
--
-- Resulting movement (legacy sigma -> new sigma, and the K multiplier):
--
--     n=0    1.0000 -> 1.0000   1.00x      n=25   0.1244 -> 0.4563   2.31x
--     n=3    0.7787 -> 0.8670   1.10x      n=30   0.1200 -> 0.3641   1.98x
--     n=5    0.6591 -> 0.8158   1.20x      n=35   0.1200 -> 0.2926   1.69x
--     n=10   0.4344 -> 0.7374   1.54x      n=40   0.1200 -> 0.2377   1.47x
--     n=15   0.2863 -> 0.6497   1.88x      n=50   0.1200 -> 0.1664   1.19x
--     n=19   0.2051 -> 0.5872   2.14x      n=60   0.1200 -> 0.1314   1.05x
--     n=20   0.1887 -> 0.5725   2.21x      n=71+  0.1200 -> 0.1200   1.00x
--
-- Sigma is only ever RAISED. `greatest(current, ...)` is applied last, so no
-- player is made to look more certain than they already were.
--
-- ---------------------------------------------------------------------------
-- WHO IS MIGRATED: only players whose sigma demonstrably came from the legacy
-- engine. That is tested directly, by fingerprint rather than by archaeology —
-- v2 produced exactly two sigma shapes:
--
--     max(0.12, 0.92^n)          (backfilled at the rating-v2 migration; later
--                                 match decay used the same 0.92, so this holds
--                                 however many matches they have played since)
--     max(0.12, 0.85 * 0.92^n)   (accounts created after v2, from the old
--                                 sigma default of 0.85)
--
-- A sigma within 0.005 of either is engine-produced. Anything else was set by
-- a human and is left alone — which is what protects hand-calibrated players:
-- an anchor on 0.30 or a leveling session on 0.50 sits nowhere near the legacy
-- curve at the match counts those RPCs force (>= 10), so both fall out
-- automatically. `is_anchor` is excluded outright as well.
--
-- Also skipped: anyone who has already settled a match under V3-F5. If a match
-- lands between the engine going live and this running, that player's sigma is
-- already moving on the new curve and re-deriving it would rewrite live
-- history.
--
-- ---------------------------------------------------------------------------
-- SAFE TO RE-RUN: guarded by app_settings('v3f5_sigma_migrated'), which also
-- records when it ran. Every change is logged to ranking_history with
-- engine_version = 'sigma_migration' (rating unchanged, delta 0), so the whole
-- operation is auditable and reversible from the log alone.
-- ===========================================================================

do $$
declare
  -- taper endpoints, both read off the engine (see header)
  c_full_below constant int     := 20;   -- established boundary
  c_no_change  constant int     := 72;   -- curve reaches the 0.12 sigma floor
  c_tol        constant numeric := 0.005;-- legacy-fingerprint tolerance

  r record;
  v_v3 numeric; v_w numeric; v_new numeric;
  v_migrated int := 0; v_human int := 0; v_already int := 0; v_nochange int := 0;
begin
  if exists (select 1 from public.app_settings where key = 'v3f5_sigma_migrated') then
    raise notice 'V3-F5 sigma backfill already applied (%). Nothing to do.',
      (select value from public.app_settings where key = 'v3f5_sigma_migrated');
    return;
  end if;

  for r in
    select p.id,
           coalesce(p.competitive_matches, 0) as cm,
           p.sigma,
           p.rating,
           coalesce(p.is_anchor, false) as anchor,
           exists (select 1 from public.ranking_history h
                    where h.profile_id = p.id and h.engine_version = 'v3_f5') as played_v3
      from public.profiles p
  loop
    if r.anchor then
      v_human := v_human + 1; continue;
    end if;

    if r.played_v3 then
      v_already := v_already + 1; continue;
    end if;

    -- legacy fingerprint: does this sigma look like the v2 engine produced it?
    if abs(r.sigma - greatest(0.12, power(0.92, r.cm))) > c_tol
       and abs(r.sigma - greatest(0.12, 0.85 * power(0.92, r.cm))) > c_tol then
      v_human := v_human + 1; continue;
    end if;

    -- the V3-F5 curve at n matches, closed form. Equivalent to iterating the
    -- decay bands (verified over n = 0..119): sigma only falls and the floor is
    -- absorbing, so clamping once at the end is the same as clamping each step.
    v_v3 := greatest(0.12, least(1.0,
              0.95 * power(0.970, least(r.cm, 5))
                   * power(0.980, greatest(0, least(r.cm, 10) - 5))
                   * power(0.975, greatest(0, least(r.cm, 20) - 10))
                   * power(0.970, greatest(0, r.cm - 20))));

    if r.cm < c_full_below then
      v_new := v_v3;
    else
      v_w := greatest(0.0, least(1.0,
               (c_no_change - r.cm)::numeric / (c_no_change - c_full_below)));
      v_new := r.sigma + (v_v3 - r.sigma) * v_w;
    end if;

    -- never make anyone look MORE certain than they already were
    v_new := round(greatest(r.sigma, least(1.0, v_new)), 6);

    if v_new > r.sigma then
      update public.profiles set sigma = v_new where id = r.id;
      insert into public.ranking_history
        (profile_id, match_id, level_before, level_after,
         rating_before, rating_after, sigma_before, sigma_after, delta,
         engine_version, match_no)
      values (r.id, null,
              round(coalesce(r.rating, 0), 2), round(coalesce(r.rating, 0), 2),
              r.rating, r.rating,          -- rating deliberately unchanged
              r.sigma, v_new, 0,
              'sigma_migration', r.cm);
      v_migrated := v_migrated + 1;
    else
      v_nochange := v_nochange + 1;
    end if;
  end loop;

  insert into public.app_settings(key, value)
  values ('v3f5_sigma_migrated', now()::text)
  on conflict (key) do update set value = excluded.value;

  raise notice 'V3-F5 sigma backfill complete.';
  raise notice '  % players re-derived onto the V3-F5 curve', v_migrated;
  raise notice '  % already past the floor / no change needed', v_nochange;
  raise notice '  % left alone (anchor or hand-set sigma)', v_human;
  raise notice '  % skipped (already settled a V3-F5 match)', v_already;
end $$;

-- ---------------------------------------------------------------------------
-- Post-run summary. Read-only — shows where the population now sits, and what
-- correction power each band actually has (K at the band's average sigma).
-- ---------------------------------------------------------------------------
select case
         when coalesce(competitive_matches, 0) = 0  then 'a. 0 (never played)'
         when coalesce(competitive_matches, 0) < 5  then 'b. 1-4  (in placement)'
         when coalesce(competitive_matches, 0) < 10 then 'c. 5-9  (just revealed)'
         when coalesce(competitive_matches, 0) < 20 then 'd. 10-19'
         when coalesce(competitive_matches, 0) < 40 then 'e. 20-39 (tapered)'
         when coalesce(competitive_matches, 0) < 72 then 'f. 40-71 (tapered)'
         else                                            'g. 72+   (untouched)'
       end                                as match_band,
       count(*)                           as players,
       round(avg(sigma), 4)               as avg_sigma,
       round(avg(0.04 + 0.31 * sigma), 4) as avg_k,
       count(*) filter (where is_anchor)  as anchors
  from public.profiles
 group by 1
 order by 1;
