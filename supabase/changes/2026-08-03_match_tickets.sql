-- 2026-08-03 — Match tickets: an automatic group thread per match.
--
-- Players create a match and then have nowhere to sort the ride, the balls or
-- who pays the court. A ticket opens automatically with all four players in
-- it, and carries their phone numbers so they can reach each other off-app.
--
-- DESIGN NOTES (why it is shaped like this):
--
--  * Membership is NOT stored. It derives from match_players, so joining or
--    leaving a match adjusts the thread for free and join_match / leave_match
--    (the anti-cheat boundary) are left completely alone.
--
--  * Open/closed is NOT stored either. A ticket is open until 24h after the
--    match was scheduled, and dead if the match was cancelled. Deriving it
--    avoids needing pg_cron, which is not enabled on this project.
--
--  * Phone numbers are served ONLY by ticket_roster(), only to members, and
--    only while the ticket is open. They are never shipped with the match
--    payload. This is the phone-privacy boundary that was deferred back in
--    June — it lands here.
--
-- Existing 1:1 DMs (conversations / direct_messages) are untouched.
--
-- Safe to re-run.

-- ── tables ────────────────────────────────────────────────────────────────

create table if not exists public.match_tickets (
  id         uuid primary key default gen_random_uuid(),
  match_id   uuid not null unique references public.matches(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.ticket_messages (
  id        uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.match_tickets(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  text      text not null,
  sent_at   timestamptz not null default now()
);
create index if not exists idx_ticket_messages
  on public.ticket_messages (ticket_id, sent_at);

-- Read cursor per player, same pattern as channel_reads.
create table if not exists public.ticket_reads (
  ticket_id    uuid not null references public.match_tickets(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (ticket_id, player_id)
);

-- ── membership + lifecycle helpers ────────────────────────────────────────

-- SECURITY DEFINER: these are called from RLS policies, so they must see
-- match_players regardless of the caller's own row-level visibility.
create or replace function public._ticket_member(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1
      from public.match_tickets t
      join public.match_players mp on mp.match_id = t.match_id
     where t.id = p_ticket
       and mp.player_id = auth.uid());
$$;

-- Open until 24h after the scheduled start; a cancelled match closes at once.
create or replace function public._ticket_open(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1
      from public.match_tickets t
      join public.matches m on m.id = t.match_id
     where t.id = p_ticket
       and m.status <> 'cancelled'
       and now() < m.scheduled_at + interval '24 hours');
$$;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.match_tickets enable row level security;
drop policy if exists "ticket: member read" on public.match_tickets;
create policy "ticket: member read" on public.match_tickets
  for select using (public._ticket_member(id));
grant select on public.match_tickets to authenticated;

alter table public.ticket_messages enable row level security;
drop policy if exists "ticket msg: member read" on public.ticket_messages;
create policy "ticket msg: member read" on public.ticket_messages
  for select using (public._ticket_member(ticket_id));
-- Posting needs an OPEN ticket: a closed thread is read-only, not gone.
drop policy if exists "ticket msg: member send" on public.ticket_messages;
create policy "ticket msg: member send" on public.ticket_messages
  for insert with check (
    sender_id = auth.uid()
    and public._ticket_member(ticket_id)
    and public._ticket_open(ticket_id));
grant select, insert on public.ticket_messages to authenticated;

alter table public.ticket_reads enable row level security;
drop policy if exists "ticket reads: own" on public.ticket_reads;
create policy "ticket reads: own" on public.ticket_reads
  for all using (player_id = auth.uid()) with check (player_id = auth.uid());
grant select, insert, update on public.ticket_reads to authenticated;

-- ── the ticket opens itself ───────────────────────────────────────────────

create or replace function public.open_match_ticket()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.match_tickets (match_id)
  values (new.id)
  on conflict (match_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_open_match_ticket on public.matches;
create trigger trg_open_match_ticket
  after insert on public.matches
  for each row
  execute function public.open_match_ticket();

-- Backfill: every match that still has a live ticket window gets one, so the
-- feature is not empty for people with matches already booked.
insert into public.match_tickets (match_id)
select m.id from public.matches m
 where m.status <> 'cancelled'
   and now() < m.scheduled_at + interval '24 hours'
on conflict (match_id) do nothing;

-- ── inbox ─────────────────────────────────────────────────────────────────

-- Every ticket the caller is in: the match line, the last message, and how
-- many they have not read. Newest activity first.
create or replace function public.ticket_inbox()
returns table (
  ticket_id    uuid,
  match_id     uuid,
  is_open      boolean,
  match_type   text,
  scheduled_at timestamptz,
  venue        text,
  court        text,
  last_text    text,
  last_at      timestamptz,
  last_sender  text,
  unread       int
)
language sql stable security definer set search_path = public as $$
  select
    t.id,
    m.id,
    (m.status <> 'cancelled' and now() < m.scheduled_at + interval '24 hours'),
    m.match_type,
    m.scheduled_at,
    c.venue_name,
    c.name,
    lm.text,
    lm.sent_at,
    lp.name,
    (select count(*)::int
       from public.ticket_messages x
      where x.ticket_id = t.id
        and x.sender_id <> auth.uid()
        and x.sent_at > coalesce(r.last_read_at, 'epoch'::timestamptz))
  from public.match_tickets t
  join public.matches m       on m.id = t.match_id
  join public.match_players me on me.match_id = m.id and me.player_id = auth.uid()
  left join public.courts c   on c.id = m.court_id
  left join public.ticket_reads r
         on r.ticket_id = t.id and r.player_id = auth.uid()
  left join lateral (
    select x.text, x.sent_at, x.sender_id
      from public.ticket_messages x
     where x.ticket_id = t.id
     order by x.sent_at desc
     limit 1
  ) lm on true
  left join public.profiles lp on lp.id = lm.sender_id
  order by coalesce(lm.sent_at, t.created_at) desc;
$$;
grant execute on function public.ticket_inbox() to authenticated;

-- ── roster (the phone-number boundary) ────────────────────────────────────

-- The four players. Phone numbers are returned ONLY to a member of the
-- ticket, and ONLY while it is open — a closed ticket hides them again, which
-- is what the thread promises its members.
--
-- Superseded by 2026-08-10_number_requests.sql, which adds share_state. Do NOT
-- re-run this delta after that one — it would put the old shape back and the
-- ticket roster would lose its Request-number state. The drop is here only so
-- re-running it errors on nothing rather than dying with 42P13.
drop function if exists public.ticket_roster(uuid);
create or replace function public.ticket_roster(p_ticket uuid)
returns table (
  player_id  uuid,
  name       text,
  username   text,
  avatar_url text,
  team       text,
  level      numeric,
  is_host    boolean,
  is_me      boolean,
  phone      text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_open boolean;
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
    mp.team,
    p.level,
    (m.created_by = p.id),
    (p.id = auth.uid()),
    case when v_open then p.phone else null end
  from public.match_tickets t
  join public.matches m        on m.id = t.match_id
  join public.match_players mp on mp.match_id = m.id
  join public.profiles p       on p.id = mp.player_id
  where t.id = p_ticket
  order by mp.team, (m.created_by = p.id) desc, p.name;
end $$;
grant execute on function public.ticket_roster(uuid) to authenticated;

-- ── read cursor ───────────────────────────────────────────────────────────

create or replace function public.mark_ticket_read(p_ticket uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if not public._ticket_member(p_ticket) then
    return;
  end if;
  insert into public.ticket_reads (ticket_id, player_id, last_read_at)
  values (p_ticket, auth.uid(), now())
  on conflict (ticket_id, player_id)
  do update set last_read_at = now();
end $$;
grant execute on function public.mark_ticket_read(uuid) to authenticated;

-- Total unread across every ticket — feeds the Home chat badge alongside the
-- existing DM count.
create or replace function public.ticket_unread_total()
returns int language sql stable security definer
set search_path = public as $$
  select coalesce(sum(u.unread), 0)::int from public.ticket_inbox() u;
$$;
grant execute on function public.ticket_unread_total() to authenticated;

-- ── realtime ──────────────────────────────────────────────────────────────
-- Live messages in the thread, same as direct_messages.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'ticket_messages'
  ) then
    alter publication supabase_realtime add table public.ticket_messages;
  end if;
end $$;
