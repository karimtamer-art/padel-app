-- ===========================================================================
-- Rating engine V3-F5 (2026-08-13) — replaces rating engine v2 as the engine
-- that settles a competitive match.
--
-- V3-F5 was selected in the Ranking Lab (tools/ranking_simulation/). Every
-- constant below was read out of the EXECUTABLE lab config — engines.dart,
-- `final kV3F5 = kV3F.copyWith(...)`, resolved through the
-- kV3Config -> kV3E -> kV3F -> kV3F5 copyWith chain and run by
-- `HybridEngine.update`. The Dart mirror is
-- lib/backend/models/rating_engine_v3f5.dart; the two are pinned against each
-- other by test/rating_engine_v3f5_parity_test.dart, which also reads THIS
-- FILE and compares the constant block below to the Dart constants, so drift
-- between SQL and Dart fails a test rather than silently mis-rating people.
--
-- WHAT CHANGES, versus v2:
--   prior      2.00 -> 3.30            sigma0     0.85 -> 0.95
--   S          0.7*result + 0.3*ratio  ->  0.85*result + 0.15*saturating margin
--   W floor    0.50 always             ->  1.00 in placement, 0.65 after
--   K          (0.04+0.31s) x1.5 <5    ->  staged 1.15/0.90/0.70 then 0.04+0.31s
--   sigma      x0.92 flat              ->  0.970 / 0.980 / 0.975 / 0.970 by band
--   precision  rating numeric(3,2)     ->  numeric(9,6)   (level stays 2dp)
--
-- WHAT DOES NOT CHANGE: the status machine, who may submit or confirm a score,
-- the rating_applied idempotency guard, season points, casual matches staying
-- unrated, the 5-match placement gate (production already used 5), anchors,
-- and the 0.00-7.00 public scale.
--
-- Safe to re-run. Run it once on live; see the header of the migration file
-- for the "only one person runs SQL" rule.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Precision. V3-F5 does no rounding internally; production stored ratings
--    at numeric(3,2) AND round()ed to 2dp on every settlement, which quantised
--    the estimate ~50x more coarsely than the deltas the engine produces
--    (a 20-match player's delta is often < 0.01). Widening to 6dp makes the
--    per-match quantisation 5e-7 — far below anything observable, and far
--    below the 0.25 step a player is shown.
--
--    `level` deliberately stays the 2dp DISPLAY mirror. Nothing reads `level`
--    back into the math; rating is the engine's number, level is the screen's.
-- ---------------------------------------------------------------------------
do $$
begin
  -- guarded: retyping is a table rewrite, so skip it once already applied
  if (select numeric_scale from information_schema.columns
       where table_schema = 'public' and table_name = 'profiles'
         and column_name = 'rating') is distinct from 6 then
    alter table public.profiles alter column rating type numeric(9,6);
  end if;
end $$;

-- New accounts start at the V3-F5 starting uncertainty. Existing rows are NOT
-- touched here — see section 9.
alter table public.profiles
  alter column sigma set default 0.95;

-- ---------------------------------------------------------------------------
-- 2. Rating history gains provenance. Legacy rows keep engine_version NULL,
--    which is how v2-settled history stays distinguishable forever.
-- ---------------------------------------------------------------------------
alter table public.ranking_history
  add column if not exists engine_version text,
  add column if not exists match_no       int,
  add column if not exists k_factor       numeric,
  add column if not exists w_opp          numeric,
  add column if not exists expected       numeric,
  add column if not exists signal         numeric;

comment on column public.ranking_history.engine_version is
  'Rating engine that produced this row. NULL = rating engine v2 (pre 2026-08-13).';
comment on column public.ranking_history.match_no is
  'This match''s 1-based ordinal in the player''s competitive career.';

create index if not exists ranking_history_engine_idx
  on public.ranking_history (engine_version);

-- ---------------------------------------------------------------------------
-- 3. The confidence flag, recalibrated to the V3-F5 sigma curve.
--
--    This is NOT the placement gate. Placement is 5 matches and is measured by
--    placement_played; after it the rating is public. is_provisional is the
--    separate "the engine is not confident yet" flag, and V3-F5 pulls the two
--    much further apart than v2 did (revealed at match 5 with sigma ~0.82).
--
--    The threshold is DERIVED, not chosen. v2 paired `sigma > 0.40` with
--    `matches < 10` because 0.85*0.92^n crosses 0.40 at exactly n=10, so both
--    clauses flipped together. The same construction on the V3-F5 curve gives
--    sigma 0.5871 after 19 matches and 0.5725 after 20, so 0.58 flips at
--    exactly the end of the last post-placement sigma band (matches >= 20).
--    Leaving it at 0.40 would have kept every player provisional until ~match
--    32 while the app told them they only needed 10.
--
--    A generated column's expression cannot be altered in place, so it is
--    dropped and re-added. Nothing in the schema depends on it (no views; the
--    admin consoles read it from PL/pgSQL functions, which are not bound at
--    DDL time).
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
begin
  select pg_get_expr(d.adbin, d.adrelid) into v_def
    from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where d.adrelid = 'public.profiles'::regclass and a.attname = 'is_provisional';
  -- guarded: dropping a stored generated column rewrites the table, so only
  -- do it when the live expression is still the v2 one
  if v_def is null or v_def not like '%0.58%' then
    alter table public.profiles drop column if exists is_provisional;
    alter table public.profiles
      add column is_provisional boolean
        generated always as (sigma > 0.58 or competitive_matches < 20) stored;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Engine selector — the rollback path.
--
--    app_settings.rating_engine = 'v3_f5' (default) | 'v2'. Setting it to 'v2'
--    routes settlement back through the untouched v2 maths WITHOUT a redeploy,
--    which is what makes turning V3-F5 on during live verification reversible.
--    Matches already settled are not re-settled either way (rating_applied).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value) values ('rating_engine', 'v3_f5')
  on conflict (key) do nothing;

