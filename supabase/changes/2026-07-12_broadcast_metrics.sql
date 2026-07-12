-- ============================================================================
-- Broadcast metrics on organizer overview (2026-07-12). Run once. Idempotent.
--
-- Adds `largest_event` (biggest entrant count across the organizer's events) and
-- `open_rate` (% of the organizer's community announcements that recipients have
-- read — derived from the notifications.read flag) to organizer_overview().
-- ============================================================================

create or replace function public.organizer_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return json_build_object('error', 'not_organizer');
  end if;
  return json_build_object(
    'tournaments', (select count(*) from tournaments where organizer_id = v_uid),
    'accepting',   (select count(*) from tournaments
                     where organizer_id = v_uid and status in ('open','upcoming')),
    'entrants',    (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'reach',       (select count(distinct te.player_id) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'fees',        (select coalesce(sum(coalesce(paid_amount,0)),0) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'paid'),
    'to_verify',   (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'pending'),
    'largest_event', (select coalesce(max(cnt), 0) from (
                       select te.tournament_id, count(*) cnt from tournament_entries te
                        where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                          and te.status not in ('withdrawn','cancelled')
                        group by te.tournament_id) x),
    'open_rate',   (select case when count(*) = 0 then 0
                       else round(100.0 * count(*) filter (where n.read) / count(*)) end
                     from notifications n
                    where n.type = 'community'
                      and n.data->>'community_id' in
                          (select id::text from communities where organizer_id = v_uid))
  );
end $$;
grant execute on function public.organizer_overview() to authenticated;

notify pgrst, 'reload schema';
