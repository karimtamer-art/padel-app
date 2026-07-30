-- ============================================================================
-- 2026-07-30 — Community member mini-profile card
--
-- Player Members tab: tapping a member opens a mini profile (tier, community
-- rank, Elo / played / win rate, hand/side, join date). This RPC returns all of
-- it in one call — profile fields + played/wins from settled matches + a
-- community rank by rating.
--
-- Safe to re-run. After: notify pgrst, 'reload schema';
-- ============================================================================

create or replace function public.community_member_card(p_community_id uuid, p_player_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_played int; v_wins int; v_rank int; v_joined timestamptz; v_res jsonb;
begin
  select count(*), count(*) filter (where mp.team = m.winner_team)
    into v_played, v_wins
  from public.match_players mp
  join public.matches m on m.id = mp.match_id
  where mp.player_id = p_player_id
    and m.status = 'completed' and m.winner_team is not null;

  select rnk into v_rank from (
    select cm.player_id,
           row_number() over (order by coalesce(pr.rating, pr.level, 0) desc) rnk
      from public.community_members cm
      join public.profiles pr on pr.id = cm.player_id
     where cm.community_id = p_community_id
  ) t where t.player_id = p_player_id;

  select joined_at into v_joined from public.community_members
   where community_id = p_community_id and player_id = p_player_id;

  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'tier', p.tier,
    'elo', p.elo, 'level', p.level, 'city', p.city,
    'hand', p.preferred_hand, 'side', p.preferred_court_side,
    'joined', v_joined, 'played', coalesce(v_played, 0),
    'wins', coalesce(v_wins, 0), 'rank', v_rank)
    into v_res from public.profiles p where p.id = p_player_id;
  return v_res;
end $$;
grant execute on function public.community_member_card(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
