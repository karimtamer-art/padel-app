-- 2026-07-03 — "Why did my level move" breakdown data.
--
-- profiles RLS is read-own (a player can't read opponents' ratings), so the
-- post-match breakdown must read only the player's OWN ranking_history rows.
-- Record the opponent-average rating + games for/against + won flag at
-- settlement time so the client can render the breakdown with no cross-user
-- reads. Adds columns + refreshes _settle_rating to populate them.
-- Safe to re-run.

alter table public.ranking_history
  add column if not exists opp_avg_rating numeric,
  add column if not exists games_for      int,
  add column if not exists games_against  int,
  add column if not exists won            boolean;

create or replace function public._settle_rating(p_match_id uuid)
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
      last_competitive_match_at = now()
    where id = r.player_id;
    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta,
       opp_avg_rating, games_for, games_against, won)
    values (r.player_id, p_match_id, r.rating, v_after,
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, 2),
       round((case when r.team = 'a' then v_avg_b else v_avg_a end)::numeric, 2),
       case when r.team = 'a' then v_ga else v_gb end,
       case when r.team = 'a' then v_gb else v_ga end,
       (r.team = v_winner));
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;
