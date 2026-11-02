-- 2026-11-02: double-elimination grand final, one match, no reset. Winners champion
-- against losers champion. Third place is the losers-final loser.
--
-- RUN ORDER: LAST, and only AFTER the 6 Nov event.
-- BEFORE RUNNING: no double-elim event may be mid-play, because this changes how
-- losers rows are numbered. The check at the end lists any. An in-flight event hits
-- "Losers bracket seat is taken" rather than being corrupted; regenerate its draw.
-- ROLLBACK: supabase/rollbacks/2026-11-02_grand_final_rollback.sql.
-- Safe to re-run.
--
-- Losers routing is now the standard fixed double-elimination bracket. It replaces
-- the arrival-order rule (CLAUDE.md "known quirk"), which stranded pairs in 28-49% of
-- simulated events, and the proposed "first open seat" rule, which could cost one pair
-- extra matches (8 instead of 6 at 16 pairs) and seat winners in a same or lower round.
-- For a draw of 2^k: k winners rounds, 2(k-1) losers rounds.
--   losers odd round:   survivors play each other
--   losers even round:  survivors play the losers of a winners round
-- Byes only exist in winners round 1, so walkovers only arise in losers rounds 1-2.

-- Winners rounds in this draw (round 1 has one row per two slots of the draw).
create or replace function public._wb_rounds(p_tid uuid)
returns int
language sql stable security definer set search_path = public as $$
  select round(log(2, greatest(count(*) * 2, 2)::numeric))::int
    from tournament_matches
   where tournament_id = p_tid and bracket = 'wb' and round = 1;
$$;
revoke all on function public._wb_rounds(uuid) from public, anon, authenticated;

