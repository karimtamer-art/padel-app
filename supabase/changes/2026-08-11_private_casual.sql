-- 2026-08-11 — Private casual matches + invite codes. Safe to re-run.
--
-- `matches.is_private` and `matches.invite_code` have existed since the first
-- migration and were DEAD: every match got a PDL- code, nothing ever read it,
-- no discovery path filtered on is_private, and no join path asked for a code.
-- This makes both real.
--
-- THE RULE
--   A private match is invisible and unjoinable without its code.
--   A public match has no code at all.
--
-- Private is CASUAL-ONLY on purpose. A ranked match moves everybody's rating,
-- so it stays open to the band — a private ranked lobby is how you'd farm
-- rating off a chosen opponent.
--
-- WHERE THE DOOR IS LOCKED. `matches` RLS is participant-read, so a stranger
-- cannot read a private match row and never sees it. That leaves three ways in,
-- and all three are closed here:
--   * mm_candidates       — the browse/matchmaking list (also feeds
--                           mm_count_candidates, which selects from it)
--   * mm_player_sees_match— the push fan-out. Missing this would announce a
--                           private match to strangers, which is the leak the
--                           feature exists to prevent.
--   * join_match / mm_accept — the two RPCs that take a match id directly. A
--                           client can pass any uuid, so neither may trust that
--                           it came from a list we filtered.
-- respond_match_invite is deliberately NOT gated: being invited is its own
-- permission, and an invited partner never sees a code.

-- ── code generation ───────────────────────────────────────────────────────
-- Charset excludes 0/O/1/I/L — these get read aloud and typed by hand, and
-- those four are where that goes wrong. matches_invite_code_key (a partial
-- unique index) is the real guard; the loop just retries a collision.
create or replace function public._new_invite_code()
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  charset constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  i int;
begin
  for attempt in 1..20 loop
    v_code := 'PDL-';
    for i in 1..5 loop
      v_code := v_code || substr(charset, 1 + floor(random() * length(charset))::int, 1);
    end loop;
    if not exists (select 1 from public.matches where invite_code = v_code) then
      return v_code;
    end if;
  end loop;
  -- 31^5 is ~28.6M codes; twenty collisions means something is very wrong.
  raise exception 'Could not allocate an invite code.';
end $$;

-- ── create_match: private is casual-only, and only private gets a code ────
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
  v_uid     uuid := auth.uid();
  v_id      uuid;
  v_private boolean;
begin
  if v_uid is null then raise exception 'Not signed in.'; end if;
  if p_scheduled_at is null then raise exception 'Pick a time for the match.'; end if;

  -- p_open is IGNORED for ranked rather than rejected: an older client that
  -- still sends it shouldn't fail to create a match over a flag it doesn't
  -- know is casual-only.
  v_private := (not coalesce(p_open, true)) and not coalesce(p_competitive, false);

  insert into public.matches
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_elo, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     v_private,
     coalesce(p_min_elo, 0),
     case when v_private then public._new_invite_code() else null end)
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

