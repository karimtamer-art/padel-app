-- 2026-11-02: tournaments drawn with free labels get their season points.
--
-- _award_tournament_season_points only looked for wb/gf rows. Console knockouts and
-- groups + knockout (generate_from_format, advance_stage) label rounds "Semifinal",
-- "Final", so finalizing them rated every match and awarded no title or podium points,
-- with no error anywhere.
--
-- Only tournaments finalized AFTER this runs are affected. Events already finalized
-- stay as they are: nothing here backfills, and finalize_tournament won't run twice.
-- Round-robin-only events still get no title points: there is no match to call the
-- final. Nothing changes for wb/gf draws.
--
-- RUN ORDER: with standings, BEFORE the 6 Nov event is finalized. Finalizing first
-- would lose that event's points for good.
-- ROLLBACK: supabase/rollbacks/2026-11-02_season_points_free_labels_rollback.sql.
-- Safe to re-run. The grand final is already on live (checked against the 2 Nov schema
-- dump), so this version keeps its third-place rule as well.

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

-- VERIFY: every `ok` must be true. `detail` lists free-label events already finalized,
-- which keep no points unless you add them by hand; it's for information.
select * from (values
  ('free-label finals are recognised',
   pg_get_functiondef('public._award_tournament_season_points(uuid)'::regprocedure) like '%v_free%', ''),
  ('still unreachable by clients only if the audit says so: informational', true,
   case when has_function_privilege('authenticated', 'public._award_tournament_season_points(uuid)', 'execute')
        then 'authenticated CAN call this; lock-down delta covers it' else 'closed' end),
  ('events finalized with no season points', true,
   coalesce((select string_agg(t.name, ', ') from public.tournaments t
              where coalesce(t.rating_applied, false)
                and exists (select 1 from public.tournament_matches m
                             where m.tournament_id = t.id and lower(btrim(m.bracket)) = 'final')
                and not exists (select 1 from public.season_points sp where sp.tournament_id = t.id)), ''))
) as v(check_name, ok, detail);
