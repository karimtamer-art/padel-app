-- 2026-08-10 — Partner invites: naming someone is a REQUEST, not an enrolment.
--
-- THE HOLE THIS CLOSES. create_match(p_partner_id) inserted the named partner
-- straight into match_players. Ticket membership derives from match_players,
-- and ticket_roster() serves phone numbers to members. So anyone could type a
-- stranger's name into the partner picker and read their phone number seconds
-- later, plus drop them into a thread they never agreed to. join_match and
-- mm_accept took the same p_partner_id and had the identical hole. The obvious
-- reading is the dangerous one: this is a free phone-number lookup for any
-- player, aimed at whoever you like.
--
-- THE FIX. A named partner now becomes a row in `match_invites` with status
-- 'pending'. They are NOT a match_player, so they are not a ticket member, so
-- they have no roster entry and no number is served. They get a notification
-- and choose. Accepting is what inserts the match_players row.
--
-- RESERVED SLOT. A pending invite still occupies its slot for capacity, so the
-- spot the host meant for their partner cannot be taken by a stranger while the
-- invite sits unanswered. Reservation is TIME-DERIVED (pending + match open +
-- not yet started) rather than swept by a job, so it expires correctly on a
-- project with no pg_cron. Once it lapses the slot is free to anyone, which is
-- also what a decline does.
--
-- SECOND HARDENING. The ticket used to open on `matches` INSERT — the moment a
-- match existed, before anyone else was in it. It now opens on the join that
-- first puts a player on BOTH sides, so numbers appear only once real opponents
-- have opted in.
--
-- Safe to re-run. Also folded into migration_player_app.sql.

-- ── the invite ────────────────────────────────────────────────────────────

create table if not exists public.match_invites (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null references public.matches(id)  on delete cascade,
  inviter_id   uuid not null references public.profiles(id) on delete cascade,
  invitee_id   uuid not null references public.profiles(id) on delete cascade,
  team         text not null,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);

-- Widen-safe CHECKs (the table may predate this file on a drifted DB).
alter table public.match_invites drop constraint if exists match_invites_team_chk;
alter table public.match_invites add  constraint match_invites_team_chk
  check (team in ('a', 'b'));
alter table public.match_invites drop constraint if exists match_invites_status_chk;
alter table public.match_invites add  constraint match_invites_status_chk
  check (status in ('pending', 'accepted', 'declined', 'cancelled'));

-- One live invite per person per match. Partial, so a declined invite doesn't
-- block a later re-invite.
create unique index if not exists match_invites_one_live
  on public.match_invites (match_id, invitee_id) where status = 'pending';
create index if not exists idx_match_invites_invitee
  on public.match_invites (invitee_id, status);

-- ── occupancy: players + reserved slots ───────────────────────────────────

-- A pending invite only holds a slot while the match could still be played.
-- Deriving that from time means no sweep job is required for correctness.
create or replace function public._invite_slots(p_match uuid, p_team text default null)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int
    from public.match_invites i
    join public.matches m on m.id = i.match_id
   where i.match_id = p_match
     and i.status   = 'pending'
     and m.status   = 'open'
     and now() < m.scheduled_at
     and (p_team is null or i.team = p_team);
$$;

-- Seats taken overall = actual players + slots reserved by live invites.
create or replace function public._match_taken(p_match uuid)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.match_players where match_id = p_match)
       + public._invite_slots(p_match, null);
$$;

-- Same, per side.
create or replace function public._team_taken(p_match uuid, p_team text)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.match_players
           where match_id = p_match and team = p_team)
       + public._invite_slots(p_match, p_team);
$$;

grant execute on function public._invite_slots(uuid, text) to authenticated;
grant execute on function public._match_taken(uuid)        to authenticated;
grant execute on function public._team_taken(uuid, text)   to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────
-- Readable by the two people concerned and by anyone already in the match (so
-- the lobby can render "waiting for Sara"). Never writable from the client —
-- every mutation goes through a SECURITY DEFINER RPC below.

alter table public.match_invites enable row level security;
drop policy if exists "match invite: read" on public.match_invites;
create policy "match invite: read" on public.match_invites
  for select using (
    invitee_id = auth.uid()
    or inviter_id = auth.uid()
    or exists (select 1 from public.match_players mp
                where mp.match_id = match_invites.match_id
                  and mp.player_id = auth.uid()));
grant select on public.match_invites to authenticated;

