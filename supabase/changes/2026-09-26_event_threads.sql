-- ===========================================================================
-- An event-wide thread per tournament (2026-09-26)
--
-- Phase 2b. The per-match thread (2026-09-26_tournament_tickets.sql) covers the
-- four players of one tie. It does not cover what an organizer actually needs to
-- say to a whole event: the draw is up, courts moved, rain delay, bring an extra
-- ball. That was the other half of tournament comms.
--
-- ── Why not organizer_broadcasts ────────────────────────────────────────────
-- It looked like the natural home -- it is already per-tournament and already
-- carries a title + body. It is NOT: its RLS is
-- `organizer_id = auth.uid() or _is_admin()`, i.e. it is an organizer-only AUDIT
-- LOG of push blasts. Players never read it; they receive a `notifications` row
-- and, when the organizer has a community, a mirrored feed post. Opening it to
-- entrants would change what the table means and what its existing index and
-- policy are for. It stays a log.
--
-- ── Why not a new table either ──────────────────────────────────────────────
-- `match_tickets` + `ticket_messages` + `ticket_reads` already IS a thread with
-- members, messages, an unread cursor and a lifecycle, and 2026-09-26 made its
-- parent swappable. An event thread is the same shape with a different
-- membership rule, so it becomes a THIRD mutually exclusive parent
-- (`tournament_id`) rather than a parallel table with its own RLS to get wrong.
-- Every policy on all three tables is unchanged again.
--
-- The table name now undersells it -- it holds match threads AND event threads.
-- Renaming it would touch ticket_messages, ticket_reads, ticket_roster,
-- ticket_inbox, mark_ticket_read, request_number, number_requests.ticket_id and
-- three screens, for no behavioural gain. Read `match_tickets` as "thread".
--
-- ── Phone numbers are deliberately NOT served in an event thread ────────────
-- This is the important decision here. In a four-player thread "we are in this
-- match together" is a real justification for letting someone ASK for a number.
-- Across a 64-entrant event it is not -- it would turn one registration into a
-- request channel to every other entrant, which is the same shape as the hole
-- closed on 2026-08-10, when typing a stranger into the partner picker was a
-- free phone-number lookup on anyone.
--
-- So an event thread serves the roster (useful: see who has entered) with
-- `phone` NULL and `share_state` 'none' for everyone, and `request_number`
-- refuses it outright. Numbers stay a per-match thing. `_can_see_phone` is
-- untouched and remains THE rule everywhere else.
--
-- ⚠️ Run AFTER 2026-09-26_tournament_tickets.sql.
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The third parent.
-- ---------------------------------------------------------------------------
alter table public.match_tickets
  add column if not exists tournament_id uuid
    references public.tournaments(id) on delete cascade;

create unique index if not exists match_tickets_tournament_key
  on public.match_tickets (tournament_id)
  where tournament_id is not null;

-- Exactly one of the three. Replaces the two-way check from the previous delta.
alter table public.match_tickets drop constraint if exists match_tickets_one_parent_chk;
alter table public.match_tickets add constraint match_tickets_one_parent_chk
  check ((match_id is not null)::int
       + (tournament_match_id is not null)::int
       + (tournament_id is not null)::int = 1);

comment on column public.match_tickets.tournament_id is
  'Set for an EVENT-wide thread (every entrant of one tournament); the other two '
  'parents are then NULL. Event threads never serve phone numbers -- see '
  'changes/2026-09-26_event_threads.sql.';

-- ---------------------------------------------------------------------------
-- 2. Membership: every entrant of the event, and their named partners.
--
--    Withdrawn entries drop out, so leaving an event leaves the thread. Guests
--    (partner_id null) have no profile and are skipped, exactly as in the
--    per-match thread.
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
  -- one tournament match: the four players of the two entries
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
     and v.pid is not null
  union
  -- the whole event: every non-withdrawn entrant plus their named partners.
  -- `team` is null — it means nothing across an event, and ticket_roster orders
  -- by it then by name, so everyone sorts alphabetically.
  select v.pid, null::text
    from public.match_tickets t
    join public.tournament_entries e on e.tournament_id = t.tournament_id
   cross join lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where t.id = p_ticket
     and t.tournament_id is not null
     and coalesce(e.status, '') <> 'withdrawn'
     and v.pid is not null;
$$;

-- ---------------------------------------------------------------------------
-- 3. Lifecycle. An event thread lives on the same clock as its per-match
--    threads: open until 48h after the event's last day.
-- ---------------------------------------------------------------------------
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
                    + interval '48 hours'))
      or exists (
    select 1
      from public.match_tickets t
      join public.tournaments tr on tr.id = t.tournament_id
     where t.id = p_ticket
       and coalesce(tr.status, '') <> 'cancelled'
       and now() < (coalesce(tr.end_date, tr.start_date)::timestamptz
                    + interval '48 hours'));
$$;

-- ---------------------------------------------------------------------------
-- 4. ticket_roster — an event thread serves NO numbers.
--
--    See the header. `phone` is NULL and `share_state` is 'none' for every row
--    of an event thread, regardless of an existing swap: a swap made in a match
--    thread is still honoured THERE, this thread just doesn't serve it.
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
  v_open  boolean;
  v_uid   uuid := auth.uid();
  v_event boolean;
