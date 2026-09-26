-- ===========================================================================
-- A thread per tournament match (2026-09-26)
--
-- Phase 2 of the tournament-first pivot. Tournaments had NO chat at all, while
-- pickup matches got an automatic group thread with the four players, their
-- phone numbers and one place to sort the ride and the balls. Since tournaments
-- are now the product, that is backwards.
--
-- ── Why the ticket points at tournament_matches, not at a fake matches row ──
-- The obvious route was to make `finalize_tournament` materialise its
-- `matches` + `match_players` mirror at DRAW time instead of after the event,
-- so `match_tickets` would work unchanged. That was the original plan and it is
-- a trap: a mirror row carries `status = 'full'` and four real `match_players`,
-- which is exactly what every PICKUP surface selects. It would have appeared
-- under "Your Pickup Matches", and `join_match`, `leave_match`, `cancel_match`
-- and the score-submission RPCs would all have accepted it — a player could
-- have left a tournament match, or submitted a pickup score against it. Eight
-- live surfaces would have needed a `tournament_match_id is null` guard, in a
-- release where pickup still works.
--
-- So `match_tickets` grows a second, mutually exclusive parent instead. This
-- also leaves `finalize_tournament` and `_settle_rating` COMPLETELY untouched,
-- which matters: that is the anti-cheat boundary and the rating engine.
--
-- ── What made it cheap ──────────────────────────────────────────────────────
-- Everything already routed through `_ticket_member` and `_ticket_open`, so
-- every RLS policy on match_tickets / ticket_messages / ticket_reads needs NO
-- change. Teaching those two functions about the second parent is the whole
-- job. The number-request / contact-share system (`_can_see_phone`, the swap,
-- the silent decline) comes along for free and is NOT reimplemented.
--
-- `ticket_roster` actually gets SIMPLER: the four players now come from one
-- set-returning `_ticket_players`, so the pickup and tournament cases share a
-- single query instead of branching.
--
-- Also fixes a real pre-existing bug — see section 7.
--
-- ⚠️ Run AFTER 2026-09-26_regions.sql and 2026-09-26_seasons_per_region.sql.
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. A ticket may hang off a pickup match OR a tournament match, never both.
--
--    `match_id` was `not null unique`. Dropping NOT NULL keeps the unique
--    index, and Postgres allows many NULLs in a unique index, so pickup tickets
--    are unaffected.
-- ---------------------------------------------------------------------------
alter table public.match_tickets alter column match_id drop not null;

alter table public.match_tickets
  add column if not exists tournament_match_id uuid
    references public.tournament_matches(id) on delete cascade;

create unique index if not exists match_tickets_tm_key
  on public.match_tickets (tournament_match_id)
  where tournament_match_id is not null;

alter table public.match_tickets drop constraint if exists match_tickets_one_parent_chk;
alter table public.match_tickets add constraint match_tickets_one_parent_chk
  check ((match_id is not null) <> (tournament_match_id is not null));

comment on column public.match_tickets.tournament_match_id is
  'Set for a tournament match thread; match_id is then NULL. Exactly one of the '
  'two is always set (match_tickets_one_parent_chk). A tournament thread is NOT '
  'a matches row on purpose — see changes/2026-09-26_tournament_tickets.sql.';

-- ---------------------------------------------------------------------------
-- 2. The four players of a ticket, whichever parent it has.
--
--    One definition, so membership, the roster and the number-request guard can
--    never disagree about who is in a thread.
--
--    Guests (`player_id is null` on an entry) are skipped: they have no profile,
--    so there is nobody to add. A tournament match against an all-guest pair
--    therefore yields a two-person thread, which is correct.
-- ---------------------------------------------------------------------------
create or replace function public._ticket_players(p_ticket uuid)
returns table (player_id uuid, team text)
language sql stable security definer set search_path = public as $$
  -- pickup match, or a tournament match already materialised by finalize
  select mp.player_id, mp.team
    from public.match_tickets t
    join public.match_players mp on mp.match_id = t.match_id
   where t.id = p_ticket
  union
  -- tournament match: the four players of the two entries
  select v.pid, v.team
    from public.match_tickets t
    join public.tournament_matches tm on tm.id = t.tournament_match_id
    join public.tournament_entries e1 on e1.id = tm.entry1
    join public.tournament_entries e2 on e2.id = tm.entry2
   cross join lateral (values
      (e1.player_id, 'a'), (e1.partner_id, 'a'),
      (e2.player_id, 'b'), (e2.partner_id, 'b')
   ) as v(pid, team)
   where t.id = p_ticket
     and v.pid is not null;
