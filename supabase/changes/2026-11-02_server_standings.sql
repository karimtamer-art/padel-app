-- 2026-11-02: one ranking, on the server. Wins, then set difference, then
-- head-to-head. advance_stage and every screen read it, so a pair shown above the
-- cut is a pair that advances.
--
-- RUN ORDER: after 2026-11-02_finalize_guard.sql. Must be live and tested by
-- Wed 4 Nov, or wait until after the 6 Nov event (groups + knockout).
-- ROLLBACK: 2026-11-02_server_standings_rollback.sql. No data changes either way.
-- Safe to re-run.

-- Sets won by each side of one decided match, oriented using the known winner
-- ("6-3, 6-4" and "3-6, 4-6" read the same). Scores are free text from players, so
-- anything that isn't clearly sets counts as (0, 0): it must not break standings.
-- Mirrors orientedSets() in lib/backend/models/tournament_bracket.dart.
create or replace function public._match_set_counts(p_score text, p_entry1_won boolean)
returns table (sets_a int, sets_b int)
language sql immutable set search_path = public as $$
  with parsed as (
    select r[1]::int as x, r[2]::int as y
      from regexp_matches(coalesce(p_score, ''), '(\d{1,3})\s*[-–—:]\s*(\d{1,3})', 'g') r
     where regexp_replace(coalesce(p_score, ''), '(\d{1,3})\s*[-–—:]\s*(\d{1,3})', '', 'g') !~ '\d'
  ),
  counted as (
    select count(*) filter (where x > y)::int as first_wins,
           count(*) filter (where y > x)::int as second_wins
      from parsed
  )
  select case when first_wins = second_wins or (first_wins > second_wins) = p_entry1_won
              then first_wins else second_wins end,
         case when first_wins = second_wins or (first_wins > second_wins) = p_entry1_won
              then second_wins else first_wins end
    from counted;
$$;
revoke all on function public._match_set_counts(text, boolean) from public, anon, authenticated;

-- The one ranking. p_by_group = false pools the whole stage (round robin, swiss).
-- p_stage null means every group-labelled row, which is what a manual draw has.
-- Head-to-head counts wins among the pairs still level, so a three-way tie has an
-- answer too; a dead-even cycle falls through to entry id, so the order is stable
-- and the app can never disagree with what advance_stage did.
create or replace function public._stage_standings(
  p_tid uuid, p_stage int default null, p_by_group boolean default true)
returns table (
  grp text, pos int, entry_id uuid, played int, won int, lost int,
  sets_won int, sets_lost int
)
language sql stable security definer set search_path = public as $$
  with m as (
    select tm.id, tm.entry1, tm.entry2, tm.winner_entry, tm.score,
           case when p_by_group then tm.bracket else '' end as g
      from tournament_matches tm
     where tm.tournament_id = p_tid
       and tm.entry1 is not null and tm.entry2 is not null
       and case when p_stage is null
                then tm.bracket like 'Group %' or tm.bracket = 'Round robin'
                else tm.stage = p_stage end
  ),
  sides as (
    select m.g, m.id, m.entry1 as entry, m.entry2 as opp, m.winner_entry as w, c.sets_a as sf, c.sets_b as sa
      from m left join lateral public._match_set_counts(m.score, m.winner_entry = m.entry1) c on true
    union all
    select m.g, m.id, m.entry2, m.entry1, m.winner_entry, c.sets_b, c.sets_a
      from m left join lateral public._match_set_counts(m.score, m.winner_entry = m.entry1) c on true
  ),
  totals as (
    select g, entry,
           count(*) filter (where w is not null)::int as played,
           count(*) filter (where w = entry)::int as won,
           count(*) filter (where w is not null and w <> entry)::int as lost,
           coalesce(sum(sf) filter (where w is not null), 0)::int as sets_won,
           coalesce(sum(sa) filter (where w is not null), 0)::int as sets_lost
      from sides
     group by g, entry
  ),
  tiers as (
    select t.*, dense_rank() over (partition by g order by won desc, sets_won - sets_lost desc) as tier
      from totals t
  ),
  h2h as (
    select a.g, a.entry, count(*)::int as wins
      from sides s
      join tiers a on a.g = s.g and a.entry = s.entry
      join tiers b on b.g = s.g and b.entry = s.opp and b.tier = a.tier
     where s.w = s.entry
     group by a.g, a.entry
  )
  select t.g, row_number() over (
           partition by t.g
           order by t.won desc, t.sets_won - t.sets_lost desc,
                    coalesce(h.wins, 0) desc, t.entry)::int,
         t.entry, t.played, t.won, t.lost, t.sets_won, t.sets_lost
    from tiers t
    left join h2h h on h.g = t.g and h.entry = t.entry;
