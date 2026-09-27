-- ============================================================================
-- 2026-09-27 — Phase 4b: the server stops accepting pickup matches
-- ============================================================================
-- Phase 4a (8a9da82) took every pickup entry point out of the app. Installed
-- older builds still have the buttons, so only the server can actually close
-- the door. This delta does that and nothing else.
--
-- ONE SWITCH: app_settings.pickup_open. Seeded 'false' here, and seeded with
-- `do nothing` so re-running the migration never overrides a hand-set value.
-- Reopening is `update app_settings set value = 'true' where key = 'pickup_open'`
-- — no deploy, no client release.
--
-- WHY GUARDS ON THE TABLES, NOT EDITS TO THE RPCs. Every way into a pickup
-- match ends in an INSERT on one of three tables:
--   matches            ← create_match
--   match_players      ← join_match, join_match_by_code (calls join_match),
--                        mm_accept (four historical definitions),
--                        respond_match_invite(accept)
--   matchmaking_tickets← mm_start_search
-- A BEFORE INSERT trigger on each refuses the row, which aborts the whole RPC
-- — including any match_invites row it wrote first — and the client shows the
-- message (every service method surfaces PostgrestException.message, and none
-- of those RPCs catch exceptions). Editing six function bodies instead would
-- touch four copies of mm_accept and trip the duplicate-definition ratchet in
-- test/sql_raise_arity_test.dart for no behavioural gain.
--
-- WHAT STILL WORKS, ON PURPOSE. Matches already booked drain on their own:
-- leave_match, cancel_match, submit_match_result, confirm_match_result and
-- expire_stale_matches (which also auto-settles 48h pending_confirm) are all
-- UPDATEs/DELETEs and never reach these guards. Nothing in flight is cancelled.
--
-- TOURNAMENTS ARE UNTOUCHED. finalize_tournament materialises each decided
-- tournament match into matches + match_players as the settlement ledger; its
-- rows carry tournament_match_id, and the guards let exactly those through.
--
-- Existing search tickets are deleted: they only exist to push "Match found"
-- for new open matches, and there will be none.
-- ============================================================================

insert into public.app_settings (key, value)
  values ('pickup_open', 'false')
  on conflict (key) do nothing;

-- Absent or anything but 'false' reads as OPEN, so a database without this
-- row behaves exactly as before (same fail-open principle as the region and
-- app-update checks).
create or replace function public._pickup_open()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select lower(btrim(value)) from public.app_settings
                    where key = 'pickup_open'), 'true') <> 'false'
$$;

create or replace function public._guard_pickup_match()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.tournament_match_id is null and not public._pickup_open() then
    raise exception 'Pickup matches have ended — join a tournament instead.';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_pickup_match on public.matches;
create trigger trg_guard_pickup_match before insert on public.matches
  for each row execute function public._guard_pickup_match();

create or replace function public._guard_pickup_player()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public._pickup_open()
     and exists (select 1 from public.matches m
                  where m.id = new.match_id and m.tournament_match_id is null) then
    raise exception 'Pickup matches have ended — join a tournament instead.';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_pickup_player on public.match_players;
create trigger trg_guard_pickup_player before insert on public.match_players
  for each row execute function public._guard_pickup_player();

create or replace function public._guard_pickup_search()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public._pickup_open() then
    raise exception 'Pickup matches have ended — join a tournament instead.';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_pickup_search on public.matchmaking_tickets;
create trigger trg_guard_pickup_search before insert on public.matchmaking_tickets
  for each row execute function public._guard_pickup_search();

delete from public.matchmaking_tickets where not public._pickup_open();

-- Verify: the switch, and how much pickup is still draining. Phase 4c (drop
-- the pickup RPCs) waits until the in-flight count reaches zero.
do $$
declare v_open boolean; v_by text;
begin
  v_open := public._pickup_open();
  select coalesce(string_agg(s || ' ' || n, ', '), 'none')
    into v_by
    from (select status s, count(*)::text n
            from public.matches
           where tournament_match_id is null
             and status in ('open', 'full', 'in_progress', 'pending_confirm', 'disputed')
           group by status) x;
  raise notice 'pickup_open = %; in-flight pickup statuses: %', v_open, v_by;
end $$;

notify pgrst, 'reload schema';
