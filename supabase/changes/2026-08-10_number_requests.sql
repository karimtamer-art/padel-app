-- 2026-08-10 — Numbers are asked for, not handed out.
--
-- BEFORE. A match ticket showed every member's phone number to every other
-- member the moment it opened, and `matchCols` embedded profiles.phone into the
-- match payload so the lobby's contact sheet could dial anyone in the match.
-- Being in a match with someone was, by itself, enough to get their number.
--
-- AFTER, two independent controls:
--
--  1. INSIDE A TICKET — nobody's number is shown automatically, teammate or
--     opponent. You raise a request, they accept or decline. Accepting is a
--     SWAP: both sides can then see each other. One approval connects two
--     people, which is what "let's call each other" actually means.
--
--  2. EVERYWHERE ELSE — `profiles.phone_public` decides whether co-players in
--     your matches can see your number WITHOUT asking. It defaults to FALSE:
--     private unless you opt in. Turning it off never blocks requests — people
--     can still ask, you still decide. It only removes the automatic path.
--
-- A swap is between two PEOPLE, not per match: accept once and you stay
-- connected next week rather than re-asking every booking. Revocable from the
-- privacy screen, because an approval you can't take back isn't consent.
--
-- Safe to re-run. Also folded into migration_player_app.sql.

-- ── the switch ────────────────────────────────────────────────────────────

-- Private by default. The whole point of this change is that being in a match
-- with someone stops being enough, so the safe value is the default value.
alter table public.profiles
  add column if not exists phone_public boolean not null default false;

-- ── who may see whom ──────────────────────────────────────────────────────

-- An accepted swap. Stored once per pair with a_id < b_id so the pair has ONE
-- canonical row and "did we swap" is a primary-key lookup in either direction.
create table if not exists public.contact_shares (
  a_id       uuid not null references public.profiles(id) on delete cascade,
  b_id       uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (a_id, b_id)
);
alter table public.contact_shares drop constraint if exists contact_shares_order_chk;
alter table public.contact_shares add  constraint contact_shares_order_chk
  check (a_id < b_id);

