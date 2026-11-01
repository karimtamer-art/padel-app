-- PROPOSAL, NOT APPLIED. Double-elimination grand final: one match, no reset.
-- Lives outside supabase/changes/ on purpose until approved. When approved it
-- moves to changes/, and these bodies replace the originals IN PLACE in
-- migration_player_app.sql (sql_raise_arity_test ratchets against duplicates).
--
-- Tested on an in-process Postgres against the real generate_draw etc.
-- Re-runnable: only create-or-replace, no data changes.

-- 1. A pair going into the losers bracket takes the first open seat, or starts a
--    new row. Used for BOTH routes in: dropping from winners and winning in losers.
--    Today losers winners follow slot/2 instead, which strands pairs in different
--    half-filled rows who can never meet (28-49% of simulated events). With one
--    rule for every arrival there is never more than one open seat.
create or replace function public._seat_in_losers(
  p_tid uuid, p_entry uuid, p_min_round int default 1)
returns void
language plpgsql security definer set search_path = public as $$
declare v_open record; v_round int; v_slot int;
begin
  select * into v_open
    from tournament_matches
   where tournament_id = p_tid and bracket = 'lb'
     and winner_entry is null and (entry1 is null or entry2 is null)
   order by round, slot
   limit 1
   for update;
  if found then
    if v_open.entry1 is null then
      update tournament_matches set entry1 = p_entry where id = v_open.id;
    else
      update tournament_matches set entry2 = p_entry where id = v_open.id;
    end if;
    return;
  end if;

  select greatest(coalesce(max(round), 1), p_min_round) into v_round
    from tournament_matches
   where tournament_id = p_tid and bracket = 'lb';
  select coalesce(max(slot) + 1, 0) into v_slot
    from tournament_matches
   where tournament_id = p_tid and bracket = 'lb' and round = v_round;
  insert into tournament_matches (tournament_id, bracket, round, slot, entry1)
  values (p_tid, 'lb', v_round, v_slot, p_entry);
end $$;

-- 2. Opens the grand final once each bracket has exactly one pair left and nothing
--    left to play. Those two pairs are the half-filled rows _advance_winner and
--    _seat_in_losers leave behind. Idempotent through the unique key.
--    `round` is one past the winners final, because
--    _award_tournament_season_points finds the champion through max(round).
create or replace function public._open_grand_final(p_tid uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_wb uuid; v_lb uuid; v_round int; v_n int;
begin
  if exists (select 1 from tournament_matches
              where tournament_id = p_tid and bracket in ('wb', 'lb')
                and winner_entry is null
                and entry1 is not null and entry2 is not null) then
    return;
  end if;

  select count(*), max(coalesce(entry1, entry2)::text)::uuid, max(round)
    into v_n, v_wb, v_round
    from tournament_matches
   where tournament_id = p_tid and bracket = 'wb' and winner_entry is null;
  if v_n <> 1 or v_wb is null then return; end if;

  select count(*), max(coalesce(entry1, entry2)::text)::uuid into v_n, v_lb
    from tournament_matches
   where tournament_id = p_tid and bracket = 'lb' and winner_entry is null;
  if v_n <> 1 or v_lb is null then return; end if;

  insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
  values (p_tid, 'gf', v_round, 0, v_wb, v_lb)
  on conflict (tournament_id, bracket, round, slot) do nothing;
end $$;

-- 3. record_bracket_winner: same checks; what changes is after the update.
create or replace function public.record_bracket_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_loser uuid;
  v_format text;
begin
  select * into m from tournament_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if m.winner_entry is not null then return 'Winner already recorded.'; end if;
  if p_winner not in (m.entry1, m.entry2) then return 'Winner must be one of the two pairs.'; end if;
  if m.entry1 is null or m.entry2 is null then return 'This match is still waiting for a pair.'; end if;

  v_loser := case when p_winner = m.entry1 then m.entry2 else m.entry1 end;

  update tournament_matches
     set winner_entry = p_winner, score = p_score
   where id = p_match_id;

  -- Single match, no reset: the grand final ends it, nobody advances or drops.
  if m.bracket = 'gf' then return null; end if;

  select format into v_format from tournaments where id = m.tournament_id;

  if v_format = 'double_elim' and m.bracket = 'lb' then
    perform public._seat_in_losers(m.tournament_id, p_winner, m.round + 1);
  else
    perform public._advance_winner(m.tournament_id, m.bracket, m.round, m.slot, p_winner);
  end if;

  if v_format = 'double_elim' then
    if m.bracket = 'wb' then
      perform public._seat_in_losers(m.tournament_id, v_loser);
    end if;
    perform public._open_grand_final(m.tournament_id);
  end if;

  return null;
end $$;

-- 4. finalize_tournament: one guard changes. A row with a missing side can't be
--    played, so it can't be what we're waiting for. That row always exists after
--    a final, so today the guard refuses EVERY generate_draw event. Everything
--    else in the body is unchanged.
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
