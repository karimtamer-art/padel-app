-- 2026-07-03 — Admin rating controls for engine v2 (anchors + leveling sessions).
--
-- One SECURITY DEFINER RPC the admin console calls to hand-set a player's 0..7
-- rating with an explicit sigma and anchor flag, writing both a ranking_history
-- row (match_id null) and an audit_log entry. Two admin actions map onto it:
--   • Mark anchor:      is_anchor=true,  sigma=0.30 (barely moves in settlement)
--   • Leveling session: is_anchor=false, sigma=0.50 (coach-assigned, self-tunes)
-- Safe to re-run.

create or replace function public.admin_set_rating(
  p_player_id uuid,
  p_rating    numeric,
  p_sigma     numeric,
  p_is_anchor boolean default false,
  p_notes     text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_rating numeric; v_sigma numeric;
  v_old_rating numeric; v_old_sigma numeric; v_old_anchor boolean;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  v_rating := round(greatest(0.0, least(7.0, p_rating)), 2);
  v_sigma  := round(greatest(0.12, least(1.0, p_sigma)), 4);

  select coalesce(rating, coalesce(level, 0)), coalesce(sigma, 0.85), coalesce(is_anchor, false)
    into v_old_rating, v_old_sigma, v_old_anchor
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;

  update public.profiles set
    rating = v_rating,
    level  = v_rating,
    tier   = public.tier_from_level(v_rating),
    elo    = greatest(800, least(2200, (800 + v_rating * 200)::int)),
    sigma  = v_sigma,
    is_anchor = coalesce(p_is_anchor, false),
    -- mark established so an admin-set player isn't flagged provisional
    competitive_matches = greatest(coalesce(competitive_matches, 0), 10),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;

  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta)
  values (p_player_id, null, v_old_rating, v_rating,
     v_old_rating, v_rating, v_old_sigma, v_sigma, round(v_rating - v_old_rating, 2));

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
grant execute on function public.admin_set_rating(uuid, numeric, numeric, boolean, text) to authenticated;
