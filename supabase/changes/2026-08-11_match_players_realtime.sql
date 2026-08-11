-- 2026-08-11 — Live match lobby. Safe to re-run.
--
-- The lobby is the screen most likely to be out of date: you sit looking at
-- "2/4" while someone takes the third slot. Until now the only way to find out
-- was to pull down.
--
-- Publishing match_players lets MatchService.rosterStream fire on join, leave
-- and invite-accept. The client ignores the rows it receives — a realtime
-- stream can't join, and a lobby needs names, levels and the match's own
-- status, which flips to 'full' on the fourth player — so it treats the event
-- purely as "something moved" and re-reads the match.
--
-- RLS still applies to realtime, so a player only receives rows for matches
-- they can already read. This publishes no more than the lobby query does.
--
-- If this never runs, rosterStream simply never fires and the lobby still
-- refreshes when the app resumes and when you pull. The feature degrades
-- quietly rather than breaking.

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'match_players'
  ) then
    alter publication supabase_realtime add table public.match_players;
  end if;
end $$;