-- An invitee is not a match_player yet, so the existing "matches: participant
-- read" policy hides the match from them — they'd tap the notification and
-- land on an empty screen with nothing to answer. A live invite is its own
-- reason to see the match. SECURITY DEFINER helper (same pattern as
-- _ticket_member) so the policy can't recurse through match_invites' own RLS.
create or replace function public._invited_to_match(p_match uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.match_invites i
     where i.match_id = p_match
       and i.invitee_id = auth.uid()
       and i.status = 'pending');
$$;
grant execute on function public._invited_to_match(uuid) to authenticated;

drop policy if exists "matches: invitee read" on public.matches;
create policy "matches: invitee read" on public.matches
  for select using (public._invited_to_match(id));

-- ── raising an invite ─────────────────────────────────────────────────────

-- Shared by create_match / join_match / mm_accept. RAISES on a bad partner
-- rather than returning a string: the caller has usually inserted its own
-- match_players row by this point, and rolling the whole thing back is the only
-- way to avoid committing a half-done join. The exception surfaces to Dart as a
-- PostgrestException, which the service layer already turns into a message.
-- Assumes the caller has validated rating/band rules.
create or replace function public._invite_partner(
  p_match uuid, p_partner uuid, p_team text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_name      text;
  v_when      timestamptz;
  v_type      text;
  v_invite    uuid;
begin
  if p_partner is null or p_partner = v_uid then return; end if;

  if not exists (select 1 from public.profiles where id = p_partner) then
    raise exception 'Partner not found.';
  end if;
  if exists (select 1 from public.match_players
              where match_id = p_match and player_id = p_partner) then
    raise exception 'That partner is already in this match.';
  end if;
  if exists (select 1 from public.match_invites
              where match_id = p_match and invitee_id = p_partner
                and status = 'pending') then
    raise exception 'They already have a pending invite to this match.';
  end if;

  insert into public.match_invites (match_id, inviter_id, invitee_id, team)
  values (p_match, v_uid, p_partner, p_team)
  returning id into v_invite;

  select name into v_name from public.profiles where id = v_uid;
  select scheduled_at, match_type into v_when, v_type
    from public.matches where id = p_match;

  insert into public.notifications (user_id, type, title, body, data)
  values (p_partner, 'match', 'Partner invite',
          coalesce(v_name, 'A player') || ' wants you as their partner on ' ||
            to_char(v_when, 'Dy DD Mon') || ' at ' || to_char(v_when, 'HH24:MI') ||
            '. Accept to join the match.',
          jsonb_build_object('match_id', p_match, 'invite_id', v_invite,
                             'action', 'partner_invite'));
end $$;
grant execute on function public._invite_partner(uuid, uuid, text) to authenticated;

-- ── answering an invite ───────────────────────────────────────────────────

create or replace function public.respond_match_invite(
  p_invite uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_inv     public.match_invites;
  v_status  text;
  v_when    timestamptz;
  v_name    text;
  v_taken   int;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select * into v_inv from public.match_invites where id = p_invite for update;
  if not found then return 'Invite not found.'; end if;
  if v_inv.invitee_id <> v_uid then return 'This invite isn''t yours.'; end if;
  if v_inv.status <> 'pending' then
    return 'You already answered this invite.';
  end if;

  select name into v_name from public.profiles where id = v_uid;

  -- ── decline: free the slot, tell the inviter ──
  if not coalesce(p_accept, false) then
    update public.match_invites
       set status = 'declined', responded_at = now() where id = p_invite;
    insert into public.notifications (user_id, type, title, body, data)
    values (v_inv.inviter_id, 'match', 'Partner invite declined',
            coalesce(v_name, 'Your partner') ||
              ' can''t make it — the spot is open to anyone now.',
            jsonb_build_object('match_id', v_inv.match_id));
    return null;
  end if;

  -- ── accept: re-check everything, the world moved while they thought ──
  select status, scheduled_at into v_status, v_when
    from public.matches where id = v_inv.match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status = 'cancelled' then return 'That match was cancelled.'; end if;
  if v_status <> 'open'     then return 'This match is no longer open.'; end if;
  if now() >= v_when        then return 'That match has already started.'; end if;

  if exists (select 1 from public.match_players
              where match_id = v_inv.match_id and player_id = v_uid) then
    update public.match_invites
       set status = 'accepted', responded_at = now() where id = p_invite;
    return null;
  end if;

  -- Our own reservation is one of these seats, so exclude it before counting.
  if (select count(*) from public.match_players
       where match_id = v_inv.match_id and team = v_inv.team) >= 2 then
    update public.match_invites
       set status = 'cancelled', responded_at = now() where id = p_invite;
    return 'That spot was taken before you answered.';
  end if;

  -- Suppress the generic "someone joined" ping: we send a tailored one below.
  perform set_config('padel.invite_accept', '1', true);
  insert into public.match_players (match_id, player_id, team)
  values (v_inv.match_id, v_uid, v_inv.team);

  update public.match_invites
     set status = 'accepted', responded_at = now() where id = p_invite;

  insert into public.notifications (user_id, type, title, body, data)
  values (v_inv.inviter_id, 'match', 'Partner confirmed',
          coalesce(v_name, 'Your partner') || ' accepted and is in the match.',
          jsonb_build_object('match_id', v_inv.match_id));

  select count(*) into v_taken from public.match_players
   where match_id = v_inv.match_id;
  if v_taken >= 4 then
    update public.matches set status = 'full' where id = v_inv.match_id;
  end if;
  return null;
end $$;
grant execute on function public.respond_match_invite(uuid, boolean) to authenticated;

-- The invitee's own list, for the inbox. Dead invites (match started, closed or
-- cancelled) are filtered out by the same rule that stops them reserving.
create or replace function public.my_match_invites()
returns table (
  invite_id      uuid,
  match_id       uuid,
  inviter_id     uuid,
  inviter_name   text,
  inviter_avatar text,
  match_type     text,
  scheduled_at   timestamptz,
  venue          text,
  court          text,
  team           text,
  created_at     timestamptz
)
language sql stable security definer set search_path = public as $$
  select i.id, i.match_id, i.inviter_id, p.name, p.avatar_url,
         m.match_type, m.scheduled_at, c.venue_name, c.name, i.team, i.created_at
    from public.match_invites i
    join public.matches  m on m.id = i.match_id
    join public.profiles p on p.id = i.inviter_id
    left join public.courts c on c.id = m.court_id
   where i.invitee_id = auth.uid()
     and i.status = 'pending'
     and m.status = 'open'
     and now() < m.scheduled_at
   order by m.scheduled_at asc;
$$;
grant execute on function public.my_match_invites() to authenticated;

-- What the lobby renders in a reserved slot. Name only — never a phone number;
-- that is the whole point of this change.
create or replace function public.match_pending_invites(p_match uuid)
returns table (
  invite_id      uuid,
  invitee_id     uuid,
  invitee_name   text,
  invitee_avatar text,
  team           text,
  is_me          boolean
)
language sql stable security definer set search_path = public as $$
  select i.id, i.invitee_id, p.name, p.avatar_url, i.team,
         (i.invitee_id = auth.uid())
    from public.match_invites i
    join public.profiles p on p.id = i.invitee_id
    join public.matches  m on m.id = i.match_id
   where i.match_id = p_match
     and i.status = 'pending'
     and m.status = 'open'
     and now() < m.scheduled_at
     and (exists (select 1 from public.match_players mp
                   where mp.match_id = p_match and mp.player_id = auth.uid())
          or i.invitee_id = auth.uid()
          or i.inviter_id = auth.uid());
$$;
grant execute on function public.match_pending_invites(uuid) to authenticated;

-- ── create_match: partner becomes an invite ───────────────────────────────

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

  -- The partner is ASKED, not added. They hold the second team-A slot while
  -- they decide; nothing about them is exposed until they accept.
  if p_partner_id is not null and p_partner_id <> v_uid then
    perform public._invite_partner(v_id, p_partner_id, 'a');
  end if;

  return v_id;
end $$;
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- ── join_match: same treatment, and respect reserved slots ────────────────

create or replace function public.join_match(
  p_match_id uuid, p_team text default null, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_elo int;
  v_my_elo int;
  v_partner_elo int;
  v_team text;
  v_team_a int;
  v_team_b int;
  v_need int;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, min_elo into v_status, v_min_elo
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  select coalesce(elo, 1000) into v_my_elo from profiles where id = v_uid;
  if v_my_elo < v_min_elo then
    return 'This match requires ' || v_min_elo || '+ ELO.';
  end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null; -- already in: treat as success
  end if;

  -- Bringing a partner: validate them before we touch anything.
  if p_partner_id is not null then
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    select coalesce(elo, 1000) into v_partner_elo from profiles where id = p_partner_id;
    if not found then return 'Partner not found.'; end if;
    if v_partner_elo < v_min_elo then
      return 'Your partner needs ' || v_min_elo || '+ ELO for this match.';
    end if;
  end if;

  -- Capacity now counts reserved slots, so a stranger can't take the seat a
  -- host is holding for their invited partner.
  v_need  := case when p_partner_id is not null then 2 else 1 end;
  v_count := public._match_taken(p_match_id);
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match is already full.' end;
  end if;

  v_team_a := public._team_taken(p_match_id, 'a');
  v_team_b := public._team_taken(p_match_id, 'b');

  if p_partner_id is not null then
    -- A pair needs one side with two open slots.
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    -- auto-balance teams unless caller asked for one
    v_team := coalesce(p_team, case when v_team_a <= v_team_b then 'a' else 'b' end);
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      return 'This match is already full.';
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  -- Raises (and rolls back this join) if the partner can't be invited.
  if p_partner_id is not null then
    perform public._invite_partner(p_match_id, p_partner_id, v_team);
  end if;

  -- Only real players fill a match; a held slot keeps it 'open'.
  if (select count(*) from match_players where match_id = p_match_id) >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;
grant execute on function public.join_match(uuid, text, uuid) to authenticated;

-- ── mm_accept: same treatment ─────────────────────────────────────────────

create or replace function public.mm_accept(p_match_id uuid, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_status     text;
  v_created_by uuid;
  v_center     numeric;
  v_created_at timestamptz;
  v_my_rating  numeric;
  v_my_plac    boolean;
  v_cr_plac    boolean;
  v_count      int;
  v_team_a     int;
  v_team_b     int;
  v_team       text;
  v_need       int;
  v_hw         numeric;
  v_partner_rating numeric;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at
    into v_status, v_created_by, v_center, v_created_at
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null;
  end if;

  if p_partner_id is not null then
    if v_created_by = p_partner_id then
      return 'That player created this match.';
    end if;
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    if not exists (select 1 from profiles where id = p_partner_id) then
      return 'Partner not found.';
    end if;
  end if;

  v_need  := case when p_partner_id is not null then 2 else 1 end;
  v_count := public._match_taken(p_match_id);
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match just filled up.' end;
  end if;

  select coalesce(rating, level, 2.0), (coalesce(placement_played, 0) < 5)
    into v_my_rating, v_my_plac from profiles where id = v_uid;
  select (coalesce(placement_played, 0) < 5) into v_cr_plac
    from profiles where id = v_created_by;

  if v_my_plac or v_cr_plac then
    if not (v_my_plac and v_cr_plac) then
      return 'This match is outside your matchmaking pool.';
    end if;
  else
    v_hw := public.mm_band_halfwidth(extract(epoch from (now() - v_created_at)) / 60.0);
    if abs(v_my_rating - v_center) > v_hw then
      return 'This match is outside your rating band.';
    end if;
    if p_partner_id is not null then
      select coalesce(rating, level, 2.0) into v_partner_rating
        from profiles where id = p_partner_id;
      if abs(coalesce(v_partner_rating, 2.0) - v_center) > v_hw then
        return 'Your partner is outside this match''s rating band.';
      end if;
    end if;
  end if;

  v_team_a := public._team_taken(p_match_id, 'a');
  v_team_b := public._team_taken(p_match_id, 'b');

  if p_partner_id is not null then
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    v_team := case when v_team_a <= v_team_b then 'a' else 'b' end;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      return 'This match just filled up.';
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  -- Raises (and rolls back this join) if the partner can't be invited.
  if p_partner_id is not null then
    perform public._invite_partner(p_match_id, p_partner_id, v_team);
  end if;

  if (select count(*) from match_players where match_id = p_match_id) >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- ── leaving / cancelling drops the invites you raised ─────────────────────

create or replace function public.leave_match(p_match_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select status into v_status from matches where id = p_match_id for update;
  if v_status in ('completed', 'in_progress') then
    return 'You can''t leave a match that already started.';
  end if;
  delete from match_players where match_id = p_match_id and player_id = v_uid;

  -- Anyone you were still waiting on stops being waited on.
  update public.match_invites
     set status = 'cancelled', responded_at = now()
   where match_id = p_match_id and inviter_id = v_uid and status = 'pending';

  update matches set status = 'open' where id = p_match_id and status = 'full';
  -- if the creator left and nobody is in the match, cancel it
  delete from matches m where m.id = p_match_id
    and not exists (select 1 from match_players mp where mp.match_id = m.id);
  return null;
end $$;
grant execute on function public.leave_match(uuid) to authenticated;

create or replace function public.cancel_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_creator uuid; v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select created_by, status into v_creator, v_status
    from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_creator <> v_uid and not public._is_admin() then
    return 'Only the host can cancel this match.';
  end if;
  if v_status in ('completed', 'cancelled') then
    return 'This match is already ' || v_status || '.';
  end if;
  update public.matches set status = 'cancelled' where id = p_match_id;

  -- Tell anyone still holding an invite, then close it.
  insert into public.notifications (user_id, type, title, body, data)
  select i.invitee_id, 'match', 'Match cancelled',
         'The match you were invited to was cancelled.',
         jsonb_build_object('match_id', p_match_id)
    from public.match_invites i
   where i.match_id = p_match_id and i.status = 'pending';
  update public.match_invites
     set status = 'cancelled', responded_at = now()
   where match_id = p_match_id and status = 'pending';

  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Match cancelled',
         'The host cancelled this match.', jsonb_build_object('match_id', p_match_id)
    from public.match_players mp
   where mp.match_id = p_match_id and mp.player_id <> v_uid;
  return null;
end $$;
grant execute on function public.cancel_match(uuid) to authenticated;

-- ── the join notification ─────────────────────────────────────────────────
-- An accepted invite sends its own tailored "Partner confirmed", so the generic
-- "someone joined your match" is suppressed for that insert. The old
-- `padel.partner_add` branch is left in place but is now unreachable from
-- create/join/mm_accept — nothing adds a partner directly any more.

create or replace function public.notify_match_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_host        uuid;
  v_joiner      text;
  v_host_name   text;
  v_partner_add boolean;
begin
  if coalesce(current_setting('padel.invite_accept', true), '') = '1' then
    return new;
  end if;

  select created_by into v_host from public.matches where id = new.match_id;
  if v_host is null then return new; end if;

  v_partner_add := coalesce(current_setting('padel.partner_add', true), '') = '1';

  if v_partner_add then
    if new.player_id <> v_host then
      select name into v_host_name from public.profiles where id = v_host;
      insert into public.notifications (user_id, type, title, body, data)
      values (new.player_id, 'match', 'You were added to a match',
              coalesce(v_host_name, 'A player') || ' added you to their match.',
              jsonb_build_object('match_id', new.match_id));
    end if;
    return new;
  end if;

  if new.player_id <> v_host then
    select name into v_joiner from public.profiles where id = new.player_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (v_host, 'match', 'Someone joined your match',
            coalesce(v_joiner, 'A player') || ' joined your match.',
            jsonb_build_object('match_id', new.match_id));
  end if;
  return new;
end $$;

-- ── the ticket opens when an opponent shows up ────────────────────────────
-- Was: a trigger on `matches` INSERT, so the thread (and every number in it)
-- existed before anyone else had joined. Now it opens on the join that first
-- puts a player on both sides.

create or replace function public.open_match_ticket_on_join()
returns trigger language plpgsql security definer set search_path = public as $$
begin
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

drop trigger if exists trg_open_match_ticket on public.matches;
drop trigger if exists trg_open_match_ticket_join on public.match_players;
create trigger trg_open_match_ticket_join
  after insert on public.match_players
  for each row execute function public.open_match_ticket_on_join();

-- Retire tickets the old backfill opened for one-sided matches. Only ones with
-- no messages — an existing conversation is never deleted.
delete from public.match_tickets t
 where not exists (select 1 from public.ticket_messages tm where tm.ticket_id = t.id)
   and not (exists (select 1 from public.match_players mp
                     where mp.match_id = t.match_id and mp.team = 'a')
        and exists (select 1 from public.match_players mp
                     where mp.match_id = t.match_id and mp.team = 'b'));

-- Open one for any match that already has both sides but lost its ticket above
-- (or never got one because it filled before this change).
insert into public.match_tickets (match_id)
select m.id from public.matches m
 where m.status <> 'cancelled'
   and now() < m.scheduled_at + interval '24 hours'
   and exists (select 1 from public.match_players mp
                where mp.match_id = m.id and mp.team = 'a')
   and exists (select 1 from public.match_players mp
                where mp.match_id = m.id and mp.team = 'b')
on conflict (match_id) do nothing;

notify pgrst, 'reload schema';
