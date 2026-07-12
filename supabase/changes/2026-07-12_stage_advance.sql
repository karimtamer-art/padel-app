-- ============================================================================
-- Format Builder: auto-advance between stages (2026-07-12). Run once. Idempotent.
--
-- generate_from_format builds stage 0. advance_stage() then, once the current
-- round is fully decided, computes who advances (top-N per group / knockout-round
-- winners) and builds the next round or the next stage's knockout — seeded by
-- standings. Matches carry a `stage` number; knockout rounds are labelled by size
-- (Round of 16 / Quarterfinal / Semifinal / Final) so the label-grouped draw view
-- shows them cleanly. Byes auto-advance within a round.
-- ============================================================================

alter table public.tournament_matches add column if not exists stage int not null default 0;

-- Name a knockout round by its draw size.
create or replace function public._ko_round_name(p_size int)
returns text language sql immutable as $$
  select case p_size when 2 then 'Final' when 4 then 'Semifinal'
                     when 8 then 'Quarterfinal' else 'Round of ' || p_size end;
$$;

-- Seed [pairs] into a fresh knockout round (byes auto-win).
create or replace function public._build_ko_round(p_tid uuid, p_stage int, p_round int, p_pairs uuid[])
returns void language plpgsql as $$
declare n int := coalesce(array_length(p_pairs, 1), 0); v_size int := 2; v_slots int;
        i int; e1 uuid; e2 uuid; v_label text;
begin
  if n < 2 then return; end if;
  while v_size < n loop v_size := v_size * 2; end loop;
  v_slots := v_size / 2;
  v_label := public._ko_round_name(v_size);
  for i in 0 .. v_slots - 1 loop
    e1 := p_pairs[i + 1];
    e2 := case when (v_size - i) <= n then p_pairs[v_size - i] else null end;
    insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, winner_entry, stage)
    values (p_tid, v_label, p_round, i, e1, e2, case when e2 is null then e1 else null end, p_stage);
  end loop;
end $$;

-- Rebuild generate_from_format so knockout first stages are label-grouped
-- (Round of N …) and everything carries stage = 0.
create or replace function public.generate_from_format(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_spec jsonb; v_stage jsonb; v_kind text;
  v_entries uuid[]; v_n int; v_g int;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select format_spec into v_spec from public.tournaments where id = p_tournament_id;
  if v_spec is null or jsonb_array_length(coalesce(v_spec->'stages', '[]'::jsonb)) = 0 then
    return 'No saved format to generate from.';
  end if;
  v_stage := v_spec->'stages'->0;
  v_kind := v_stage->>'kind';

  select array_agg(id order by lvl desc) into v_entries from (
    select te.id, (coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0)) / 2.0 as lvl
      from public.tournament_entries te
      join public.profiles p1 on p1.id = te.player_id
      left join public.profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id and te.status = 'registered'
  ) s;
  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 registered pairs.'; end if;

  delete from public.tournament_matches where tournament_id = p_tournament_id;

  if v_kind = 'groups' then
    v_g := coalesce((v_stage->'cfg'->>'groups')::int, 4);
    declare gi int; a int; b int; v_label text; v_slot int; grp uuid[];
    begin
      for gi in 0 .. v_g - 1 loop
        grp := array(select v_entries[i] from generate_series(1, v_n) i where ((i - 1) % v_g) = gi);
        v_label := 'Group ' || chr(65 + gi);
        v_slot := 0;
        for a in 1 .. coalesce(array_length(grp, 1), 0) loop
          for b in a + 1 .. coalesce(array_length(grp, 1), 0) loop
            insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
            values (p_tournament_id, v_label, 1, v_slot, grp[a], grp[b], 0);
            v_slot := v_slot + 1;
          end loop;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind = 'roundRobin' then
    declare a int; b int; v_slot int := 0;
    begin
      for a in 1 .. v_n loop
        for b in a + 1 .. v_n loop
          insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
          values (p_tournament_id, 'Round robin', 1, v_slot, v_entries[a], v_entries[b], 0);
          v_slot := v_slot + 1;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind in ('knockout', 'doubleElim', 'consolation') then
    perform public._build_ko_round(p_tournament_id, 0, 1, v_entries);
    return null;

  else
    return 'The first stage (' || coalesce(v_kind, '?') || ') is drawn manually for now.';
  end if;
end $$;
grant execute on function public.generate_from_format(uuid) to authenticated;

-- Advance the draw: current round → next round (knockout) or current group/RR
-- stage → next stage's knockout, seeded by standings.
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
    -- knockout-like: advance to the next round from this round's winners.
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
grant execute on function public.advance_stage(uuid) to authenticated;

notify pgrst, 'reload schema';
