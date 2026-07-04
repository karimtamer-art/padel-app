-- 2026-07-02 — Rating engine v2 (Playtomic-style).
--
-- Native 0.00–7.00 `rating` becomes the source of truth (was integer ELO).
-- Core = Elo, plus Glicko-style uncertainty (sigma) driving the K-factor, an
-- opponent-reliability discount, margin-of-victory weighting, and doubles team
-- averaging. This SQL is the RUNTIME AUTHORITY and MUST stay identical to the
-- reference implementation in lib/backend/models/rating_engine.dart (unit tests
-- pin golden vectors). All rating writes remain server-side / SECURITY DEFINER.
--
-- `level` is kept as a display mirror of `rating` (level := rating) so every
-- existing read of profiles.level / the Division mapping keeps working.
-- Idempotent + safe to re-run.

-- ── 1. profiles: new rating-model columns ─────────────────────────────────
alter table public.profiles
  add column if not exists rating       numeric(3,2),
  add column if not exists sigma        numeric not null default 0.85,
  add column if not exists is_anchor    boolean not null default false,
  add column if not exists competitive_matches int not null default 0,
  add column if not exists last_competitive_match_at timestamptz;

-- reliability % and provisional flag derive from the two stored columns above.
alter table public.profiles
  add column if not exists reliability numeric
    generated always as (round((1 - sigma / 1.0) * 100, 0)) stored;
alter table public.profiles
  add column if not exists is_provisional boolean
    generated always as (sigma > 0.40 or competitive_matches < 10) stored;

-- keep sigma within the spec band [0.12, 1.0]
do $$ begin
  alter table public.profiles
    add constraint profiles_sigma_range check (sigma >= 0.12 and sigma <= 1.0);
exception when duplicate_object then null; end $$;

-- ── 2. matches: idempotency guard for settlement ──────────────────────────
alter table public.matches
  add column if not exists rating_applied boolean not null default false;

-- ── 3. ranking_history doubles as the spec's rating_history ───────────────
alter table public.ranking_history
  add column if not exists rating_before numeric,
  add column if not exists rating_after  numeric,
  add column if not exists sigma_before  numeric,
  add column if not exists sigma_after   numeric,
  add column if not exists delta         numeric;

-- ── 4. One-time backfill of existing players ──────────────────────────────
-- rating = current level (unchanged number); sigma = max(0.12, 0.92^n) with
-- n = competitive matches played; counters + last-played from history.
-- Guarded via app_settings so re-running the migration never resets live sigma.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'rating_v2_backfilled') then
    update public.profiles p set
      competitive_matches = coalesce((
        select count(*) from public.ranking_history h
         where h.profile_id = p.id and h.match_id is not null), 0);

    update public.profiles p set
      rating = round(coalesce(level, public.level_from_elo(coalesce(elo, 1000)))::numeric, 2),
      last_competitive_match_at = (
        select max(h.created_at) from public.ranking_history h
         where h.profile_id = p.id and h.match_id is not null);

    update public.profiles p set
      sigma = greatest(0.12, round(power(0.92, competitive_matches)::numeric, 4));

    -- mirror level from the new rating and refresh tier
    update public.profiles p set
      level = rating,
      tier  = public.tier_from_level(rating)
      where rating is not null;

    insert into public.app_settings(key, value) values ('rating_v2_backfilled', 'true')
      on conflict (key) do nothing;
  end if;
end $$;

-- ── 5. Set-score parser (mirrors parseSetGames in Dart) ───────────────────
-- Sums games per team from a team-A-perspective string like '6-4,3-6,7-6'.
-- A match tie-break set (any side >= 10, e.g. '10-8') counts as ONE game to
-- its winner so it doesn't dwarf the games ratio.
create or replace function public._parse_set_games(p_score text)
returns table(a int, b int)
language plpgsql immutable as $$
declare
  v_set text; v_parts text[]; v_a int; v_b int; ta int := 0; tb int := 0;
