-- 2026-08-11 — Casual matches are joinable by anyone. Safe to re-run.
--
-- BUG: a placed player tapping Join on an UNPLACED host's casual match got
-- "This match is outside your matchmaking pool." The card was offered to them
-- and then refused.
--
-- Casual is UNRATED, so neither the rating band nor the placed/unplaced split
-- is supposed to apply. Two of the three functions knew that:
--
--   mm_candidates        and (m.match_type = 'casual' or <band+placement>)
--   mm_player_sees_match if v_type is distinct from 'casual' then <same> end if
--   mm_accept            -- never looked at match_type at all
--
-- mm_accept is the one the Join button calls, which is why the match appeared
-- (mm_candidates said yes) and the join failed (mm_accept said no). It doesn't
-- even select match_type. This adds the same exemption the other two carry.
--
-- Keeps the private-match guard from 2026-08-11_private_casual.sql. This file
-- can be run before OR after that one — it is a full create-or-replace either
-- way, and _may_join_private is created there.

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
  v_type       text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at,
         is_private, match_type
    into v_status, v_created_by, v_center, v_created_at, v_private, v_type
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

  -- ── THE FIX ────────────────────────────────────────────────────────────
  -- Casual is unrated: no band, no placed/unplaced split. Mirrors the clause
  -- mm_candidates and mm_player_sees_match have always had. Skipping the whole
  -- block (not just the split) matters — the band check underneath would
  -- refuse a casual match on rating distance instead, which is the same bug
  -- wearing a different error message.
  if v_type is distinct from 'casual' then
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
