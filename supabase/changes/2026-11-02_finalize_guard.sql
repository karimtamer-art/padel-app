-- 2026-11-02: finalize_tournament no longer waits for a row that can't be played.
--
-- _advance_winner always inserts a next round, so the winner of a final gets a row
-- of their own with one side empty and no winner. The guard counted that row as an
-- unfinished match, so every generate_draw event answered "Finish all current
-- matches before finalizing": no ratings, no season points, never completed.
--
-- Only the guard changes: a row counts only if both sides are set. A real unplayed
-- match still blocks finalizing.
--
-- After this runs, finalizing a stuck event DOES settle its ratings and award its
-- season points. Nothing does that by itself; it takes an organiser pressing
-- Finalize. This lists the events that were stuck (read-only):
--
--   select t.id, t.name, t.status from tournaments t
--    where t.rated and not coalesce(t.rating_applied, false)
--      and exists (select 1 from tournament_matches m
--                   where m.tournament_id = t.id and m.bracket = 'wb'
--                     and m.winner_entry is not null)
--      and not exists (select 1 from tournament_matches m
--                       where m.tournament_id = t.id and m.winner_entry is null
--                         and m.entry1 is not null and m.entry2 is not null);
--
-- Safe to re-run. Also edited in place in migration_player_app.sql.

create or replace function public.finalize_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_rated boolean; v_applied boolean; v_owner uuid;
  m record; v_wteam text; v_mid uuid; v_n int := 0;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select rated, coalesce(rating_applied, false), organizer_id
    into v_rated, v_applied, v_owner
    from public.tournaments where id = p_tournament_id;
  if not found then return 'Tournament not found.'; end if;
  if v_applied then return 'Ratings already applied for this tournament.'; end if;

  if not v_rated then
    update public.tournaments set status = 'completed' where id = p_tournament_id;
    return 'Marked complete — this tournament is not rated.';
  end if;

  if exists (select 1 from public.tournament_matches
              where tournament_id = p_tournament_id and winner_entry is null
                and entry1 is not null and entry2 is not null) then
    return 'Finish all current matches before finalizing.';
  end if;
  if not exists (select 1 from public.tournament_matches
                  where tournament_id = p_tournament_id and winner_entry is not null) then
    return 'No completed matches to rate yet.';
  end if;

  for m in
    select tm.id, tm.entry1, tm.entry2, tm.winner_entry, tm.score,
           e1.player_id as a1, e1.partner_id as a2,
           e2.player_id as b1, e2.partner_id as b2
      from public.tournament_matches tm
      join public.tournament_entries e1 on e1.id = tm.entry1
      join public.tournament_entries e2 on e2.id = tm.entry2
     where tm.tournament_id = p_tournament_id
       and tm.winner_entry is not null
  loop
    -- Rate only clean 2v2s of four real profiles (skip guests — no profile).
    if m.a1 is null or m.a2 is null or m.b1 is null or m.b2 is null then continue; end if;
    if m.a1 = m.a2 or m.b1 = m.b2 then continue; end if;
    if m.a1 in (m.b1, m.b2) or m.a2 in (m.b1, m.b2) then continue; end if;
    if exists (select 1 from public.matches where tournament_match_id = m.id) then continue; end if;

    v_wteam := case when m.winner_entry = m.entry1 then 'a' else 'b' end;
    insert into public.matches
      (status, match_type, scheduled_at, created_by, is_private, min_rating,
       winner_team, score_team_a, rating_applied, invite_code, tournament_match_id)
    values
      ('completed', 'ranked', now(), coalesce(v_owner, m.a1), true, 0,
       v_wteam, nullif(m.score, ''), false, 'TRN-' || replace(m.id::text, '-', ''), m.id)
    returning id into v_mid;

    insert into public.match_players (match_id, player_id, team) values
      (v_mid, m.a1, 'a'), (v_mid, m.a2, 'a'),
      (v_mid, m.b1, 'b'), (v_mid, m.b2, 'b');

    perform public._settle_rating(v_mid);
    v_n := v_n + 1;
  end loop;

  -- title + podium season points (separate from the per-match points above)
  perform public._award_tournament_season_points(p_tournament_id);

  update public.tournaments set rating_applied = true, status = 'completed'
   where id = p_tournament_id;
  return v_n || ' match' || (case when v_n = 1 then '' else 'es' end) || ' rated.';
end $$;

-- Check it landed: must return true. Don't trust "Success" alone.
select pg_get_functiondef('public.finalize_tournament(uuid)'::regprocedure)
       like '%winner_entry is null%and entry1 is not null and entry2 is not null%'
       as finalize_guard_applied;