begin
  a := 0; b := 0;
  if p_score is null or btrim(p_score) = '' then return next; return; end if;
  foreach v_set in array string_to_array(p_score, ',') loop
    v_parts := string_to_array(btrim(v_set), '-');
    if array_length(v_parts, 1) <> 2 then continue; end if;
    if btrim(v_parts[1]) !~ '^\d+$' or btrim(v_parts[2]) !~ '^\d+$' then continue; end if;
    v_a := btrim(v_parts[1])::int;
    v_b := btrim(v_parts[2])::int;
    if v_a >= 10 or v_b >= 10 then
      if v_a > v_b then ta := ta + 1; elsif v_b > v_a then tb := tb + 1; end if;
    else
      ta := ta + v_a; tb := tb + v_b;
    end if;
  end loop;
  a := ta; b := tb; return next;
end $$;

-- ── 6. Settlement engine — mirrors RatingEngine.settleMatch exactly ───────
create or replace function public._settle_rating(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_winner   text;
  v_score_a  text;
  v_applied  boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric;
  v_ratio_a numeric; v_ratio_b numeric;
  v_s_a numeric; v_s_b numeric;
  v_w_a numeric; v_w_b numeric;
  r record;
  v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric;
begin
  select winner_team, score_team_a, coalesce(rating_applied, false)
    into v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;
  if v_applied then return; end if;          -- idempotency: already settled
  if v_winner is null then return; end if;    -- nothing to settle

  select a, b into v_ga, v_gb from public._parse_set_games(v_score_a);
  v_ga := coalesce(v_ga, 0); v_gb := coalesce(v_gb, 0);
  v_tot := v_ga + v_gb;

  select avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'a'),
         avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'b'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'a'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 2.0); v_avg_b := coalesce(v_avg_b, 2.0);
  v_sig_a := coalesce(v_sig_a, 0.85); v_sig_b := coalesce(v_sig_b, 0.85);

  -- Expected scores (s = 1.0)
  v_e_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / 1.0));
  v_e_b := 1.0 / (1.0 + power(10.0, (v_avg_a - v_avg_b) / 1.0));

  -- Score signal S = 0.7*result + 0.3*games_ratio  (result: win 1 / loss 0)
  v_ratio_a := case when v_tot = 0 then 0.5 else v_ga::numeric / v_tot end;
  v_ratio_b := case when v_tot = 0 then 0.5 else v_gb::numeric / v_tot end;
  v_s_a := 0.7 * (case when v_winner = 'a' then 1 else 0 end) + 0.3 * v_ratio_a;
  v_s_b := 0.7 * (case when v_winner = 'b' then 1 else 0 end) + 0.3 * v_ratio_b;

  -- Opponent-reliability weight W_opp = 0.5 + 0.5*(1 - avg_sigma_opponents)
  v_w_a := 0.5 + 0.5 * (1 - v_sig_b);
  v_w_b := 0.5 + 0.5 * (1 - v_sig_a);

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
    if r.cm < 5 then v_k := v_k * 1.5; end if;         -- placement boost

    v_delta := v_k * v_w * (v_s - v_e);
    if r.anchor then v_delta := greatest(-0.05, least(0.05, v_delta)); end if;

    v_after := round(greatest(0.0, least(7.0, r.rating + v_delta)), 2);
    v_sig_after := greatest(0.12, round(r.sigma * 0.92, 4));

    update profiles set
      rating = v_after,
      level  = v_after,                       -- display mirror
      tier   = public.tier_from_level(v_after),
      sigma  = v_sig_after,
      competitive_matches = r.cm + 1,
      last_competitive_match_at = now()
    where id = r.player_id;

    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta)
    values
      (r.player_id, p_match_id, r.rating, v_after,
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, 2));
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;

