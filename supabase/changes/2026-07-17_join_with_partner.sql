-- 2026-07-17 · Join solo vs. with a partner + notify the added partner.
--
-- Three related fixes to the match/partner flow:
--   1. When you ADD a partner (creating a match, or joining one with a partner),
--      that partner now gets a notification. Previously the host got a spurious
--      "X joined your match" and the partner got nothing.
--   2. join_match / mm_accept accept an optional partner — you and your partner
--      take one side together, or you join solo and get paired randomly.
--
-- The adder sets a transaction-local GUC `padel.partner_add` right before the
-- partner INSERT; the notify trigger reads it and routes the ping to the partner
-- instead of the host. Safe to re-run (idempotent); also folded into
-- migration_player_app.sql.

-- ── create_match: flag the partner insert ───────────────────────────────────
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
    perform set_config('padel.partner_add', '1', true);
    insert into public.match_players (match_id, player_id, team) values (v_id, p_partner_id, 'a');
  end if;

  return v_id;
end $$;
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- ── join_match: optional partner (both take one side) ───────────────────────
drop function if exists public.join_match(uuid, text);
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
    return null;
  end if;

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

  v_need := case when p_partner_id is not null then 2 else 1 end;
  select count(*) into v_count from match_players where match_id = p_match_id;
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match is already full.' end;
  end if;

  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;

  if p_partner_id is not null then
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    v_team := coalesce(p_team, case when v_team_a <= v_team_b then 'a' else 'b' end);
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  if p_partner_id is not null then
    perform set_config('padel.partner_add', '1', true);
    insert into match_players (match_id, player_id, team) values (p_match_id, p_partner_id, v_team);
  end if;

  if v_count + v_need >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;
grant execute on function public.join_match(uuid, text, uuid) to authenticated;

-- ── mm_accept: optional partner (band-checks you only, not the friend) ──────
drop function if exists public.mm_accept(uuid);
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

  v_need := case when p_partner_id is not null then 2 else 1 end;
  select count(*) into v_count from match_players where match_id = p_match_id;
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

  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;

  if p_partner_id is not null then
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    v_team := case when v_team_a <= v_team_b then 'a' else 'b' end;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  if p_partner_id is not null then
    perform set_config('padel.partner_add', '1', true);
    insert into match_players (match_id, player_id, team) values (p_match_id, p_partner_id, v_team);
  end if;

  if v_count + v_need >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- ── notify trigger: ping the partner on a partner-add, else the host ────────
create or replace function public.notify_match_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_host        uuid;
  v_joiner      text;
  v_host_name   text;
  v_partner_add boolean;
begin
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

  if v_host = new.player_id then return new; end if;
  select name into v_joiner from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_host, 'match', 'New player joined',
          coalesce(v_joiner, 'A player') || ' joined your match.',
          jsonb_build_object('match_id', new.match_id));
  return new;
end $$;

notify pgrst, 'reload schema';