begin
  if not public._ticket_member(p_ticket) then
    raise exception 'Not a member of this ticket';
  end if;
  v_open := public._ticket_open(p_ticket);
  select (t.tournament_id is not null) into v_event
    from public.match_tickets t where t.id = p_ticket;

  return query
  select
    p.id,
    p.name,
    p.username,
    p.avatar_url,
    tp.team,
    (select level from public.player_ratings where player_id = p.id),
    -- False for a tournament or event thread: nobody hosts a tournament match,
    -- and the organizer of an event is not in the thread.
    coalesce(
      (select m.created_by = p.id
         from public.match_tickets t
         join public.matches m on m.id = t.match_id
        where t.id = p_ticket), false),
    (p.id = v_uid),
    case when v_open and not v_event and public._can_see_phone(v_uid, p.id)
         then p.phone else null end,
    case
      when p.id = v_uid then 'me'
      when v_event then 'none'   -- an event thread is not a request channel
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
-- 5. request_number refuses an event thread.
--
--    Belt as well as braces: section 4 already reports 'none' so the UI offers
--    no Ask button, but the RPC is reachable directly and is the actual
--    boundary. Everything else is unchanged.
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

  -- An event thread is not a request channel. Sharing across a 64-entrant field
  -- is not the same claim as sharing with the three people in your match.
  if exists (select 1 from public.match_tickets t
              where t.id = p_ticket and t.tournament_id is not null) then
    return 'Numbers are shared inside a match, not across a whole event.';
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
-- 6. ticket_inbox lists event threads too.
--
--    Dropped first again: the return type is unchanged from the previous delta,
--    but the drop keeps this file re-runnable in either order.
--    match_type is 'event'; venue/court are the tournament's venue and name.
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
    select t.id as ticket_id, t.match_id, t.tournament_match_id,
           t.tournament_id, t.created_at
      from public.match_tickets t
     where public._ticket_member(t.id)
  )
  select
    mine.ticket_id,
    mine.match_id,
    mine.tournament_match_id,
    public._ticket_open(mine.ticket_id),
    case
      when mine.tournament_id is not null then 'event'
      when mine.tournament_match_id is not null then 'tournament'
      else coalesce(m.match_type, 'casual')
    end,
    coalesce(m.scheduled_at, tmr.start_date::timestamptz, evt.start_date::timestamptz),
    coalesce(c.venue_name, tmr.venue_name, evt.venue_name),
    coalesce(c.name, tmr.name, evt.name),
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
  left join public.tournaments tmr       on tmr.id = tm.tournament_id
  left join public.tournaments evt       on evt.id = mine.tournament_id
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
-- 7. Open the event thread on the first entry.
--
--    Mirrors how the match thread opens on the join that first puts players on
--    both sides: the thread appears when there is somebody in it. An event with
--    no entrants would have no members, so nobody could read it anyway — but
--    creating it on demand keeps the table honest.
-- ---------------------------------------------------------------------------
create or replace function public.open_event_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.status, '') = 'withdrawn' then return new; end if;
  insert into public.match_tickets (tournament_id)
  values (new.tournament_id)
  on conflict (tournament_id) where tournament_id is not null do nothing;
  return new;
end $$;

drop trigger if exists trg_open_event_ticket on public.tournament_entries;
create trigger trg_open_event_ticket
  after insert on public.tournament_entries
  for each row execute function public.open_event_ticket();

-- Backfill: one thread per tournament that has an entrant and hasn't finished.
insert into public.match_tickets (tournament_id)
select tr.id
  from public.tournaments tr
 where coalesce(tr.status, '') <> 'cancelled'
   and now() < (coalesce(tr.end_date, tr.start_date)::timestamptz + interval '48 hours')
   and exists (select 1 from public.tournament_entries e
                where e.tournament_id = tr.id
                  and coalesce(e.status, '') <> 'withdrawn')
on conflict (tournament_id) where tournament_id is not null do nothing;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Run these one at a time; the editor shows only the last result set.

-- Every thread has exactly one parent. Expect zero rows.
select id, match_id, tournament_match_id, tournament_id
  from public.match_tickets
 where (match_id is not null)::int
     + (tournament_match_id is not null)::int
     + (tournament_id is not null)::int <> 1;

-- The three kinds, and how many carry conversation.
select case
         when tournament_id is not null then 'event'
         when tournament_match_id is not null then 'tournament match'
         else 'pickup match'
       end as kind,
       count(*) as threads,
       count(*) filter (
         where exists (select 1 from public.ticket_messages m where m.ticket_id = id)
       ) as with_messages
  from public.match_tickets
 group by 1
 order by 1;

-- Event threads and how many entrants each resolves to.
select tr.name, tr.start_date,
       (select count(*) from public._ticket_players(t.id)) as members
  from public.match_tickets t
  join public.tournaments tr on tr.id = t.tournament_id
 order by tr.start_date desc
 limit 20;

-- No event thread may ever have produced a number request. Expect zero.
select count(*) as event_number_requests
  from public.number_requests nr
  join public.match_tickets t on t.id = nr.ticket_id
 where t.tournament_id is not null;