-- ── 7. Repoint the score flow at the new engine ───────────────────────────
-- Competitive ('ranked') matches settle on confirmation; casual matches never
-- touch rating (competitive-only, per spec).
create or replace function public.submit_match_result(
  p_match_id uuid, p_score_a text, p_score_b text, p_winner text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_type text; v_status text; v_sched timestamptz;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_winner not in ('a','b') then return 'Invalid winner.'; end if;
  if not exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return 'Only players in this match can submit a score.';
  end if;

  select match_type, status, scheduled_at into v_type, v_status, v_sched
    from matches where id = p_match_id for update;
  if v_status = 'completed' then return 'Result already confirmed.'; end if;
  if v_sched > now() then return 'Score entry opens after the match time.'; end if;

  update matches set
    score_team_a = p_score_a,
    score_team_b = p_score_b,
    winner_team  = p_winner,
    result_submitted_by = v_uid,
    result_submitted_at = now(),
    status = case when v_type = 'ranked' then 'pending_confirm' else 'completed' end
  where id = p_match_id;

  -- casual matches are not rated; ranked matches wait for opponent confirmation
  return null;
end $$;

create or replace function public.confirm_match_result(p_match_id uuid, p_confirm boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_submitter uuid; v_status text; v_sub_team text; v_my_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select status, result_submitted_by into v_status, v_submitter
    from matches where id = p_match_id for update;
  if v_status <> 'pending_confirm' then return 'Nothing awaiting confirmation.'; end if;

  select team into v_sub_team from match_players where match_id = p_match_id and player_id = v_submitter;
  select team into v_my_team  from match_players where match_id = p_match_id and player_id = v_uid;
  if v_my_team is null then return 'Only players in this match can confirm.'; end if;
  if v_my_team = v_sub_team then return 'A player on the other team must confirm.'; end if;

  if p_confirm then
    update matches set status = 'completed' where id = p_match_id;
    perform public._settle_rating(p_match_id);
  else
    update matches set status = 'disputed', winner_team = null,
      score_team_a = null, score_team_b = null,
      result_submitted_by = null, result_submitted_at = null
    where id = p_match_id;
  end if;
  return null;
end $$;

-- ── 8. Admin seed → rating (keeps the (uuid,int elo) signature) ───────────
-- Maps the seed ELO to a rating, sets a confident sigma (0.30) and marks the
-- player established (competitive_matches >= 10) so they aren't provisional.
create or replace function public.admin_set_player_rating(p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_rating numeric; v_rating numeric;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  v_rating := public.level_from_elo(greatest(800, least(2200, p_elo)));
  select coalesce(rating, coalesce(level, 0)) into v_old_rating
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;

  update public.profiles set
    rating = v_rating,
    level  = v_rating,
    tier   = public.tier_from_level(v_rating),
    elo    = greatest(800, least(2200, p_elo)),
    sigma  = 0.30,
    competitive_matches = greatest(coalesce(competitive_matches, 0), 10),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;

  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta)
  values (p_player_id, null, v_old_rating, v_rating,
     v_old_rating, v_rating, null, 0.30, round(v_rating - v_old_rating, 2));
  return null;
end $$;

-- ── 9. Inactivity: sigma idle-growth + gentle rating decay ────────────────
-- Weekly. (a) Idle > 14 days: sigma = min(0.60, sigma + 0.01). (b) Idle > 60
-- days: rating -= 0.04, floored at the current division floor and never below
-- 1.0. Placement players (competitive_matches < 5) are never decayed.
create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_count int := 0;
  r record;
  v_floor numeric; v_new numeric;
begin
  -- (a) uncertainty grows with inactivity
  update public.profiles p set
    sigma = least(0.60, sigma + 0.01)
  where coalesce(p.is_admin, false) = false
    and sigma < 0.60
    and (p.last_competitive_match_at is null
         or p.last_competitive_match_at < now() - interval '14 days');

  -- (b) gentle rating decay after 60 days idle
  for r in
    select p.id, coalesce(p.rating, coalesce(p.level, 0))::numeric as rating
      from profiles p
     where coalesce(p.is_admin, false) = false
       and coalesce(p.competitive_matches, 0) >= 5
       and coalesce(p.rating, coalesce(p.level, 0)) > 1.0
       and (p.last_competitive_match_at is null
            or p.last_competitive_match_at < now() - interval '60 days')
  loop
    v_floor := case
      when r.rating >= 5.0 then 5.0
      when r.rating >= 3.5 then 3.5
      when r.rating >= 2.0 then 2.0
      else 0.0 end;
    v_new := greatest(1.0, greatest(v_floor, round(r.rating - 0.04, 2)));
    if v_new < r.rating then
      update profiles set rating = v_new, level = v_new,
        tier = public.tier_from_level(v_new)
      where id = r.id;
      insert into ranking_history
        (profile_id, match_id, level_before, level_after,
         rating_before, rating_after, delta)
      values (r.id, null, r.rating, v_new, r.rating, v_new, round(v_new - r.rating, 2));
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;
