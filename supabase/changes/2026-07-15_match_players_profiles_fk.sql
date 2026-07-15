-- 2026-07-15 · Fix match reads: PostgREST couldn't embed profiles on match_players
--
-- Symptom (opening a match / match detail):
--   PGRST200 "Could not find a relationship between 'match_players' and
--   'profiles' in the schema cache"
--
-- Cause: on the drifted live DB, match_players.player_id has a FK only to
-- auth.users, so PostgREST has no public relationship to resolve the
-- `match_players(... profiles(...))` embed used by MatchService.matchCols.
-- Every other player_id table (matches, orders, tournament_entries,
-- trade_requests) already had a named-FK repair; match_players was missing one.
--
-- Adds the FK ONLY if match_players has no FK to profiles yet (guarded on the
-- target table, not a constraint name) so we never create a second, ambiguous
-- profiles relationship. A distinct constraint name is used because the drifted
-- table already has match_players_player_id_fkey pointing at auth.users; both
-- coexist and PostgREST only exposes the public.profiles one. Then reloads
-- PostgREST's schema cache. Idempotent. Also folded into migration_player_app.sql.

do $$ begin
  if not exists (
    select 1 from pg_constraint c
    join pg_class rel  on rel.oid  = c.conrelid
    join pg_class frel on frel.oid = c.confrelid
    where c.contype = 'f'
      and rel.relnamespace = 'public'::regnamespace
      and rel.relname  = 'match_players'
      and frel.relname = 'profiles'
  ) then
    alter table public.match_players
      add constraint match_players_player_id_profiles_fkey
      foreign key (player_id) references public.profiles(id) on delete cascade;
  end if;
end $$;

-- Tell PostgREST to pick up the new relationship immediately.
notify pgrst, 'reload schema';