$$;
revoke all on function public._stage_standings(uuid, int, boolean) from public, anon, authenticated;

-- What the app reads, and the only one of these a client may call. It runs as
-- definer so it can use the helpers above, which means RLS doesn't filter it for
-- the caller: the WHERE below repeats who may read public.tournaments
-- ("tournaments: read all", "tournaments: admin write", "tournaments: organizer
-- write own"). Change those policies and this must change too; the check at the end
-- of this file prints the live ones to compare.
--
-- `qualifies` comes from the saved format with advance_stage's own defaults (2 per
-- group, 4 from a round robin); false for everyone when the format ends at this
-- stage, so nobody is told they advance to nothing.
create or replace function public.tournament_standings(p_tournament_id uuid)
returns table (
  grp text, pos int, entry_id uuid, played int, won int, lost int,
  sets_won int, sets_lost int, qualifies boolean
)
language sql stable security definer set search_path = public as $$
  with spec as (
    select coalesce(t.format_spec->'stages', '[]'::jsonb) as stages
      from tournaments t
     where t.id = p_tournament_id
       and auth.uid() is not null
       and (t.status <> 'cancelled'
            or public._is_admin()
            or (t.organizer_id = auth.uid() and public.current_admin_role() = 'organizer'))
  )
  select s.grp, s.pos, s.entry_id, s.played, s.won, s.lost, s.sets_won, s.sets_lost,
         (jsonb_array_length(spec.stages) <> 1)
         and s.pos <= coalesce((spec.stages->0->'cfg'->>'advance')::int,
                               case when s.grp = 'Round robin' then 4 else 2 end)
    from spec, public._stage_standings(p_tournament_id) s
   order by s.grp, s.pos;
$$;
revoke all on function public.tournament_standings(uuid) from public, anon;
grant execute on function public.tournament_standings(uuid) to authenticated;

-- advance_stage: the two ranking queries become reads of _stage_standings. Nothing
-- else in the body changes.
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
      select s.entry_id from public._stage_standings(p_tournament_id, v_cur_stage, true) s
       where s.pos <= v_adv
       order by s.pos, s.grp);
    if v_cur_stage + 1 >= jsonb_array_length(v_stages) then
      return 'Groups done — add a knockout stage to the format to continue.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage + 1, 1, quals);
    return null;

  elsif v_kind in ('roundRobin', 'swiss') then
    v_adv := coalesce((v_stages->v_cur_stage->'cfg'->>'advance')::int, 4);
    quals := array(
      select s.entry_id from public._stage_standings(p_tournament_id, v_cur_stage, false) s
       where s.pos <= v_adv
       order by s.pos);
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

-- VERIFY: every `ok` must be true. Compare `detail` on the policy row with the WHERE
-- in tournament_standings above; if the live policies say something else, stop.
select * from (values
  ('helper _match_set_counts closed to clients',
   not has_function_privilege('anon', 'public._match_set_counts(text,boolean)', 'execute')
   and not has_function_privilege('authenticated', 'public._match_set_counts(text,boolean)', 'execute'), ''),
  ('helper _stage_standings closed to clients',
   not has_function_privilege('anon', 'public._stage_standings(uuid,int,boolean)', 'execute')
   and not has_function_privilege('authenticated', 'public._stage_standings(uuid,int,boolean)', 'execute'), ''),
  ('tournament_standings: signed-in only',
   has_function_privilege('authenticated', 'public.tournament_standings(uuid)', 'execute')
   and not has_function_privilege('anon', 'public.tournament_standings(uuid)', 'execute'), ''),
  ('advance_stage reads the shared ranking',
   pg_get_functiondef('public.advance_stage(uuid)'::regprocedure) like '%_stage_standings%', ''),
  ('set counting reads either side the same',
   (select sets_a = 0 and sets_b = 2 from public._match_set_counts('6-3, 6-4', false))
   and (select sets_a = 0 and sets_b = 2 from public._match_set_counts('3-6, 4-6', false)), ''),
  ('live read policies on tournaments, compare by eye', true,
   (select string_agg(policyname || ': ' || coalesce(qual, '(none)'), ' | ' order by policyname)
      from pg_policies
     where schemaname = 'public' and tablename = 'tournaments' and cmd in ('SELECT', 'ALL')))
) as v(check_name, ok, detail);