create or replace function public.rating_engine_version()
returns text language sql stable set search_path = public as $$
  select coalesce((select value from public.app_settings where key = 'rating_engine'),
                  'v3_f5')::text
$$;
grant execute on function public.rating_engine_version() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The saturating games margin — the whole of V3-F5's margin contribution.
--
--        rho  = gamesFor / (gamesFor + gamesAgainst)      (0.5 if no games)
--        rho' = 0.5 + clamp(rho - 0.5, +/-0.15) / 0.15 * 0.5
--
--    Beyond a 0.65 games ratio every scoreline is worth the same, so 6-2 6-2
--    and 6-0 6-0 carry identical weight and running up a score buys nothing.
--    rho'(for,against) + rho'(against,for) == 1 by construction, which is what
--    makes S_win + S_lose == 1.
--
--    Split out as its own immutable function so SQL and Dart share ONE
--    expression rather than two transcriptions of it.
-- ---------------------------------------------------------------------------
create or replace function public._v3f5_margin(p_for int, p_against int)
returns numeric language sql immutable as $$
  select 0.5 + (greatest(-0.15, least(0.15,
    (case when coalesce(p_for, 0) + coalesce(p_against, 0) = 0 then 0.5
          else coalesce(p_for, 0)::numeric
               / (coalesce(p_for, 0) + coalesce(p_against, 0))
     end) - 0.5)) / 0.15) * 0.5
$$;

