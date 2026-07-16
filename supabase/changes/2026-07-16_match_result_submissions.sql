-- 2026-07-16 · Two-claim dispute model — record each team's submission
--
-- A dispute clears matches.score/winner, so "both teams' claims" needs its own
-- durable store. match_result_submissions keeps ONE row per (match, team) with
-- that team's claimed score + winner; submit_match_result upserts it on every
-- submit. The row survives a dispute, so an admin can see Team A's claim next to
-- Team B's. No change to the player flow — claims are captured passively.
--
-- Idempotent; also folded into migration_player_app.sql.

create table if not exists public.match_result_submissions (
  match_id     uuid not null references public.matches(id) on delete cascade,
  team         text not null check (team in ('a','b')),
  submitter_id uuid references public.profiles(id),
  score_team_a text,
  score_team_b text,
  winner       text,
  created_at   timestamptz not null default now(),
  primary key (match_id, team)
);
alter table public.match_result_submissions enable row level security;
do $$ begin
  create policy "mrs: player or admin read" on public.match_result_submissions for select
    using (
      exists (select 1 from public.match_players mp
               where mp.match_id = match_result_submissions.match_id and mp.player_id = auth.uid())
      or public._is_admin()
    );
exception when duplicate_object then null; end $$;
grant select on public.match_result_submissions to authenticated;

-- submit_match_result now also records the submitter's team claim.
create or replace function public.submit_match_result(
  p_match_id uuid, p_score_a text, p_score_b text, p_winner text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_type text; v_status text; v_sched timestamptz; v_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_winner not in ('a','b') then return 'Invalid winner.'; end if;
  select team into v_team from match_players where match_id = p_match_id and player_id = v_uid;
  if v_team is null then return 'Only players in this match can submit a score.'; end if;
  select match_type, status, scheduled_at into v_type, v_status, v_sched
    from matches where id = p_match_id for update;
  if v_status = 'completed' then return 'Result already confirmed.'; end if;
  if v_sched > now() then return 'Score entry opens after the match time.'; end if;

  update matches set
    score_team_a = p_score_a, score_team_b = p_score_b, winner_team = p_winner,
    result_submitted_by = v_uid, result_submitted_at = now(),
    status = case when v_type = 'ranked' then 'pending_confirm' else 'completed' end
  where id = p_match_id;

  insert into public.match_result_submissions
    (match_id, team, submitter_id, score_team_a, score_team_b, winner)
  values (p_match_id, v_team, v_uid, p_score_a, p_score_b, p_winner)
  on conflict (match_id, team) do update set
    submitter_id = excluded.submitter_id,
    score_team_a = excluded.score_team_a,
    score_team_b = excluded.score_team_b,
    winner       = excluded.winner,
    created_at   = now();
  return null;
end $$;
grant execute on function public.submit_match_result(uuid, text, text, text) to authenticated;

-- Backfill a submission from any match that currently has a stored result.
insert into public.match_result_submissions
  (match_id, team, submitter_id, score_team_a, score_team_b, winner)
select m.id,
       coalesce((select mp.team from public.match_players mp
                  where mp.match_id = m.id and mp.player_id = m.result_submitted_by), 'a'),
       m.result_submitted_by, m.score_team_a, m.score_team_b, m.winner_team
  from public.matches m
 where m.result_submitted_by is not null and m.winner_team is not null
on conflict (match_id, team) do nothing;

-- Console read now carries each match's submissions (both claims).
create or replace function public.admin_matches_console(p_limit int default 200)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(x order by x.scheduled_at desc nulls last), '[]'::json)
    from (
      select
        m.id, m.status, m.match_type, m.scheduled_at, m.min_elo, m.winner_team,
        m.score_team_a, m.score_team_b,
        c.venue_name, c.name as court_name,
        (select p.name from public.profiles p where p.id = m.created_by)            as host,
        (select p.name from public.profiles p where p.id = m.result_submitted_by)   as submitted_by,
        (select count(*)::int from public.match_players mp where mp.match_id = m.id) as player_count,
        (select coalesce(json_agg(json_build_object('name', pr.name, 'team', mp.team) order by mp.team), '[]'::json)
           from public.match_players mp join public.profiles pr on pr.id = mp.player_id
          where mp.match_id = m.id)                                                  as players,
        (select coalesce(json_agg(json_build_object(
                   'team', s.team,
                   'submitter', (select p2.name from public.profiles p2 where p2.id = s.submitter_id),
                   'score_a', s.score_team_a, 'score_b', s.score_team_b, 'winner', s.winner) order by s.team), '[]'::json)
           from public.match_result_submissions s where s.match_id = m.id)           as submissions,
        (select max(rh.delta) from public.ranking_history rh where rh.match_id = m.id) as elo_delta
      from public.matches m
      left join public.courts c on c.id = m.court_id
      order by m.scheduled_at desc nulls last
      limit p_limit
    ) x
  );
end $$;
grant execute on function public.admin_matches_console(int) to authenticated;

notify pgrst, 'reload schema';
