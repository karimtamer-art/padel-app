-- ROLLBACK for 2026-11-02_season_points_free_labels.sql: back to what live ran on 2 Nov,
-- which has the grand final but gives free-label draws no points.
-- Points already awarded stay: remove them by hand if you need to.

create or replace function public._award_tournament_season_points(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; v_frozen boolean; v_title int; v_podium int;
  v_final_round int; f record; m record;
  v_champ uuid; v_runner uuid; v_region text;
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
  if v_final_round is null then return; end if;

  -- the final: champion + runner-up
  select tm.entry1, tm.entry2, tm.winner_entry, coalesce(tm.bracket, 'wb') as bracket into f
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.round = v_final_round and tm.winner_entry is not null
   order by tm.slot limit 1;
  if not found then return; end if;

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
end 
$$;