-- ---------------------------------------------------------------------------
-- 6. _settle_rating_v2 — rating engine v2, PRESERVED VERBATIM.
--
--    This is the exact body _settle_rating had before this change, moved
--    behind a name so the dispatcher can reach it. Do not "improve" it: its
--    whole value is being an unchanged record of what settled every
--    engine_version IS NULL row in ranking_history, and the rollback target.
-- ---------------------------------------------------------------------------
create or replace function public._settle_rating_v2(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_winner text; v_score_a text; v_applied boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric; v_ratio_a numeric; v_ratio_b numeric;
  v_s_a numeric; v_s_b numeric; v_w_a numeric; v_w_b numeric;
  r record; v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric;
begin
  select winner_team, score_team_a, coalesce(rating_applied, false)
    into v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;
  if v_applied then return; end if;
  if v_winner is null then return; end if;

  select a, b into v_ga, v_gb from public._parse_set_games(v_score_a);
  v_ga := coalesce(v_ga, 0); v_gb := coalesce(v_gb, 0); v_tot := v_ga + v_gb;

  select avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'a'),
         avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'b'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'a'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 2.0); v_avg_b := coalesce(v_avg_b, 2.0);
  v_sig_a := coalesce(v_sig_a, 0.85); v_sig_b := coalesce(v_sig_b, 0.85);

  v_e_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / 1.0));
  v_e_b := 1.0 / (1.0 + power(10.0, (v_avg_a - v_avg_b) / 1.0));
  v_ratio_a := case when v_tot = 0 then 0.5 else v_ga::numeric / v_tot end;
  v_ratio_b := case when v_tot = 0 then 0.5 else v_gb::numeric / v_tot end;
  v_s_a := 0.7 * (case when v_winner = 'a' then 1 else 0 end) + 0.3 * v_ratio_a;
  v_s_b := 0.7 * (case when v_winner = 'b' then 1 else 0 end) + 0.3 * v_ratio_b;
  v_w_a := 0.5 + 0.5 * (1 - v_sig_b);
  v_w_b := 0.5 + 0.5 * (1 - v_sig_a);

  perform public._award_season_points(p_match_id);

  for r in
    select mp.player_id, mp.team,
           coalesce(p.rating, 2.0) as rating, coalesce(p.sigma, 0.85) as sigma,
           coalesce(p.competitive_matches, 0) as cm, coalesce(p.is_anchor, false) as anchor
      from match_players mp join profiles p on p.id = mp.player_id
     where mp.match_id = p_match_id
  loop
    if r.team = 'a' then v_s := v_s_a; v_e := v_e_a; v_w := v_w_a;
    else                 v_s := v_s_b; v_e := v_e_b; v_w := v_w_b; end if;
    v_k := 0.04 + (0.35 - 0.04) * (r.sigma / 1.0);
    if r.cm < 5 then v_k := v_k * 1.5; end if;
    v_delta := v_k * v_w * (v_s - v_e);
    if r.anchor then v_delta := greatest(-0.05, least(0.05, v_delta)); end if;
    v_after := round(greatest(0.0, least(7.0, r.rating + v_delta)), 2);
    v_sig_after := greatest(0.12, round(r.sigma * 0.92, 4));
    update profiles set
      rating = v_after, level = v_after, tier = public.tier_from_level(v_after),
      sigma = v_sig_after, competitive_matches = r.cm + 1,
      placement_played = least(coalesce(placement_played, 0) + 1, 5),
      last_competitive_match_at = now()
    where id = r.player_id;
    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta,
       opp_avg_rating, games_for, games_against, won, engine_version, match_no)
    values (r.player_id, p_match_id, r.rating, v_after,
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, 2),
       round((case when r.team = 'a' then v_avg_b else v_avg_a end)::numeric, 2),
       case when r.team = 'a' then v_ga else v_gb end,
       case when r.team = 'a' then v_gb else v_ga end,
       (r.team = v_winner), 'v2', r.cm + 1);
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. _settle_rating_v3f5 — THE ENGINE.
--
--    Per player i on team T against O, with every input read PRE-match:
--
--      T     = (R1 + R2) / 2                        pure average, lambda = 0
--      E_T   = 1 / (1 + 10^((T_O - T_T) / 1.0))     E_O = 1 - E_T
--      S     = 0.85*result + 0.15*rho'              rho' from _v3f5_margin
--      W     = max(0.5 + 0.5*(1 - mean sigma_opp), floor)
--              floor = 1.00 while n < 5, else 0.65
--      K     = stageK[j] * clamp(sigma/0.95, 0.35, 1.0)   if n < 5
--            = 0.04 + 0.31*sigma                          if n >= 5
--      delta = K * W * (S - E_T)                    +/-0.05 for ANCHORS only
--      R'    = clamp(R + delta, 0.0, 7.0)
--      sigma'= clamp(sigma * d, 0.12, 1.0)
--      n'    = n + 1
--
--    n is competitive_matches read BEFORE this match is counted, which is what
--    puts the stage and decay boundaries at 5/6, 10/11 and 20/21.
--
--    THREE BEHAVIOURS THAT LOOK LIKE BUGS AND ARE NOT. All three were measured
--    and accepted when V3-F5 was selected; changing any of them here makes
--    production stop matching the engine that was validated.
--
--      * A WINNER CAN LOSE A LITTLE RATING. At E ~ 0.99 the winner needs a
--        games ratio >= 0.630 to gain; 6-4 6-4 yields delta = -0.002. Do not
--        add `if won then delta := greatest(delta, 0)`.
--      * SIGMA IGNORES EVIDENCE. Decay is a pure function of match count, so a
--        player who keeps being wrong still gets more confident, and K falls
--        with sigma. This is the "confidently wrong" weakness. The lab's
--        surprise-aware sigma exists and is deliberately OFF.
--      * K DROPS OFF A CLIFF at match 5 -> 6 (0.62 -> 0.29). There is NO
--        elevated early-career K stage for matches 6-10; the normal
--        sigma-driven formula takes over immediately. Matches 6-10 differ only
--        in their sigma decay band.
--
--    Any change to the above is a new engine version (V3-F5.1), studied in the
--    lab first, not an edit here.
-- ---------------------------------------------------------------------------
create or replace function public._settle_rating_v3f5(p_match_id uuid)
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

  v_winner text; v_score_a text; v_applied boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric; v_s_a numeric; v_s_b numeric;
  v_raw_w_a numeric; v_raw_w_b numeric;
  r record; v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric; v_decay numeric;
  v_placement boolean;
