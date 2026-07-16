-- 2026-07-16 · Admin Matches console (Phase 1) — rich list + reason-logged remove
--
-- admin_matches_console(): one admin-gated read returning everything the
-- redesigned console needs — court, host, players (name+team), score, winner,
-- min-ELO, player count, ELO delta — as JSON. admin_cancel_match() now takes a
-- reason + note and writes the removal to audit_log (still a soft cancel; no
-- hard delete, no ELO revert — those are later phases). Idempotent; folded into
-- migration_player_app.sql.

create or replace function public.admin_matches_console(p_limit int default 200)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(x order by x.scheduled_at desc nulls last), '[]'::json)
    from (
      select
        m.id, m.status, m.match_type, m.scheduled_at, m.min_elo, m.winner_team,
        m.score_team_a, m.score_team_b,
        c.venue_name, c.name as court_name,
        (select p.name from public.profiles p where p.id = m.created_by)            as host,
        (select p.name from public.profiles p where p.id = m.result_submitted_by)   as submitted_by,
        (select count(*)::int from public.match_players mp where mp.match_id = m.id) as player_count,
        (select coalesce(json_agg(json_build_object('name', pr.name, 'team', mp.team) order by mp.team), '[]'::json)
           from public.match_players mp join public.profiles pr on pr.id = mp.player_id
          where mp.match_id = m.id)                                                  as players,
        (select max(rh.delta) from public.ranking_history rh where rh.match_id = m.id) as elo_delta
      from public.matches m
      left join public.courts c on c.id = m.court_id
      order by m.scheduled_at desc nulls last
      limit p_limit
    ) x
  );
end $$;
grant execute on function public.admin_matches_console(int) to authenticated;

-- Remove with a reason + note, logged to the audit trail (still a soft cancel).
drop function if exists public.admin_cancel_match(uuid);
create or replace function public.admin_cancel_match(
  p_match_id uuid, p_reason text default null, p_note text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old text;
begin
  if not public._is_admin() then return 'Admins only.'; end if;
  select status into v_old from public.matches where id = p_match_id;
  if not found then return 'Match not found.'; end if;

  update public.matches set status = 'cancelled' where id = p_match_id;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'remove_match', 'match', p_match_id,
          jsonb_build_object('status', v_old),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason),
          p_note);
  return null;
end $$;
grant execute on function public.admin_cancel_match(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