$$;
grant execute on function public._ticket_players(uuid) to authenticated;

-- Is a SPECIFIC player in this thread? Extracted because request_number needs
-- exactly this question about someone else, and used to ask it by joining
-- match_players directly — which would reject every target in a tournament
-- thread. See section 6.
create or replace function public._ticket_has_player(p_ticket uuid, p_player uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1 from public._ticket_players(p_ticket) tp
     where tp.player_id = p_player);
$$;
grant execute on function public._ticket_has_player(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Membership + lifecycle, now parent-agnostic.
--
--    SECURITY DEFINER is load-bearing: these are called FROM RLS policies, so
--    they must see the underlying rows regardless of the caller's own
--    visibility. Unchanged from before, restated because the bodies change.
-- ---------------------------------------------------------------------------
create or replace function public._ticket_member(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select public._ticket_has_player(p_ticket, auth.uid());
$$;

-- A pickup thread is open until 24h after the scheduled start; a cancelled
-- match closes it at once. A TOURNAMENT thread stays open until 48h after the
-- event's last day — an event runs over days rather than starting at one
-- instant, and players still need each other while it is on.
create or replace function public._ticket_open(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1
      from public.match_tickets t
      join public.matches m on m.id = t.match_id
     where t.id = p_ticket
       and m.status <> 'cancelled'
       and now() < m.scheduled_at + interval '24 hours')
      or exists (
    select 1
      from public.match_tickets t
      join public.tournament_matches tm on tm.id = t.tournament_match_id
      join public.tournaments tr        on tr.id = tm.tournament_id
     where t.id = p_ticket
       and coalesce(tr.status, '') <> 'cancelled'
       and now() < (coalesce(tr.end_date, tr.start_date)::timestamptz
                    + interval '48 hours'));
$$;

-- ---------------------------------------------------------------------------
-- 4. ticket_roster — one query for both parents.
--
--    The phone-number boundary is UNCHANGED: `_can_see_phone` is still THE
--    rule, a closed thread still stops serving numbers, and `share_state` still
--    drives the roster row. Only where the four players come from changed.
--
--    `is_host` is false for a tournament thread, deliberately: nobody hosts a
--    tournament match. The organizer does, and they are not in the thread.
-- ---------------------------------------------------------------------------
create or replace function public.ticket_roster(p_ticket uuid)
returns table (
  player_id   uuid,
  name        text,
  username    text,
  avatar_url  text,
  team        text,
  level       numeric,
  is_host     boolean,
  is_me       boolean,
  phone       text,
  share_state text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_open boolean;
  v_uid  uuid := auth.uid();
begin
  if not public._ticket_member(p_ticket) then
    raise exception 'Not a member of this ticket';
  end if;
  v_open := public._ticket_open(p_ticket);

  return query
  select
    p.id,
    p.name,
    p.username,
    p.avatar_url,
    tp.team,
    (select level from public.player_ratings where player_id = p.id),
    coalesce(
      (select m.created_by = p.id
         from public.match_tickets t
         join public.matches m on m.id = t.match_id
        where t.id = p_ticket), false),
    (p.id = v_uid),
    -- A closed ticket hides numbers again, exactly as before; a swap that
    -- happened inside it survives, but this thread stops serving it.
    case when v_open and public._can_see_phone(v_uid, p.id)
         then p.phone else null end,
    case
      when p.id = v_uid then 'me'
      when public._can_see_phone(v_uid, p.id) then 'shared'
      when exists (select 1 from public.number_requests r
                    where r.requester_id = v_uid and r.target_id = p.id
                      and r.status = 'pending') then 'pending'
      else 'none'
    end
  from public._ticket_players(p_ticket) tp
  join public.profiles p on p.id = tp.player_id
  order by tp.team, p.name;
end $$;
grant execute on function public.ticket_roster(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. ticket_inbox — lists both kinds.
--
--    DROPPED first: `create or replace` cannot change a return type (42P13),
--    and this gains a `tournament_match_id` column. Same reason `dm_inbox` is
--    dropped before being redefined further up the migration.
--
--    For a tournament thread `match_id` is null, `match_type` is 'tournament',
--    `venue` is the event's venue and `court` its name — so the inbox row reads
--    "Cairo Padel Club · Autumn Open" with no client branching.
-- ---------------------------------------------------------------------------
drop function if exists public.ticket_inbox();
create or replace function public.ticket_inbox()
returns table (
  ticket_id           uuid,
  match_id            uuid,
  tournament_match_id uuid,
  is_open             boolean,
  match_type          text,
  scheduled_at        timestamptz,
  venue               text,
  court               text,
  last_text           text,
  last_at             timestamptz,
  last_sender         text,
  unread              int
)
language sql stable security definer set search_path = public as $$
  with mine as (
    select t.id as ticket_id, t.match_id, t.tournament_match_id, t.created_at
      from public.match_tickets t
     where public._ticket_member(t.id)
  )
  select
    mine.ticket_id,
    mine.match_id,
    mine.tournament_match_id,
    public._ticket_open(mine.ticket_id),
    coalesce(m.match_type, 'tournament'),
    coalesce(m.scheduled_at, tr.start_date::timestamptz),
    coalesce(c.venue_name, tr.venue_name),
    coalesce(c.name, tr.name),
    lm.text,
    lm.sent_at,
    lp.name,
    (select count(*)::int
       from public.ticket_messages x
      where x.ticket_id = mine.ticket_id
        and x.sender_id <> auth.uid()
        and x.sent_at > coalesce(r.last_read_at, 'epoch'::timestamptz))
  from mine
  left join public.matches m             on m.id  = mine.match_id
  left join public.courts c              on c.id  = m.court_id
  left join public.tournament_matches tm on tm.id = mine.tournament_match_id
  left join public.tournaments tr        on tr.id = tm.tournament_id
  left join public.ticket_reads r
         on r.ticket_id = mine.ticket_id and r.player_id = auth.uid()
  left join lateral (
    select x.text, x.sent_at, x.sender_id
      from public.ticket_messages x
     where x.ticket_id = mine.ticket_id
     order by x.sent_at desc
     limit 1
  ) lm on true
  left join public.profiles lp on lp.id = lm.sender_id
  order by coalesce(lm.sent_at, mine.created_at) desc;
$$;
grant execute on function public.ticket_inbox() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. request_number — ask the shared helper who is in the thread.
--
--    Its second guard joined `match_players` directly, which would answer
--    "That player isn't in this match." for every target in a tournament
--    thread. Everything else here is unchanged, including the deliberately
--    SILENT decline and the already-connected / already-asked short circuits.
-- ---------------------------------------------------------------------------
create or replace function public.request_number(p_ticket uuid, p_target uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_id   uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_target = v_uid then return 'That''s you.'; end if;

  -- You may only ask someone you are actually in this ticket with. Without
  -- this the RPC would be a way to ping any user id in the database.
  if not public._ticket_member(p_ticket) then
    return 'Not a member of this ticket.';
  end if;
  if not public._ticket_has_player(p_ticket, p_target) then
    return 'That player isn''t in this match.';
  end if;

  if public._has_share(v_uid, p_target) then
    return null; -- already connected; nothing to ask for
  end if;
  if exists (select 1 from public.number_requests
              where requester_id = v_uid and target_id = p_target
                and status = 'pending') then
    return null; -- already asked; treat as success so the UI just shows Pending
  end if;

  insert into public.number_requests (ticket_id, requester_id, target_id)
  values (p_ticket, v_uid, p_target)
  returning id into v_id;

  select name into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (p_target, 'match',
          coalesce(v_name, 'A player') || ' asked for your number',
          'Tap to share it, or ignore this.',
          jsonb_build_object('ticket_id', p_ticket, 'request_id', v_id));
  return null;
end $$;
grant execute on function public.request_number(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Open the thread when the pairing is known — and fix a real bug.
--
--    THE BUG: `open_match_ticket_on_join()` fires on every `match_players`
--    insert and checks only that both teams are present. `finalize_tournament`
--    inserts four `match_players` rows per decided tournament match, AFTER the
--    event, so it has been opening a thread for every historical tournament
--    match — threads for matches that were already over, which nobody could
--    usefully use. Now gated on the match not being finished.
--
--    The tournament thread opens from a trigger on `tournament_matches` instead
--    of from the four functions that can set a pairing (`generate_draw`,
--    `_advance_winner`, `record_bracket_winner`'s losers-bracket drop, and
--    `add_custom_match`). One trigger catches every path, including paths added
--    later, and none of those functions needs editing.
-- ---------------------------------------------------------------------------
create or replace function public.open_match_ticket_on_join()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- A finished or cancelled match gets no thread. finalize_tournament inserts
  -- its four players with status already 'completed', which is what used to
  -- mint a dead thread per historical tournament match.
  if exists (select 1 from public.matches m
              where m.id = new.match_id
                and m.status in ('completed', 'cancelled')) then
    return new;
  end if;

  if exists (select 1 from public.match_players
              where match_id = new.match_id and team = 'a')
     and exists (select 1 from public.match_players
                  where match_id = new.match_id and team = 'b') then
    insert into public.match_tickets (match_id)
    values (new.match_id)
    on conflict (match_id) do nothing;
  end if;
  return new;
end $$;

create or replace function public.open_tournament_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_real int;
begin
  if new.entry1 is null or new.entry2 is null then return new; end if;

  -- At least one real profile per side, or there is nobody to talk to. A pair
  -- of guests has no profile at all, so a thread would be empty on that side.
  select count(*) into v_real
    from public.tournament_entries e
   where e.id in (new.entry1, new.entry2)
     and e.player_id is not null;
  if coalesce(v_real, 0) < 2 then return new; end if;

  insert into public.match_tickets (tournament_match_id)
  values (new.id)
  on conflict (tournament_match_id) where tournament_match_id is not null
    do nothing;
  return new;
end $$;

drop trigger if exists trg_open_tournament_ticket on public.tournament_matches;
create trigger trg_open_tournament_ticket
  after insert or update of entry1, entry2 on public.tournament_matches
  for each row execute function public.open_tournament_ticket();

-- Retire the dead threads the un-gated trigger already minted for finished
-- tournament matches. Only ones with NO messages — an existing conversation is
-- never deleted, same rule the 2026-08-03 backfill used.
delete from public.match_tickets t
 where t.match_id is not null
   and not exists (select 1 from public.ticket_messages tm where tm.ticket_id = t.id)
   and exists (select 1 from public.matches m
                where m.id = t.match_id
                  and m.tournament_match_id is not null
                  and m.status = 'completed');

-- Open threads for tournament matches that are already drawn and still to play.
insert into public.match_tickets (tournament_match_id)
select tm.id
  from public.tournament_matches tm
  join public.tournaments tr on tr.id = tm.tournament_id
 where tm.entry1 is not null and tm.entry2 is not null
   and tm.winner_entry is null
   and coalesce(tr.status, '') <> 'cancelled'
   and now() < (coalesce(tr.end_date, tr.start_date)::timestamptz + interval '48 hours')
   and (select count(*) from public.tournament_entries e
         where e.id in (tm.entry1, tm.entry2) and e.player_id is not null) >= 2
on conflict (tournament_match_id) where tournament_match_id is not null do nothing;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Run these one at a time; the editor shows only the last result set.

-- Every ticket has exactly one parent. Expect zero rows.
select id, match_id, tournament_match_id
  from public.match_tickets
 where (match_id is not null) = (tournament_match_id is not null);

-- How the threads split, and how many carry conversation.
select case when tournament_match_id is not null then 'tournament' else 'pickup' end as kind,
       count(*) as threads,
       count(*) filter (
         where exists (select 1 from public.ticket_messages m where m.ticket_id = id)
       ) as with_messages
  from public.match_tickets
 group by 1
 order by 1;

-- No dead pickup thread should be left pointing at a finished tournament
-- mirror. Expect zero.
select count(*) as dead_mirror_threads
  from public.match_tickets t
  join public.matches m on m.id = t.match_id
 where m.tournament_match_id is not null and m.status = 'completed';

-- Spot-check one tournament thread's roster resolves four players. Replace the
-- id, or drop the where clause to see them all.
select t.id as ticket_id, tr.name as tournament,
       (select count(*) from public._ticket_players(t.id)) as players
  from public.match_tickets t
  join public.tournament_matches tm on tm.id = t.tournament_match_id
  join public.tournaments tr        on tr.id = tm.tournament_id
 order by tr.start_date desc
 limit 20;
