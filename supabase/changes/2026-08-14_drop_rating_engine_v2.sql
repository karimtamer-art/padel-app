-- ===========================================================================
-- Remove rating engine v2 (2026-08-14)
--
-- V3-F5 has been live, verified (22/22 on 2026-08-13_verify_v3f5.sql) and has
-- settled real matches. The v2 fallback has done its job and is now just a
-- second engine nobody intends to run.
--
-- THIS REMOVES THE ROLLBACK. Until now, reverting was
-- `update app_settings set value = 'v2' where key = 'rating_engine'`. After
-- this, recovering v2 means restoring `_settle_rating_v2` out of git
-- (supabase/changes/2026-08-13_rating_engine_v3f5.sql, section 6) and running
-- it — still entirely possible, just manual. Run this only once you are
-- satisfied with how V3-F5 is settling real matches.
--
-- WHAT GOES
--   _settle_rating_v2()        the v2 maths
--   rating_engine_version()    the selector
--   app_settings 'rating_engine' row
--   the dispatch indirection — _settle_rating IS the engine now
--
-- WHAT STAYS
--   every ranking_history row, including engine_version IS NULL (v2-settled)
--   and 'v2' — history is never rewritten
--   profiles.elo / level_from_elo — the older v1 ELO layer, its own cleanup
--   the Ranking Lab's v2 baseline, which is research code, not production
--
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. _settle_rating absorbs the engine.
--
--    Previously: a dispatcher that read app_settings and delegated. Now the
--    V3-F5 body directly, with the casual guard at the top — one function, one
--    engine, nothing to select. The engine identity lives where it is actually
--    useful: stamped on every ranking_history row as engine_version.
--
--    The constant block below is still the SQL half of the Dart/SQL parity
--    test, which reads THIS function by name.
-- ---------------------------------------------------------------------------
create or replace function public._settle_rating(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  -- ==== V3-F5 CONSTANT BLOCK (mirrored in RatingEngineV3F5; drift is a test
  -- failure, not a surprise in production) ================================
  c_prior      constant numeric   := 3.30;   -- hidden starting estimate
  c_sigma0     constant numeric   := 0.95;   -- starting uncertainty
  c_placement  constant int       := 5;      -- public placement matches
  c_stage_end  constant int[]     := array[2, 4, 5];         -- exclusive
  c_stage_k    constant numeric[] := array[1.15, 0.90, 0.70];
  c_stage_lo   constant numeric   := 0.35;   -- sigma scaling floor in placement
  c_k_min      constant numeric   := 0.04;
  c_k_max      constant numeric   := 0.35;
  c_curve      constant numeric   := 1.0;    -- logistic scale
  c_result_w   constant numeric   := 0.85;
  c_pl_relfl   constant numeric   := 1.00;   -- W floor while in placement
  c_relfl      constant numeric   := 0.65;   -- W floor once established
  c_pl_decay   constant numeric   := 0.970;  -- sigma decay, matches 1-5
  c_post_end   constant int[]     := array[10, 20];
  c_post_decay constant numeric[] := array[0.980, 0.975];
  c_decay      constant numeric   := 0.970;  -- established, matches 21+
  c_sig_min    constant numeric   := 0.12;
  c_sig_max    constant numeric   := 1.00;
  c_r_min      constant numeric   := 0.0;
  c_r_max      constant numeric   := 7.0;
  c_anchor     constant numeric   := 0.05;
  c_dp         constant int       := 6;      -- stored precision
  c_version    constant text      := 'v3_f5';
  -- ========================================================================

  v_type text;
  v_winner text; v_score_a text; v_applied boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric; v_s_a numeric; v_s_b numeric;
  v_raw_w_a numeric; v_raw_w_b numeric;
  r record; v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric; v_decay numeric;
  v_placement boolean;
begin
  select coalesce(match_type, 'ranked'), winner_team, score_team_a,
         coalesce(rating_applied, false)
    into v_type, v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;

  if v_type is null then return; end if;          -- no such match
  if v_type <> 'ranked' then return; end if;      -- casual is unrated, always
  if v_applied then return; end if;               -- idempotency: never twice
  if v_winner is null then return; end if;

  select a, b into v_ga, v_gb from public._parse_set_games(v_score_a);
  v_ga := coalesce(v_ga, 0); v_gb := coalesce(v_gb, 0); v_tot := v_ga + v_gb;

  -- Team strength is the plain average of the pair. lambda (team imbalance) is
  -- 0 and stays 0 until it can be fitted on real match history: 5.0 + 2.0 and
  -- 3.5 + 3.5 are the same team to this engine, knowingly.
  select avg(coalesce(p.rating, c_prior))  filter (where mp.team = 'a'),
         avg(coalesce(p.rating, c_prior))  filter (where mp.team = 'b'),
         avg(coalesce(p.sigma,  c_sigma0)) filter (where mp.team = 'a'),
         avg(coalesce(p.sigma,  c_sigma0)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, c_prior);  v_avg_b := coalesce(v_avg_b, c_prior);
  v_sig_a := coalesce(v_sig_a, c_sigma0); v_sig_b := coalesce(v_sig_b, c_sigma0);

  -- E_b is the COMPLEMENT of E_a, not a second logistic, so the pair sums to
  -- exactly 1 the way the reference implementation does.
  v_e_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / c_curve));
  v_e_b := 1.0 - v_e_a;

  v_s_a := c_result_w * (case when v_winner = 'a' then 1 else 0 end)
         + (1 - c_result_w) * public._v3f5_margin(v_ga, v_gb);
  v_s_b := c_result_w * (case when v_winner = 'b' then 1 else 0 end)
         + (1 - c_result_w) * public._v3f5_margin(v_gb, v_ga);

  -- W depends on the OPPONENTS' mean sigma, but its floor depends on the
  -- player's OWN match count, so the raw value is computed per team here and
  -- floored per player in the loop.
  v_raw_w_a := 0.5 + 0.5 * (1 - v_sig_b);
  v_raw_w_b := 0.5 + 0.5 * (1 - v_sig_a);

  -- Season ladder is a SEPARATE system and is untouched by V3-F5. It runs here
  -- because it must see the pre-match ratings (that is what its upset bonus is
  -- measured against).
  perform public._award_season_points(p_match_id);

  for r in
    select mp.player_id, mp.team,
           coalesce(p.rating, c_prior)  as rating,
           coalesce(p.sigma,  c_sigma0) as sigma,
           coalesce(p.competitive_matches, 0) as cm,
           coalesce(p.is_anchor, false) as anchor
      from match_players mp join profiles p on p.id = mp.player_id
     where mp.match_id = p_match_id
  loop
    if r.team = 'a' then v_s := v_s_a; v_e := v_e_a; v_w := v_raw_w_a;
    else                 v_s := v_s_b; v_e := v_e_b; v_w := v_raw_w_b; end if;

    v_placement := (r.cm < c_placement);

    -- W: no opponent is discounted at all during a player's first five
    -- matches. Discounting opponents at launch, when nobody is established,
    -- suppresses exactly the evidence placement needs.
    v_w := greatest(v_w, case when v_placement then c_pl_relfl else c_relfl end);

    -- K: staged in placement (exploration / calibration / validation), scaled
    -- inside the stage by remaining uncertainty so the stage value is a
    -- ceiling. After placement, the plain sigma-driven formula — no
    -- intermediate schedule, and the drop from 0.62 to 0.29 between match 5
    -- and match 6 is characteristic of V3-F5, not a bug to smooth.
    if v_placement then
      if    r.cm < c_stage_end[1] then v_k := c_stage_k[1];
      elsif r.cm < c_stage_end[2] then v_k := c_stage_k[2];
      else                             v_k := c_stage_k[3];
      end if;
      v_k := v_k * greatest(c_stage_lo, least(1.0, r.sigma / c_sigma0));
    else
      v_k := c_k_min + (c_k_max - c_k_min) * r.sigma;
    end if;

    -- A huge favourite winning narrowly gives S < E and therefore a NEGATIVE
    -- delta. That is measured, accepted V3-F5 behaviour; do not add a
    -- `if won then delta := greatest(delta, 0)` here.
    v_delta := v_k * v_w * (v_s - v_e);
    -- Anchors are a SOFT pin: a hand-calibrated player still moves, by at most
    -- 0.05 a match, and their sigma still decays normally.
    if r.anchor then v_delta := greatest(-c_anchor, least(c_anchor, v_delta)); end if;
    v_after := round(greatest(c_r_min, least(c_r_max, r.rating + v_delta)), c_dp);

    -- Sigma: deterministic, keyed on matches already played. Approaches the
    -- established rate from ABOVE and never dips below it, which is what keeps
    -- K alive after the rating goes public. It ignores the RESULT entirely —
    -- the known "confidently wrong" weakness, preserved on purpose.
    if    v_placement            then v_decay := c_pl_decay;
    elsif r.cm < c_post_end[1]   then v_decay := c_post_decay[1];
    elsif r.cm < c_post_end[2]   then v_decay := c_post_decay[2];
    else                              v_decay := c_decay;
    end if;
    v_sig_after := round(greatest(c_sig_min, least(c_sig_max, r.sigma * v_decay)), c_dp);

    update profiles set
      rating = v_after,
      -- level is the 2dp DISPLAY mirror of rating; it is never read back into
      -- the math, so display rounding cannot feed the engine.
      level  = round(v_after, 2),
      tier   = public.tier_from_level(v_after),
      sigma  = v_sig_after,
      competitive_matches = r.cm + 1,
      -- the placement counter, and with it the public reveal, at match 5
      placement_played = least(coalesce(placement_played, 0) + 1, c_placement),
      last_competitive_match_at = now()
    where id = r.player_id;

    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta,
       opp_avg_rating, games_for, games_against, won,
       engine_version, match_no, k_factor, w_opp, expected, signal)
    values (r.player_id, p_match_id, round(r.rating, 2), round(v_after, 2),
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, c_dp),
       round((case when r.team = 'a' then v_avg_b else v_avg_a end)::numeric, 4),
       case when r.team = 'a' then v_ga else v_gb end,
       case when r.team = 'a' then v_gb else v_ga end,
       (r.team = v_winner),
       -- the intermediate terms are recorded so a future engine can be
       -- replayed against real history without re-deriving them
       c_version, r.cm + 1, round(v_k, 6), round(v_w, 6), round(v_e, 6), round(v_s, 6));
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Drop what is now unreachable.
--
--    _settle_rating_v3f5 goes too: its body is _settle_rating now, and leaving
--    a second identical copy behind is how the two drift apart later. Nothing
--    calls it — every caller (confirm_match_result, admin_resolve_match,
--    expire_stale_matches, finalize_tournament) goes through _settle_rating.
-- ---------------------------------------------------------------------------
drop function if exists public._settle_rating_v2(uuid);
drop function if exists public._settle_rating_v3f5(uuid);
drop function if exists public.rating_engine_version();

delete from public.app_settings where key = 'rating_engine';

-- ---------------------------------------------------------------------------
-- 3. Prove nothing was left pointing at the removed engine.
--
--    A stale call would only surface when a match settled, which is exactly
--    when nobody wants to discover it.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ')
    into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname <> '_settle_rating'
     and (p.prosrc like '%_settle_rating_v2%'
       or p.prosrc like '%_settle_rating_v3f5%'
       or p.prosrc like '%rating_engine_version%');
  if v_bad is not null then
    raise exception 'still referencing the removed v2 engine: %', v_bad;
  end if;

  if not exists (select 1 from pg_proc
                  where proname = '_settle_rating'
                    and pronamespace = 'public'::regnamespace) then
    raise exception '_settle_rating is missing — do not leave the DB in this state';
  end if;

  raise notice 'rating engine v2 removed. _settle_rating is V3-F5, no dispatch.';
  raise notice 'ranking_history keeps % v2-era rows (engine_version null or ''v2'').',
    (select count(*) from public.ranking_history
      where engine_version is null or engine_version = 'v2');
end $$;

grant execute on function public._settle_rating(uuid) to authenticated;

notify pgrst, 'reload schema';
