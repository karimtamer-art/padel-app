-- 2026-07-17 · Wire tournament results into the rating engine.
--
-- Tournaments are RATED by default (per-event `rated` toggle to opt a
-- prize-only/social event out). When an organizer finalizes, every decided
-- tournament match with a clean 2v2 of real profiles is materialized into a
-- normal completed `matches` + `match_players` row and settled by the existing
-- _settle_rating — so tournaments feed the same 0–7 rating engine (doubles
-- averaging, margin-of-victory, sigma, placement, ranking_history).
--
-- Idempotent: matches.tournament_match_id (unique) dedupes materialization and
-- tournaments.rating_applied guards the one-shot finalize. Also folded into
-- migration_player_app.sql.

alter table public.tournaments add column if not exists rated boolean not null default true;
alter table public.tournaments add column if not exists rating_applied boolean not null default false;

alter table public.matches
  add column if not exists tournament_match_id uuid references public.tournament_matches(id) on delete set null;
create unique index if not exists matches_tournament_match_id_key
  on public.matches (tournament_match_id) where tournament_match_id is not null;

-- Finalize a tournament: apply ratings for every decided match, then mark it
-- completed. One-shot (rating_applied). Only the owner/admin may call it.
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

  -- Don't finalize while matches are still pending a result.
  if exists (select 1 from public.tournament_matches
              where tournament_id = p_tournament_id and winner_entry is null) then
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
    -- Rate only clean 2v2s of four distinct real profiles.
    if m.a1 is null or m.a2 is null or m.b1 is null or m.b2 is null then continue; end if;
    if m.a1 = m.a2 or m.b1 = m.b2 then continue; end if;
    if m.a1 in (m.b1, m.b2) or m.a2 in (m.b1, m.b2) then continue; end if;
    if exists (select 1 from public.matches where tournament_match_id = m.id) then continue; end if;

    v_wteam := case when m.winner_entry = m.entry1 then 'a' else 'b' end;
    insert into public.matches
      (status, match_type, scheduled_at, created_by, is_private, min_elo,
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

  update public.tournaments set rating_applied = true, status = 'completed'
   where id = p_tournament_id;
  return v_n || ' match' || (case when v_n = 1 then '' else 'es' end) || ' rated.';
end $$;
grant execute on function public.finalize_tournament(uuid) to authenticated;

notify pgrst, 'reload schema';
