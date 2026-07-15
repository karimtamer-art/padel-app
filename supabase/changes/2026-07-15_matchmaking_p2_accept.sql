-- 2026-07-15 · Matchmaking Phase 2 — race-safe accept with band re-check
--
-- The "Accept" on a surfaced candidate. Like join_match, but it is the
-- matchmaking entry point and therefore RE-VERIFIES the band server-side — a
-- client can call this with ANY match_id, so we never trust that the id came
-- from mm_candidates. Placement players may only accept placement matches;
-- placed players must fall inside the (age-widened) band. First accepter wins
-- the slot (row lock); a late accepter on a now-full match gets a clean error.
--
-- Depends on: mm_band_halfwidth (P0), matches.mm_center_rating + created_at (P1).
-- Idempotent. Also folded into migration_player_app.sql.

create or replace function public.mm_accept(p_match_id uuid)
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
begin
  if v_uid is null then return 'Not signed in.'; end if;

  -- Lock the match row so two accepters can't both take the last slot.
  select status, created_by, coalesce(mm_center_rating, 2.0), created_at
    into v_status, v_created_by, v_center, v_created_at
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null; -- already in: treat as success
  end if;

  select count(*) into v_count from match_players where match_id = p_match_id;
  if v_count >= 4 then return 'This match just filled up.'; end if;

  -- Band re-check (anti-cheat: never trust the caller's match_id).
  select coalesce(rating, level, 2.0), (coalesce(placement_played, 0) < 5)
    into v_my_rating, v_my_plac from profiles where id = v_uid;
  select (coalesce(placement_played, 0) < 5) into v_cr_plac
    from profiles where id = v_created_by;

  if v_my_plac or v_cr_plac then
    if not (v_my_plac and v_cr_plac) then
      return 'This match is outside your matchmaking pool.';
    end if;
  elsif abs(v_my_rating - v_center)
        > public.mm_band_halfwidth(extract(epoch from (now() - v_created_at)) / 60.0) then
    return 'This match is outside your rating band.';
  end if;

  -- Auto-balance onto the emptier team.
  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;
  v_team := case when v_team_a <= v_team_b then 'a' else 'b' end;
  if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
    v_team := case v_team when 'a' then 'b' else 'a' end;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  if v_count + 1 >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;

grant execute on function public.mm_accept(uuid) to authenticated;

notify pgrst, 'reload schema';