-- Puts a pair in a losers seat. An occupied seat means the event was drawn under the
-- old routing: refuse rather than overwrite someone.
create or replace function public._lb_place(
  p_tid uuid, p_entry uuid, p_round int, p_slot int, p_first boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_taken uuid;
begin
  insert into tournament_matches (tournament_id, bracket, round, slot)
  values (p_tid, 'lb', p_round, p_slot)
  on conflict (tournament_id, bracket, round, slot) do nothing;

  select case when p_first then entry1 else entry2 end into v_taken
    from tournament_matches
   where tournament_id = p_tid and bracket = 'lb' and round = p_round and slot = p_slot
   for update;
  if v_taken is not null and v_taken <> p_entry then
    raise exception 'Losers bracket seat is taken (round %, slot %). Regenerate this draw.',
      p_round, p_slot;
  end if;

  update tournament_matches
     set entry1 = case when p_first then p_entry else entry1 end,
         entry2 = case when p_first then entry2 else p_entry end
   where tournament_id = p_tid and bracket = 'lb' and round = p_round and slot = p_slot;
end $$;
revoke all on function public._lb_place(uuid, uuid, int, int, boolean) from public, anon, authenticated;

-- A losers-bracket winner moves on. The losers final's winner goes to the grand final.
create or replace function public._advance_in_losers(
  p_tid uuid, p_winner uuid, p_round int, p_slot int)
returns void
language plpgsql security definer set search_path = public as $$
declare v_last int := 2 * (public._wb_rounds(p_tid) - 1);
begin
  if p_round >= v_last then return; end if;
  if p_round % 2 = 1 then
    perform public._lb_place(p_tid, p_winner, p_round + 1, p_slot, true);
  else
    perform public._lb_place(p_tid, p_winner, p_round + 1, p_slot / 2, p_slot % 2 = 0);
  end if;
end $$;
revoke all on function public._advance_in_losers(uuid, uuid, int, int) from public, anon, authenticated;

-- A winners-bracket loser drops down. Later rounds drop into the opposite half, which
-- delays rematches; they are allowed, just not sought.
create or replace function public._drop_from_winners(
  p_tid uuid, p_loser uuid, p_round int, p_slot int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_k int := public._wb_rounds(p_tid);
  v_slot int;
  v_byes int;
begin
  if v_k <= 1 then return; end if; -- two pairs: straight to the grand final

  if p_round = 1 then
    v_slot := p_slot / 2;
    -- The other half of this seat is a bye, so nobody is coming: walkover.
    if exists (select 1 from tournament_matches
                where tournament_id = p_tid and bracket = 'wb' and round = 1
                  and slot = (p_slot # 1) and winner_entry is not null
                  and (entry1 is null or entry2 is null)) then
      perform public._lb_place(p_tid, p_loser, 2, v_slot, true);
    else
      perform public._lb_place(p_tid, p_loser, 1, v_slot, p_slot % 2 = 0);
    end if;
    return;
  end if;

  v_slot := (1 << (v_k - p_round)) - 1 - p_slot;

  if p_round = 2 then
    -- Both feeders of the survivor's side were byes: no survivor exists, walkover.
    select count(*) into v_byes
      from tournament_matches
     where tournament_id = p_tid and bracket = 'wb' and round = 1
       and slot in (v_slot * 2, v_slot * 2 + 1) and winner_entry is not null
       and (entry1 is null or entry2 is null);
    if v_byes = 2 then
      perform public._advance_in_losers(p_tid, p_loser, 2, v_slot);
      return;
    end if;
  end if;

  perform public._lb_place(p_tid, p_loser, 2 * (p_round - 1), v_slot, false);
end $$;
revoke all on function public._drop_from_winners(uuid, uuid, int, int) from public, anon, authenticated;

-- Opens the grand final once both finals are decided. Its round is one past the winners
-- final, because _award_tournament_season_points finds the champion through max(round).
-- Idempotent through the unique key.
create or replace function public._open_grand_final(p_tid uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_k int := public._wb_rounds(p_tid);
  f record;
  v_wb uuid;
  v_lb uuid;
begin
  select * into f from tournament_matches
   where tournament_id = p_tid and bracket = 'wb' and round = v_k and slot = 0;
  if not found or f.winner_entry is null then return; end if;
  v_wb := f.winner_entry;

  if v_k <= 1 then
    v_lb := case when f.winner_entry = f.entry1 then f.entry2 else f.entry1 end;
  else
    select winner_entry into v_lb from tournament_matches
     where tournament_id = p_tid and bracket = 'lb' and round = 2 * (v_k - 1) and slot = 0;
    if v_lb is null then return; end if;
  end if;

  insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
  values (p_tid, 'gf', v_k + 1, 0, v_wb, v_lb)
  on conflict (tournament_id, bracket, round, slot) do nothing;
end $$;
revoke all on function public._open_grand_final(uuid) from public, anon, authenticated;

create or replace function public.record_bracket_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_loser uuid;
  v_format text;
  v_k int;
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

  if v_format is distinct from 'double_elim' then
    -- single elimination: unchanged. The very last match still makes a row for the
    -- champion; finalize_tournament and the app both know it isn't a match.
    perform public._advance_winner(m.tournament_id, m.bracket, m.round, m.slot, p_winner);
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtext(m.tournament_id::text));
  v_k := public._wb_rounds(m.tournament_id);

  if m.bracket = 'wb' then
    if m.round < v_k then
      perform public._advance_winner(m.tournament_id, 'wb', m.round, m.slot, p_winner);
    end if;
    perform public._drop_from_winners(m.tournament_id, v_loser, m.round, m.slot);
  elsif m.bracket = 'lb' then
    perform public._advance_in_losers(m.tournament_id, p_winner, m.round, m.slot);
  end if;
  perform public._open_grand_final(m.tournament_id);

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
  select tm.entry1, tm.entry2, tm.winner_entry, coalesce(tm.bracket, 'wb') as bracket into f
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

  -- A grand-final event: third place is whoever lost the losers final. Two-pair events
  -- have no losers final, so nobody. Everything below is the single-elimination rule.
  if f.bracket = 'gf' then
    insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
    select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
      from (select case when lf.winner_entry = lf.entry1 then lf.entry2 else lf.entry1 end as third
              from public.tournament_matches lf
             where lf.tournament_id = p_tournament_id and lf.bracket = 'lb'
               and lf.winner_entry is not null
             order by lf.round desc
             limit 1) x
      join public.tournament_entries e on e.id = x.third,
           lateral (values (e.player_id), (e.partner_id)) as v(pid)
     where v.pid is not null
    on conflict do nothing;
    return;
  end if;

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

-- VERIFY: every `ok` must be true. `detail` on the first row lists double-elim events
-- with unplayed matches and no grand final: it should be empty BEFORE you rely on this.
select * from (values
  ('no double-elim event is mid-play',
   not exists (select 1 from tournaments t
                where t.format = 'double_elim' and t.status <> 'cancelled'
                  and not coalesce(t.rating_applied, false)
                  and exists (select 1 from tournament_matches m
                               where m.tournament_id = t.id and m.winner_entry is null
                                 and m.entry1 is not null and m.entry2 is not null)),
   coalesce((select string_agg(t.name, ', ') from tournaments t
              where t.format = 'double_elim' and t.status <> 'cancelled'
                and not coalesce(t.rating_applied, false)
                and exists (select 1 from tournament_matches m
                             where m.tournament_id = t.id and m.winner_entry is null
                               and m.entry1 is not null and m.entry2 is not null)), '')),
  ('record_bracket_winner opens the final',
   pg_get_functiondef('public.record_bracket_winner(uuid,uuid,text)'::regprocedure) like '%_open_grand_final%', ''),
  ('helpers closed to clients',
   not has_function_privilege('authenticated', 'public._open_grand_final(uuid)', 'execute')
   and not has_function_privilege('anon', 'public._open_grand_final(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'public._drop_from_winners(uuid,uuid,int,int)', 'execute')
   and not has_function_privilege('anon', 'public._drop_from_winners(uuid,uuid,int,int)', 'execute')
   and not has_function_privilege('authenticated', 'public._advance_in_losers(uuid,uuid,int,int)', 'execute')
   and not has_function_privilege('anon', 'public._advance_in_losers(uuid,uuid,int,int)', 'execute')
   and not has_function_privilege('authenticated', 'public._lb_place(uuid,uuid,int,int,boolean)', 'execute')
   and not has_function_privilege('anon', 'public._lb_place(uuid,uuid,int,int,boolean)', 'execute')
   and not has_function_privilege('authenticated', 'public._wb_rounds(uuid)', 'execute')
   and not has_function_privilege('anon', 'public._wb_rounds(uuid)', 'execute'), '')
) as v(check_name, ok, detail);