create table if not exists public.number_requests (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid references public.match_tickets(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  target_id    uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);
alter table public.number_requests drop constraint if exists number_requests_status_chk;
alter table public.number_requests add  constraint number_requests_status_chk
  check (status in ('pending', 'accepted', 'declined'));

-- One live ask per direction per pair. Partial, so a decline doesn't block a
-- later ask in a different match.
create unique index if not exists number_requests_one_live
  on public.number_requests (requester_id, target_id) where status = 'pending';
create index if not exists idx_number_requests_target
  on public.number_requests (target_id, status);

-- Canonical pair order, so callers never have to think about it.
create or replace function public._pair_lo(a uuid, b uuid)
returns uuid language sql immutable as $$ select least(a, b); $$;
create or replace function public._pair_hi(a uuid, b uuid)
returns uuid language sql immutable as $$ select greatest(a, b); $$;

-- Have these two swapped?
create or replace function public._has_share(p_one uuid, p_two uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.contact_shares
     where a_id = public._pair_lo(p_one, p_two)
       and b_id = public._pair_hi(p_one, p_two));
$$;

-- THE rule for showing a phone number, in one place so every surface agrees:
-- it's mine, or we've swapped, or they chose to be public.
create or replace function public._can_see_phone(p_viewer uuid, p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_viewer is not null and (
    p_viewer = p_target
    or public._has_share(p_viewer, p_target)
    or coalesce((select phone_public from public.profiles where id = p_target), false));
$$;

grant execute on function public._has_share(uuid, uuid)     to authenticated;
grant execute on function public._can_see_phone(uuid, uuid) to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.contact_shares enable row level security;
drop policy if exists "contact share: mine" on public.contact_shares;
create policy "contact share: mine" on public.contact_shares
  for select using (a_id = auth.uid() or b_id = auth.uid());
grant select on public.contact_shares to authenticated;

alter table public.number_requests enable row level security;
drop policy if exists "number request: mine" on public.number_requests;
create policy "number request: mine" on public.number_requests
  for select using (requester_id = auth.uid() or target_id = auth.uid());
grant select on public.number_requests to authenticated;

-- ── asking ────────────────────────────────────────────────────────────────

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
  if not exists (
    select 1 from public.match_tickets t
      join public.match_players mp on mp.match_id = t.match_id
     where t.id = p_ticket and mp.player_id = p_target) then
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
  values (p_target, 'match', 'Number request',
          coalesce(v_name, 'A player') ||
            ' asked for your number so you can sort the game.' ||
            ' Accepting shares both ways.',
          jsonb_build_object('request_id', v_id, 'ticket_id', p_ticket,
                             'action', 'number_request'));
  return null;
end $$;
grant execute on function public.request_number(uuid, uuid) to authenticated;

create or replace function public.respond_number_request(
  p_request uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.number_requests;
  v_name text;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select * into v_req from public.number_requests where id = p_request for update;
  if not found then return 'Request not found.'; end if;
  if v_req.target_id <> v_uid then return 'This request isn''t yours.'; end if;
  if v_req.status <> 'pending' then return 'You already answered this.'; end if;

  update public.number_requests
     set status = case when coalesce(p_accept, false) then 'accepted' else 'declined' end,
         responded_at = now()
   where id = p_request;

  if not coalesce(p_accept, false) then
    -- Deliberately silent: telling someone they were turned down invites a
    -- second ask. The requester's row just stops showing "Pending".
    return null;
  end if;

  insert into public.contact_shares (a_id, b_id)
  values (public._pair_lo(v_uid, v_req.requester_id),
          public._pair_hi(v_uid, v_req.requester_id))
  on conflict do nothing;

  select name into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_req.requester_id, 'match', 'Number shared',
          coalesce(v_name, 'They') || ' shared their number with you.',
          jsonb_build_object('ticket_id', v_req.ticket_id,
                             'action', 'number_shared'));
  return null;
end $$;
grant execute on function public.respond_number_request(uuid, boolean) to authenticated;

-- Requests waiting on me, for the accept/decline sheet.
create or replace function public.my_number_requests()
returns table (
  request_id     uuid,
  ticket_id      uuid,
  requester_id   uuid,
  requester_name text,
  requester_avatar text,
  created_at     timestamptz
)
language sql stable security definer set search_path = public as $$
  select r.id, r.ticket_id, r.requester_id, p.name, p.avatar_url, r.created_at
    from public.number_requests r
    join public.profiles p on p.id = r.requester_id
   where r.target_id = auth.uid() and r.status = 'pending'
   order by r.created_at desc;
$$;
grant execute on function public.my_number_requests() to authenticated;

-- ── the roster, rebuilt around the rule ───────────────────────────────────
-- Same shape as before plus `share_state`, which is all the UI needs to decide
-- between showing a number, a Request button, or Pending.
--   'me'       — your own row
--   'shared'   — visible (swapped, or they are public)
--   'pending'  — you asked, no answer yet
--   'none'     — ask them

drop function if exists public.ticket_roster(uuid);
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
    mp.team,
    p.level,
    (m.created_by = p.id),
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
  from public.match_tickets t
  join public.matches m        on m.id = t.match_id
  join public.match_players mp on mp.match_id = m.id
  join public.profiles p       on p.id = mp.player_id
  where t.id = p_ticket
  order by mp.team, (m.created_by = p.id) desc, p.name;
end $$;
grant execute on function public.ticket_roster(uuid) to authenticated;

-- ── the lobby's contact sheet ─────────────────────────────────────────────
-- Replaces the profiles.phone embed in MatchService.matchCols, which shipped a
-- number to the client for every co-player and left the decision to Dart.
-- Now the number never leaves Postgres unless the rule allows it.

create or replace function public.player_phone(p_player uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return null; end if;
  -- Must actually share a match with them, so this can't be used to test the
  -- whole user table for public numbers.
  if v_uid <> p_player and not exists (
    select 1 from public.match_players a
      join public.match_players b on b.match_id = a.match_id
     where a.player_id = v_uid and b.player_id = p_player) then
    return null;
  end if;
  if not public._can_see_phone(v_uid, p_player) then return null; end if;
  return (select phone from public.profiles where id = p_player);
end $$;
grant execute on function public.player_phone(uuid) to authenticated;

-- ── the privacy screen ────────────────────────────────────────────────────

create or replace function public.set_phone_public(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  update public.profiles set phone_public = coalesce(p_on, false)
   where id = auth.uid();
end $$;
grant execute on function public.set_phone_public(boolean) to authenticated;

-- Who I've swapped with, so approving is reversible.
create or replace function public.my_contact_shares()
returns table (
  player_id  uuid,
  name       text,
  username   text,
  avatar_url text,
  since      timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.username, p.avatar_url, s.created_at
    from public.contact_shares s
    join public.profiles p
      on p.id = case when s.a_id = auth.uid() then s.b_id else s.a_id end
   where s.a_id = auth.uid() or s.b_id = auth.uid()
   order by s.created_at desc;
$$;
grant execute on function public.my_contact_shares() to authenticated;

-- Revoking cuts BOTH ways — a swap is one row, and taking your number back
-- while keeping theirs would be a strange kind of consent.
create or replace function public.revoke_contact_share(p_other uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return 'Not signed in.'; end if;
  delete from public.contact_shares
   where a_id = public._pair_lo(v_uid, p_other)
     and b_id = public._pair_hi(v_uid, p_other);
  -- Clear any answered request between the two of you so a fresh ask is
  -- possible later rather than being blocked by history.
  delete from public.number_requests
   where status <> 'pending'
     and ((requester_id = v_uid and target_id = p_other)
       or (requester_id = p_other and target_id = v_uid));
  return null;
end $$;
grant execute on function public.revoke_contact_share(uuid) to authenticated;

notify pgrst, 'reload schema';
