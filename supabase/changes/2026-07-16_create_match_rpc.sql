-- 2026-07-16 · Fix create-match: atomic match + players in one RPC
--
-- Bug: MatchService.createMatch inserted the `matches` row (allowed) and then
-- inserted `match_players` DIRECTLY from the client. match_players has RLS with
-- no INSERT policy, so that insert was denied — leaving an ORPHANED match with
-- no creator/partner, and the creator's device saw a swallowed error ("nothing
-- happened"). join/leave/accept avoid this because they're SECURITY DEFINER.
--
-- This creates a single SECURITY DEFINER create_match() that inserts the match
-- and the players (creator + optional partner) in ONE transaction: no orphans,
-- and it can't be left half-created. Also cleans up any orphaned open matches
-- from the bug. Idempotent; also folded into migration_player_app.sql.

create or replace function public.create_match(
  p_competitive  boolean,
  p_scheduled_at timestamptz,
  p_court_id     uuid default null,
  p_partner_id   uuid default null,
  p_min_elo      int default 0,
  p_open         boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'Not signed in.'; end if;
  if p_scheduled_at is null then raise exception 'Pick a time for the match.'; end if;

  insert into public.matches
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_elo, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     not coalesce(p_open, true),
     coalesce(p_min_elo, 0),
     'PDL-' || upper(substr(md5(gen_random_uuid()::text), 1, 5)))
  returning id into v_id;

  insert into public.match_players (match_id, player_id, team) values (v_id, v_uid, 'a');
  if p_partner_id is not null and p_partner_id <> v_uid then
    insert into public.match_players (match_id, player_id, team) values (v_id, p_partner_id, 'a');
  end if;

  return v_id;
end $$;
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- One-time cleanup: delete orphaned open matches (no players) left by the bug.
delete from public.matches m
 where m.status = 'open'
   and not exists (select 1 from public.match_players mp where mp.match_id = m.id);

notify pgrst, 'reload schema';
