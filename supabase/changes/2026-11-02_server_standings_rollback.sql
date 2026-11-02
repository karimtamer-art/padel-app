-- ROLLBACK for 2026-11-02_server_standings.sql. Only run this to undo it.
-- Restores advance_stage's wins-only ranking and removes the new functions. App
-- builds that read tournament_standings then hide the standings table and keep
-- showing fixtures. No data is touched.

create or replace function public.advance_stage(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_spec jsonb; v_stages jsonb; v_cur_stage int; v_cur_round int; v_kind text;
  v_adv int; quals uuid[]; wins uuid[];
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select format_spec into v_spec from public.tournaments where id = p_tournament_id;
  v_stages := coalesce(v_spec->'stages', '[]'::jsonb);
  select max(stage) into v_cur_stage from public.tournament_matches where tournament_id = p_tournament_id;
  if v_cur_stage is null then return 'Generate the first stage first.'; end if;
  select max(round) into v_cur_round from public.tournament_matches
    where tournament_id = p_tournament_id and stage = v_cur_stage;
  if exists (select 1 from public.tournament_matches
              where tournament_id = p_tournament_id and stage = v_cur_stage
                and round = v_cur_round and winner_entry is null) then
    return 'Finish all matches in the current round first.';
  end if;
  v_kind := v_stages->v_cur_stage->>'kind';

  if v_kind = 'groups' then
    v_adv := coalesce((v_stages->v_cur_stage->'cfg'->>'advance')::int, 2);
    quals := array(
      select pid from (
        select bracket, pid, row_number() over (partition by bracket order by wins desc) rn
          from (
            select bracket, pid, count(*) filter (where won) wins from (
              select bracket, entry1 pid, (winner_entry = entry1) won
                from public.tournament_matches
               where tournament_id = p_tournament_id and stage = v_cur_stage and entry1 is not null
              union all
              select bracket, entry2 pid, (winner_entry = entry2) won
                from public.tournament_matches
               where tournament_id = p_tournament_id and stage = v_cur_stage and entry2 is not null
            ) u group by bracket, pid
          ) s
      ) r where rn <= v_adv order by rn, bracket);
    if v_cur_stage + 1 >= jsonb_array_length(v_stages) then
      return 'Groups done — add a knockout stage to the format to continue.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage + 1, 1, quals);
    return null;

  elsif v_kind in ('roundRobin', 'swiss') then
    v_adv := coalesce((v_stages->v_cur_stage->'cfg'->>'advance')::int, 4);
    quals := array(
      select pid from (
        select pid, count(*) filter (where won) wins from (
          select entry1 pid, (winner_entry = entry1) won from public.tournament_matches
           where tournament_id = p_tournament_id and stage = v_cur_stage and entry1 is not null
          union all
          select entry2 pid, (winner_entry = entry2) won from public.tournament_matches
           where tournament_id = p_tournament_id and stage = v_cur_stage and entry2 is not null
        ) u group by pid order by wins desc
      ) s limit v_adv);
    if v_cur_stage + 1 >= jsonb_array_length(v_stages) then
      return 'Stage done — add a knockout stage to the format to continue.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage + 1, 1, quals);
    return null;

  else
    select array_agg(winner_entry order by slot) into wins
      from public.tournament_matches
     where tournament_id = p_tournament_id and stage = v_cur_stage
       and round = v_cur_round and winner_entry is not null;
    if coalesce(array_length(wins, 1), 0) <= 1 then
      return 'Champion decided — no more rounds.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage, v_cur_round + 1, wins);
    return null;
  end if;
end $$;

drop function if exists public.tournament_standings(uuid);
drop function if exists public._stage_standings(uuid, int, boolean);
drop function if exists public._match_set_counts(text, boolean);

-- VERIFY: must return true.
select pg_get_functiondef('public.advance_stage(uuid)'::regprocedure) not like '%_stage_standings%'
       and to_regproc('public.tournament_standings') is null as standings_rolled_back;
