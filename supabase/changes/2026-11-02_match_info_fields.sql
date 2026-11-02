-- 2026-11-02: optional fields players see when set: a match's court and LIVE state,
-- a tournament's draw time and venue address. All nullable, nothing backfilled.
--
-- RUN ORDER: any time after 2026-11-02_finalize_guard.sql. Independent of standings
-- and the grand final.
-- ROLLBACK: supabase/rollbacks/2026-11-02_match_info_fields_rollback.sql.
-- Safe to re-run.
--
-- On tournament_matches, not `matches`: a `matches` row only exists once a tournament
-- is finalized, so it can't describe a match being played. And there is no `venues`
-- table: a tournament's venue is the free-text venue_name.

alter table public.tournament_matches add column if not exists court text;
alter table public.tournaments add column if not exists draw_at timestamptz;
alter table public.tournaments add column if not exists venue_address text;

-- result_status has no CHECK, so 'live' needs no constraint change. Results are
-- unaffected: submit_tournament_result only refuses 'confirmed' and overwrites 'live'
-- with 'pending'; the app treats a decided match as finished whatever this says.
comment on column public.tournament_matches.result_status is
  'open|live|pending|confirmed|disputed';

-- The console's court + LIVE control. Goes through owns_tournament like every other
-- draw RPC, so an organizer can only touch their own events. LIVE only applies to a
-- match with both pairs, no result and no submission waiting; turning it off puts the
-- match back to open and leaves any other state alone.
create or replace function public.admin_set_match_info(
  p_match_id uuid, p_court text, p_live boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from tournament_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if p_live and (m.winner_entry is not null or m.entry1 is null or m.entry2 is null
                 or m.result_status not in ('open', 'live')) then
    return 'Only a match waiting to be played can go live.';
  end if;
  update tournament_matches set
    court = nullif(btrim(p_court), ''),
    result_status = case when p_live then 'live'
                         when result_status = 'live' then 'open'
                         else result_status end
   where id = p_match_id;
  return null;
end $$;
revoke all on function public.admin_set_match_info(uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_match_info(uuid, text, boolean) to authenticated;

-- VERIFY: every `ok` must be true.
select * from (values
  ('tournament_matches.court exists', exists (select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tournament_matches' and column_name = 'court')),
  ('tournaments.draw_at exists', exists (select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tournaments' and column_name = 'draw_at')),
  ('tournaments.venue_address exists', exists (select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tournaments' and column_name = 'venue_address')),
  ('no CHECK on result_status would refuse live', not exists (
     select 1 from pg_constraint c
      where c.conrelid = 'public.tournament_matches'::regclass and c.contype = 'c'
        and pg_get_constraintdef(c.oid) like '%result_status%')),
  ('admin_set_match_info: signed-in only',
   has_function_privilege('authenticated', 'public.admin_set_match_info(uuid,text,boolean)', 'execute')
   and not has_function_privilege('anon', 'public.admin_set_match_info(uuid,text,boolean)', 'execute'))
) as v(check_name, ok);
