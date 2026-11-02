-- ROLLBACK for 2026-11-02_grand_final.sql. Only run this to undo it.
-- Restores arrival-order losers routing and the old podium rule, and removes the new
-- helpers. Any 'gf' row already created is left alone: if one exists, the console
-- still lists it, but recording it would advance a phantom round, so finish or
-- regenerate that event first. Check with:
--   select tournament_id from tournament_matches where bracket = 'gf';

create or replace function public.record_bracket_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_loser uuid;
  v_format text;
  v_lb_round int;
  v_lb_slot int;
  v_open record;
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

  select format into v_format from tournaments where id = m.tournament_id;

  -- advance the winner (round caps handled by simply creating next rounds;
  -- the very last match of a bracket just stores its winner)
  perform public._advance_winner(m.tournament_id, m.bracket, m.round, m.slot, p_winner);

  -- double-elim: drop the WB loser into the losers bracket
  if v_format = 'double_elim' and m.bracket = 'wb' then
    -- find an LB match with a free seat, else open a new one
    select * into v_open
      from tournament_matches
     where tournament_id = m.tournament_id and bracket = 'lb'
       and winner_entry is null and (entry1 is null or entry2 is null)
     order by round, slot
     limit 1;
    if found then
      if v_open.entry1 is null then
        update tournament_matches set entry1 = v_loser where id = v_open.id;
      else
        update tournament_matches set entry2 = v_loser where id = v_open.id;
      end if;
    else
      select coalesce(max(round), 0) into v_lb_round
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb';
      select coalesce(max(slot) + 1, 0) into v_lb_slot
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb'
         and round = greatest(v_lb_round, 1);
      insert into tournament_matches (tournament_id, bracket, round, slot, entry1)
      values (m.tournament_id, 'lb', greatest(v_lb_round, 1), v_lb_slot, v_loser);
    end if;
  end if;

  return null;
end $$;

create or replace function public._award_tournament_season_points(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; v_frozen boolean; v_title int; v_podium int;
  v_final_round int; f record; m record;
  v_champ uuid; v_runner uuid; v_region text; v_free boolean := false; v_finals int;
begin
  -- From the TOURNAMENT's region, not any player's: an event belongs to one
  -- market, and its title must not land in two ladders because a visitor
  -- entered. See changes/2026-09-26_seasons_per_region.sql.
  select coalesce(t.region_id, 'EG') into v_region
    from public.tournaments t where t.id = p_tournament_id;

  v_sid := public._live_season(v_region);
  if v_sid is null then return; end if;
  select s.frozen into v_frozen from public.seasons s where s.id = v_sid;
  if coalesce(v_frozen, false) then return; end if;

  select coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_win'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_podium'), 0)
    into v_title, v_podium;

  select max(tm.round) into v_final_round
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.winner_entry is not null;
  -- No wb/gf row: a Format Builder or console draw, which labels its rounds freely.
  -- The title needs one decided match labelled exactly Final in the last stage that
  -- has one. Anything else is left unawarded rather than guessed at: points can be
  -- added by hand, but a wrong champion is worse.
  if v_final_round is null then
    select tm.entry1, tm.entry2, tm.winner_entry, tm.bracket, tm.stage into f
      from public.tournament_matches tm
     where tm.tournament_id = p_tournament_id
       and lower(btrim(tm.bracket)) = 'final'
       and tm.winner_entry is not null
       and tm.entry1 is not null and tm.entry2 is not null
     order by tm.stage desc, tm.round desc
     limit 1;
    if not found then return; end if;
    select count(*) into v_finals
      from public.tournament_matches tm
     where tm.tournament_id = p_tournament_id
       and tm.stage = f.stage
       and lower(btrim(tm.bracket)) = 'final';
    if v_finals <> 1 then return; end if;
    v_free := true;
  end if;

  if not v_free then
  -- the final: champion + runner-up
  select tm.entry1, tm.entry2, tm.winner_entry into f
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.round = v_final_round and tm.winner_entry is not null
   order by tm.slot limit 1;
  if not found then return; end if;
  end if;

  v_champ  := f.winner_entry;
  v_runner := case when f.winner_entry = f.entry1 then f.entry2 else f.entry1 end;

  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_win', v_title, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_champ and v.pid is not null
  on conflict do nothing;

  -- podium: the runner-up plus everyone who lost a semi-final
  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_runner and v.pid is not null
  on conflict do nothing;

  -- Free-label draw: the podium is the runner-up plus whoever lost a semi-final in
  -- the same stage. A bye has no loser, so it adds nobody.
  if v_free then
    insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
    select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
      from public.tournament_matches s
      join public.tournament_entries e
        on e.id = case when s.winner_entry = s.entry1 then s.entry2 else s.entry1 end,
           lateral (values (e.player_id), (e.partner_id)) as v(pid)
     where s.tournament_id = p_tournament_id
       and s.stage = f.stage
       and lower(btrim(s.bracket)) like 'semi%'
       and s.winner_entry is not null
       and s.entry1 is not null and s.entry2 is not null
       and v.pid is not null
    on conflict do nothing;
    return;
  end if;

  for m in
    select tm.entry1, tm.entry2, tm.winner_entry
      from public.tournament_matches tm
     where tm.tournament_id = p_tournament_id
       and coalesce(tm.bracket, 'wb') = 'wb'
       and tm.round = v_final_round - 1
       and tm.winner_entry is not null
  loop
    insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
    select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
      from public.tournament_entries e,
           lateral (values (e.player_id), (e.partner_id)) as v(pid)
     where e.id = (case when m.winner_entry = m.entry1 then m.entry2 else m.entry1 end)
       and v.pid is not null
    on conflict do nothing;
  end loop;
end $$;

drop function if exists public._open_grand_final(uuid);
drop function if exists public._drop_from_winners(uuid, uuid, int, int);
drop function if exists public._advance_in_losers(uuid, uuid, int, int);
drop function if exists public._lb_place(uuid, uuid, int, int, boolean);
drop function if exists public._wb_rounds(uuid);

-- VERIFY: must return true.
select to_regproc('public._open_grand_final') is null
       and pg_get_functiondef('public.record_bracket_winner(uuid,uuid,text)'::regprocedure)
           not like '%_open_grand_final%' as grand_final_rolled_back;