begin
  select winner_team, score_team_a, coalesce(rating_applied, false)
    into v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;
  if v_applied then return; end if;   -- idempotency: never settle twice
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
    -- intermediate schedule.
    if v_placement then
      if    r.cm < c_stage_end[1] then v_k := c_stage_k[1];
      elsif r.cm < c_stage_end[2] then v_k := c_stage_k[2];
      else                             v_k := c_stage_k[3];
      end if;
      v_k := v_k * greatest(c_stage_lo, least(1.0, r.sigma / c_sigma0));
    else
      v_k := c_k_min + (c_k_max - c_k_min) * r.sigma;
    end if;

    v_delta := v_k * v_w * (v_s - v_e);
    -- Anchors are a SOFT pin: a hand-calibrated player still moves, by at most
    -- 0.05 a match, and their sigma still decays normally.
    if r.anchor then v_delta := greatest(-c_anchor, least(c_anchor, v_delta)); end if;
    v_after := round(greatest(c_r_min, least(c_r_max, r.rating + v_delta)), c_dp);

    -- Sigma: deterministic, keyed on matches already played. Approaches the
    -- established rate from ABOVE and never dips below it, which is what keeps
    -- K alive after the rating goes public.
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
-- 8. The dispatcher. Every existing caller (confirm_match_result,
--    admin_resolve_match, expire_stale_matches' 48h auto-settle,
--    finalize_tournament) keeps calling _settle_rating and does not care which
--    engine ran.
--
--    The casual guard is belt-and-braces: casual matches already never reach
--    settlement (submit_match_result sends them straight to 'completed',
--    skipping pending_confirm), but a rating engine should refuse an unrated
--    match itself rather than rely on every caller remembering.
-- ---------------------------------------------------------------------------
create or replace function public._settle_rating(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_type text;
begin
  select coalesce(match_type, 'ranked') into v_type
    from public.matches where id = p_match_id;
  if v_type is null then return; end if;
  if v_type <> 'ranked' then return; end if;   -- casual is unrated, always

  if public.rating_engine_version() = 'v2' then
    perform public._settle_rating_v2(p_match_id);
  else
    perform public._settle_rating_v3f5(p_match_id);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Existing players are NOT reset.
--
--    Ratings, sigmas, competitive_matches and all of ranking_history are left
--    exactly as they are. Established players stay ranked and keep their
--    number; players part-way through placement keep their progress and carry
--    on toward five. Only FUTURE matches settle under V3-F5.
--
--    THE SIGMA GAP IS NOW CLOSED — see
--    supabase/changes/2026-08-13_v3f5_sigma_backfill.sql, run straight after
--    this one.
--
--    The problem it solves: existing sigmas came off v2's 0.92-per-match
--    curve, which falls ~3x faster than V3-F5's, so a 10-match player carried
--    sigma ~0.43 where V3-F5 expects 0.74. K is sigma-driven, so early
--    adopters would have corrected at roughly half the intended rate — the
--    people who were here first getting a materially weaker engine than new
--    signups.
--
--    That backfill re-derives sigma from `competitive_matches` alone (which is
--    valid precisely because V3-F5's sigma carries no player information), in
--    full below 20 matches and tapering to no-change at 72. It touches sigma
--    and nothing else: no rating, no match count, no placement state. Ratings
--    and match counts remain preserved exactly as described above.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 10. Inactivity widens UNCERTAINTY only. It no longer touches the rating.
--
--     Absence is lost information, not lost skill. V3-F5 was selected with
--     `ratingInactivityDecay = false`, so a job that quietly subtracted
--     0.04/week from the skill estimate meant production was not really
--     running the engine that was validated — it was running V3-F5 during
--     matches and something else between them. The rating decay is REMOVED.
--     Nothing outside match settlement may move a rating now, except an
--     explicit admin action.
--
--     What that deleted, for the record: −0.04/week after 60 days idle,
--     floored at the division boundary (5.0 / 3.5 / 2.0) and never below 1.0,
--     for players with 5+ competitive matches. It wrote `engine_version =
--     'decay'` rows to ranking_history. Existing rows from the v2 era stay —
--     history is not rewritten, and those ratings are not restored, because
--     re-inflating people on the basis of a rule we just retired would be its
--     own unreviewed rating change. They will simply re-converge by playing.
--
--     WHAT REMAINS is the sigma half, kept and corrected. The Ranking Lab's
--     idle() helper is known-broken — `min(cap, sigma + ...)` LOWERS sigma for
--     anyone already above the cap — and is NOT ported. Production had the
--     identical bug, dormant: `least(0.60, sigma + 0.01)` never bit under v2
--     because sigma fell below 0.60 within a few matches. Under V3-F5 sigma
--     stays above 0.60 until ~match 17, so going quiet would have made the app
--     MORE confident about a player it had just stopped learning about. It is
--     monotone now — inactivity may raise uncertainty, never lower it — at v2's
--     unchanged 0.60 target and 0.01/week rate.
--
--     Raising sigma is the right response to absence on its own terms: it
--     widens K, so a returning player is re-measured quickly by playing rather
--     than being pre-emptively marked down for not playing.
--
--     The NAME is now a misnomer and is kept deliberately: the pg_cron
--     schedule stores `select public.apply_rating_decay()` as a command
--     STRING, so renaming would silently orphan the job. Note it needs pg_cron
--     enabled to run at all.
-- ---------------------------------------------------------------------------
create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  update public.profiles p
     set sigma = greatest(p.sigma, least(0.60, p.sigma + 0.01))
  where coalesce(p.is_admin, false) = false and p.sigma < 0.60
    and (p.last_competitive_match_at is null
         or p.last_competitive_match_at < now() - interval '14 days');
  get diagnostics v_count = row_count;
  -- returns players whose uncertainty was widened (it used to return players
  -- whose rating was cut, which is now always zero by construction)
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Admin rating controls follow the recalibrated confidence gate.
--
--     Both RPCs used to force competitive_matches to >= 10 because that was
--     where v2's is_provisional cleared. The gate is now 20, so they push to
--     20 — otherwise "Mark anchor" would leave the player flagged provisional,
--     which is the opposite of what the action means.
--
--     Anchor ratings themselves are NOT created or recalibrated here. The
--     Ranking Lab's established pool is anchored at TRUE skill with sigma 0.25
--     for research purposes; production anchors are hand-calibrated humans and
--     are not equivalent. Reproducing the lab's pool in production would be
--     inventing data.
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_player_rating(p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_rating numeric; v_rating numeric;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  v_rating := public.level_from_elo(greatest(800, least(2200, p_elo)));
  select coalesce(rating, coalesce(level, 0)) into v_old_rating
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = round(v_rating, 2),
    tier = public.tier_from_level(v_rating),
    elo = greatest(800, least(2200, p_elo)), sigma = 0.30,
    competitive_matches = greatest(coalesce(competitive_matches, 0), 20),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta, engine_version)
  values (p_player_id, null, round(v_old_rating, 2), round(v_rating, 2),
     v_old_rating, v_rating, null, 0.30, round(v_rating - v_old_rating, 6), 'admin');
  return null;
end $$;

create or replace function public.admin_set_rating(
  p_player_id uuid, p_rating numeric, p_sigma numeric,
  p_is_anchor boolean default false, p_notes text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_rating numeric; v_sigma numeric;
  v_old_rating numeric; v_old_sigma numeric; v_old_anchor boolean;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  -- 6dp, matching the engine's own storage grain rather than the old 2dp/4dp
  v_rating := round(greatest(0.0, least(7.0, p_rating)), 6);
  v_sigma  := round(greatest(0.12, least(1.0, p_sigma)), 6);
  select coalesce(rating, coalesce(level, 0)), coalesce(sigma, 0.95), coalesce(is_anchor, false)
    into v_old_rating, v_old_sigma, v_old_anchor
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = round(v_rating, 2),
    tier = public.tier_from_level(v_rating),
    elo = greatest(800, least(2200, (800 + v_rating * 200)::int)),
    sigma = v_sigma, is_anchor = coalesce(p_is_anchor, false),
    competitive_matches = greatest(coalesce(competitive_matches, 0), 20),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta, engine_version)
  values (p_player_id, null, round(v_old_rating, 2), round(v_rating, 2),
     v_old_rating, v_rating, v_old_sigma, v_sigma,
     round(v_rating - v_old_rating, 6), 'admin');
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid,
    case when coalesce(p_is_anchor, false) then 'set_anchor_rating' else 'leveling_session' end,
    'profile', p_player_id,
    jsonb_build_object('rating', v_old_rating, 'sigma', v_old_sigma, 'is_anchor', v_old_anchor),
    jsonb_build_object('rating', v_rating,     'sigma', v_sigma,     'is_anchor', coalesce(p_is_anchor, false)),
    p_notes);
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 12. NOT IN THIS DELTA, on purpose: two admin surfaces carry their own copy
--     of the confidence rule, each buried inside a large function this change
--     otherwise has no business rewriting.
--
--       * admin_players_console  — `coalesce(p.is_provisional, cm < 5)`. The
--         coalesce fallback only fires on a database where the generated
--         column does not exist, so it is dead on live.
--       * admin_season_player    — `(v_sigma > 0.40 or v_cm < 5)`, computed
--         from scratch and therefore genuinely stale.
--
--     Both are display-only (a "Provisional" chip in the console — no money,
--     no rating, no gate), and both are corrected in
--     supabase/migration_player_app.sql, which is re-run on live. Flagged here
--     so the discrepancy is a decision on the record rather than an oversight.
-- ---------------------------------------------------------------------------

grant execute on function public._settle_rating(uuid)       to authenticated;
grant execute on function public.admin_set_player_rating(uuid, int) to authenticated;
grant execute on function public.admin_set_rating(uuid, numeric, numeric, boolean, text) to authenticated;

notify pgrst, 'reload schema';