-- ── may this caller join a private match? ─────────────────────────────────
-- Either they were invited, or they redeemed the code THIS transaction.
-- The GUC mirrors the padel.invite_accept pattern already used by
-- respond_match_invite: set by the trusted RPC, invisible to a client, and
-- gone when the transaction ends.
create or replace function public._may_join_private(p_match uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(current_setting('padel.join_code_ok', true), '') = p_match::text then
    return true;
  end if;
  return public._invited_to_match(p_match);
end $$;

-- ── join_match: refuse a private match without the code ───────────────────
-- Only the guard is new; everything else is byte-for-byte the previous body.
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
  v_private boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, min_elo, is_private into v_status, v_min_elo, v_private
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if coalesce(v_private, false) and not public._may_join_private(p_match_id) then
    return 'This match is private — you need its invite code.';
  end if;

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

-- ── join by code ──────────────────────────────────────────────────────────
-- Returns (match_id, error). match_id is non-null whenever the caller ends up
-- in the match — including when they were already in it, so scanning the same
-- code twice navigates instead of erroring.
--
-- "No match with that code" covers wrong, expired and already-started codes
-- ON PURPOSE. Distinguishing them turns this into an oracle for probing which
-- codes exist.
create or replace function public.join_match_by_code(
  p_code text, p_partner_id uuid default null)
returns table (match_id uuid, error text)
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_code text;
  v_id   uuid;
  v_err  text;
begin
  if v_uid is null then
    return query select null::uuid, 'Not signed in.'::text; return;
  end if;

  -- Accept "pdl-ab12c", "PDL-AB12C", " AB12C " — people retype these from a
  -- screenshot or a voice note, so normalise rather than scold.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_code like 'PDL%' then v_code := substr(v_code, 4); end if;
  if length(v_code) <> 5 then
    return query select null::uuid, 'That code doesn''t look right — it''s 5 characters, like PDL-AB12C.'::text;
    return;
  end if;
  v_code := 'PDL-' || v_code;

  select id into v_id
    from public.matches
   where invite_code = v_code
     and is_private
     and status = 'open'
     and scheduled_at > now();
  if v_id is null then
    return query select null::uuid, 'No match with that code. Check it with whoever invited you.'::text;
    return;
  end if;

  -- Unlock the private guard for this transaction only, scoped to THIS match
  -- so it can't be leaned on to enter a different one.
  perform set_config('padel.join_code_ok', v_id::text, true);
  v_err := public.join_match(v_id, null, p_partner_id);
  perform set_config('padel.join_code_ok', '', true);

  if v_err is not null then
    return query select null::uuid, v_err; return;
  end if;
  return query select v_id, null::text;
end $$;
grant execute on function public.join_match_by_code(text, uuid) to authenticated;

-- ── mm_accept: the other direct-join RPC ──────────────────────────────────
-- It does its own band check rather than going through mm_player_sees_match,
-- so filtering the list functions does not cover it. A client can pass any
-- uuid here. Only the is_private read and the guard below it are new.
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
  v_private    boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at, is_private
    into v_status, v_created_by, v_center, v_created_at, v_private
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if coalesce(v_private, false) and not public._may_join_private(p_match_id) then
    return 'This match is private — you need its invite code.';
  end if;

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

-- ── discovery: private matches are not offered ────────────────────────────
-- mm_count_candidates selects from mm_candidates, so it needs no change.
create or replace function public.mm_candidates(
  p_limit int default 10,
  p_from  timestamptz default null,
  p_to    timestamptz default null
)
returns table (
  match_id        uuid,
  scheduled_at    timestamptz,
  match_type      text,
  court_name      text,
  venue_name      text,
  city            text,
  creator_id      uuid,
  creator_name    text,
  creator_rating  numeric,
  creator_level   numeric,
  players         int,
  center_rating   numeric,
  level_match_pct int
) language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric; v_uid uuid := auth.uid();
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = v_uid;
  v_window := coalesce((select value::numeric from public.app_settings
                         where key = 'mm_time_window_hours'), 12);

  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         cp.id, cp.name, cp.rating, cp.level,
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0),
         greatest(0, 100 - round(abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) * 40))::int
    from public.matches m
    join public.profiles cp on cp.id = m.created_by
    left join public.courts c on c.id = m.court_id
   where m.status = 'open'
     and not coalesce(m.is_private, false)   -- private: code only
     and m.created_by <> v_uid
     and m.scheduled_at > now() - public.mm_grace()
     and (
       case when p_from is null and p_to is null
         then m.scheduled_at < now() + (v_window * interval '1 hour')
         else m.scheduled_at >= greatest(now(), coalesce(p_from, now()))
              and m.scheduled_at <= coalesce(p_to, now() + interval '365 days')
       end
     )
     and (select count(*) from public.match_players mp2 where mp2.match_id = m.id) < 4
     and not exists (select 1 from public.match_players mp3
                      where mp3.match_id = m.id and mp3.player_id = v_uid)
     and (
       m.match_type = 'casual'
       or case when v_plac
         then coalesce(cp.placement_played, 0) < 5
         else coalesce(cp.placement_played, 0) >= 5
              and abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0))
                  <= public.mm_band_halfwidth(extract(epoch from (now() - m.created_at)) / 60.0)
       end
     )
     and (v_city is null or coalesce(c.city, cp.city) is null or coalesce(c.city, cp.city) = v_city)
   order by abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) asc,
            m.scheduled_at asc
   limit p_limit;
end $$;
grant execute on function public.mm_candidates(int, timestamptz, timestamptz) to authenticated;

-- ── push fan-out must not announce a private match ────────────────────────
-- Only the is_private read and the one early return are new; the rest of the
-- body is unchanged. Without this the "new match near you" notification tells
-- strangers a private match exists, which is precisely what the host asked us
-- not to do.
create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
  v_type text; v_private boolean;
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = p_player;
  if not found then return false; end if;

  select m.status, m.created_by, coalesce(m.mm_center_rating, 2.0), m.created_at,
         m.scheduled_at, m.court_id, m.match_type, m.is_private
    into v_status, v_cby, v_center, v_created, v_sched, v_court, v_type, v_private
    from public.matches m where m.id = p_match;
  if not found or v_status <> 'open' or v_cby = p_player then return false; end if;
  if coalesce(v_private, false) then return false; end if;  -- code only
  if v_sched <= now() - public.mm_grace() then return false; end if;  -- past grace

  v_window := coalesce((select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);
  if v_sched >= now() + (v_window * interval '1 hour') then return false; end if;

  select count(*) into v_count from public.match_players where match_id = p_match;
  if v_count >= 4 then return false; end if;
  if exists (select 1 from public.match_players where match_id = p_match and player_id = p_player) then
    return false;
  end if;

  select (coalesce(placement_played, 0) < 5), city into v_cplac, v_ccity
    from public.profiles where id = v_cby;
  select city into v_courtcity from public.courts where id = v_court;

  -- Casual is unrated: no band, no placement/placed split (see mm_candidates).
  if v_type is distinct from 'casual' then
    if v_plac or v_cplac then
      if not (v_plac and v_cplac) then return false; end if;
    elsif abs(v_rating - v_center)
          > public.mm_band_halfwidth(extract(epoch from (now() - v_created)) / 60.0) then
      return false;
    end if;
  end if;

  if v_city is not null and coalesce(v_courtcity, v_ccity) is not null
     and coalesce(v_courtcity, v_ccity) <> v_city then
    return false;
  end if;
  return true;
end $$;
