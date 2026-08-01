-- ============================================================================
-- SEASON — FIND ANY PLAYER FROM THE CONSOLE  (2026-08-01)
--
-- Follows 2026-08-01_season_leaderboards.sql and _season_player_detail.sql.
--
-- The standings are derived from the points ledger, so a season that has just
-- started lists nobody — and with nobody to tap there was no way into a
-- player's record or to award them anything. This search covers EVERY player,
-- scoring or not, and reports where they currently stand.
--
-- Safe to re-run.
-- ============================================================================

create or replace function public.admin_season_find_players(
  p_season_id uuid, p_term text default null, p_limit int default 25)
returns table (
  player_id uuid, name text, avatar_url text, tier text,
  pts int, rank int, scoring boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_term text := btrim(coalesce(p_term, ''));
begin
  if not public._is_admin() then return; end if;
  return query
    with st as (
      select s.player_id, s.pts, s.rank from public.season_standings(p_season_id) s
    )
    select p.id,
           coalesce(p.name, 'Player'),
           p.avatar_url,
           coalesce(p.tier, 'bronze'),
           coalesce(st.pts, 0)::int,
           st.rank,
           (st.player_id is not null)
      from public.profiles p
      left join st on st.player_id = p.id
     where (
             v_term = ''
             or p.name ilike '%' || v_term || '%'
             or coalesce(p.username, '') ilike '%' || v_term || '%'
           )
     -- players already on the board first, then everyone else by name
     order by (st.rank is null), st.rank nulls last, p.name nulls last
     limit greatest(1, least(100, coalesce(p_limit, 25)));
end $$;
grant execute on function public.admin_season_find_players(uuid, text, int) to authenticated;

notify pgrst, 'reload schema';
