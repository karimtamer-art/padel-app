-- 2026-07-16 · Admin Matches Phase 2 — resolve a disputed match
--
-- An admin finalizes a disputed (or pending) match: pick the winning team, set
-- the final score, add a note. Sets the result, runs _settle_rating (ELO recalc
-- for all four players, idempotent), notifies every player, and logs to
-- audit_log. Disputes clear the stored score, so the admin enters it fresh; the
-- score is stored the same way the app stores results. Idempotent; folded into
-- migration_player_app.sql.

create or replace function public.admin_resolve_match(
  p_match_id uuid,
  p_winner   text,
  p_score_a  text default null,
  p_score_b  text default null,
  p_note     text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if not public._is_admin() then return 'Admins only.'; end if;
  if p_winner not in ('a','b') then return 'Pick the winning team.'; end if;

  select status into v_status from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status not in ('disputed','pending_confirm') then
    return 'This match is not awaiting resolution.';
  end if;

  update public.matches set
    winner_team         = p_winner,
    score_team_a        = nullif(btrim(coalesce(p_score_a, '')), ''),
    score_team_b        = nullif(btrim(coalesce(p_score_b, '')), ''),
    result_submitted_by = coalesce(result_submitted_by, v_uid),
    result_submitted_at = now(),
    status              = 'completed'
  where id = p_match_id;

  -- ELO recalc for all players (idempotent via matches.rating_applied).
  perform public._settle_rating(p_match_id);

  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Dispute resolved',
         'An admin finalized your match result — your rating has been updated.',
         jsonb_build_object('match_id', p_match_id)
    from public.match_players mp where mp.match_id = p_match_id;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'resolve_match', 'match', p_match_id,
          jsonb_build_object('status', v_status),
          jsonb_build_object('status', 'completed', 'winner', p_winner,
                             'score_a', p_score_a, 'score_b', p_score_b),
          p_note);
  return null;
end $$;
grant execute on function public.admin_resolve_match(uuid, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
