-- ============================================================
-- Incremental change · 2026-06-16
-- Admin seeding of a player's rating (cold-start) — server-side, consistent
-- ------------------------------------------------------------
-- Brand-new app: everyone starts at ELO 1000 / unranked, so rank-based
-- matchmaking has no signal. Since this community came from Discord (admins
-- know who's who), admins seed known players' levels. This RPC keeps the write
-- INSIDE Postgres (anti-cheat boundary — rule #2) and keeps everything
-- consistent: it derives level + tier from the ELO and marks the player as
-- ranked (placement_played = 5) so they leave the unranked state. Their first
-- real ranked matches still use K=64 (the seed row has match_id NULL so it
-- doesn't count toward games played), so a wrong seed self-corrects fast.
-- Also folded into the canonical migration. Idempotent.
-- ============================================================

create or replace function public.admin_set_player_rating(
  p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_elo   int;
  v_old_level numeric;
  v_elo       int;
  v_level     numeric;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  v_elo := greatest(800, least(2200, p_elo));
  select coalesce(elo, 1000), coalesce(level, 0)
    into v_old_elo, v_old_level
  from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;

  v_level := public.level_from_elo(v_elo);
  update public.profiles set
    elo = v_elo,
    level = v_level,
    tier = public.tier_from_level(v_level),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;

  -- audit row (match_id NULL → not counted as a played ranked match)
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after, elo_before, elo_after)
  values (p_player_id, null, v_old_level, v_level, v_old_elo, v_elo);
  return null;
end $$;

grant execute on function public.admin_set_player_rating(uuid, int) to authenticated;

notify pgrst, 'reload schema';
