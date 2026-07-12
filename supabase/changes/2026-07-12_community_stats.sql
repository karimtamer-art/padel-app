-- ============================================================================
-- Organizer community stats (2026-07-12). Run once. Idempotent.
--
-- KPI tiles + member skill-tier breakdown for the organizer's Community console:
-- members, unanswered inbox threads, events this week, matches made all-time,
-- and a Bronze-Silver / Gold / Elite member split (by profiles.level).
-- ============================================================================

create or replace function public.organizer_community_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid; v_res jsonb;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return '{}'::jsonb;
  end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return '{}'::jsonb; end if;
  select jsonb_build_object(
    'members', (select count(*) from public.community_members where community_id = v_cid),
    'inbox_unread', (
      select count(*) from (
        select cm.member_id,
               (array_agg(cm.sender_role order by cm.created_at desc))[1] as last_role
          from public.community_messages cm
         where cm.community_id = v_cid
         group by cm.member_id
      ) t where t.last_role = 'member'),
    'events_week', (
      select count(*) from public.tournaments
       where organizer_id = v_uid and start_date is not null
         and start_date between current_date and current_date + 7),
    'matches_made', (
      select count(*) from public.tournament_matches m
       join public.tournaments t on t.id = m.tournament_id
       where t.organizer_id = v_uid and m.winner_entry is not null),
    'tier_bronze', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce(p.level, 0) < 3.5),
    'tier_gold', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce(p.level, 0) >= 3.5 and coalesce(p.level, 0) < 5.0),
    'tier_elite', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce(p.level, 0) >= 5.0)
  ) into v_res;
  return v_res;
end $$;
grant execute on function public.organizer_community_stats() to authenticated;

notify pgrst, 'reload schema';
