-- ===========================================================================
-- mm_accept: the last two reads still pointed at profiles (2026-09-07)
--
-- SYMPTOM: tapping Join on a RANKED match answered
--     column "rating" does not exist
-- straight from Postgres, rendered raw in the radar's red snackbar
-- (matchmaking_hero.dart -> MatchService.acceptCandidate -> mm_accept).
--
-- CAUSE: 2026-08-15_player_ratings_p1.sql moved the 11 ranking columns off
-- `profiles` and rewrote every reader. mm_candidates and mm_player_sees_match
-- were converted completely. mm_accept was converted only where the rewrite
-- could see it -- the partner band-check -- and these two statements, which
-- sit inside the `if v_type is distinct from 'casual'` guard added by
-- 2026-08-11_casual_pool_fix.sql, were missed:
--
--     select coalesce(rating, level, public.rating_prior()), ...
--       into v_my_rating, v_my_plac from profiles where id = v_uid;
--     select (coalesce(placement_played, 0) < 5) into v_cr_plac
--       from profiles where id = v_created_by;
--
-- CASUAL matches never enter that branch, which is exactly why this stayed
-- hidden: the casual pool kept working and only ranked joins broke. Same
-- shape as matches_status_chk (2026-08-01) -- casual skipping the broken path
-- hid it -- and worth remembering as a pattern rather than a coincidence.
--
-- WHY THE p1 MIGRATION DID NOT CATCH IT: its own header promises that
-- "before the old columns are dropped, the catalog is swept for any function
-- still reading profiles.<ranking column>, and the migration ABORTS naming
-- it". That sweep was never written -- section 6 only checks row counts, that
-- the columns are gone, and the grants. Section 3 below is that missing
-- sweep, so the next miss is named instead of shipped.
--
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Preconditions. This delta assumes the ranking move has already run; on a
--    database where it has not, mm_accept must keep reading profiles.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'player_ratings') then
    raise exception 'player_ratings does not exist'
      using hint = 'run supabase/changes/2026-08-15_player_ratings_p1.sql first';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles'
                and column_name = 'rating') then
    raise exception 'profiles.rating still exists -- the ranking move did not finish'
      using hint = 're-run 2026-08-15_player_ratings_p1.sql before this delta';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. mm_accept, unchanged except for the two reads. Redefined whole because a
--    function cannot be patched in part.
-- ---------------------------------------------------------------------------
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
    -- Ranking state lives in player_ratings, NOT on profiles (2026-08-15).
    -- These two reads were the last in the schema still pointed at profiles;
    -- they made every RANKED join fail with `column "rating" does not exist`
    -- (2026-09-07). The partner read below was converted at the time; these
    -- were missed because they sit inside the casual guard.
    select coalesce(pr.rating, pr.level, public.rating_prior()),
           (coalesce(pr.placement_played, 0) < 5)
      into v_my_rating, v_my_plac
      from player_ratings pr where pr.player_id = v_uid;
    -- No row = a player the trigger never covered: unrated and unplaced, which
    -- is what the profiles read returned for a NULL column. Never NULL, or the
    -- placement branch below evaluates to NULL and waves them straight through.
    if not found then
      v_my_rating := public.rating_prior();
      v_my_plac   := true;
    end if;

    select (coalesce(pr.placement_played, 0) < 5) into v_cr_plac
      from player_ratings pr where pr.player_id = v_created_by;
    v_cr_plac := coalesce(v_cr_plac, true);

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
        select coalesce(rating, level, public.rating_prior()) into v_partner_rating
          from player_ratings where player_id = p_partner_id;
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

-- ---------------------------------------------------------------------------
-- 3. The sweep 2026-08-15_player_ratings_p1.sql promised and never wrote.
--
--    plpgsql bodies carry no dependency records -- that is precisely why the
--    column drop could not warn about mm_accept -- so the body text is what
--    there is to check. prosrc is split into statements and a statement is
--    flagged when it (a) reads FROM/JOIN profiles, (b) never mentions
--    player_ratings, and (c) names a ranking column. Verified against the
--    whole current schema: 0 hits after this delta, and exactly the 2
--    offending statements before it, so it neither over- nor under-reports.
--
--    If this aborts, section 2 has ALREADY committed -- each do-block is its
--    own statement -- so the mm_accept fix is not lost. A name you do not
--    recognise from this repo is live-only drift (see CLAUDE.md, "Live-DB
--    drift traps"): fix that function the same way, then re-run.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(distinct p.proname || '()', ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_split_to_table(p.prosrc, ';') as s(stmt)
   where n.nspname = 'public'
     and p.prokind = 'f'
     -- extension-owned functions are not ours to judge
     and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')
     and lower(regexp_replace(s.stmt, '--[^' || chr(10) || ']*', ' ', 'g'))
           ~ '(from|join)[[:space:]]+(public\.)?profiles([^a-z0-9_]|$)'
     and lower(s.stmt) !~ 'player_ratings'
     and lower(regexp_replace(s.stmt, '--[^' || chr(10) || ']*', ' ', 'g'))
           ~ ('[^a-z0-9_](rating|sigma|is_anchor|competitive_matches'
              || '|last_competitive_match_at|placement_played|placement_revealed'
              || '|is_provisional|reliability|tier|level)[^a-z0-9_]');
  if v_bad is not null then
    raise exception 'function(s) still read a ranking column from profiles: %', v_bad
      using hint = 'ranking state moved to player_ratings on 2026-08-15';
  end if;
  raise notice 'sweep: no function reads a ranking column from profiles.';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Verify: a ranked join now gets past the band check instead of aborting.
--    mm_accept is SECURITY DEFINER on auth.uid(), so it cannot be called
--    meaningfully from the SQL editor -- what is checkable is that the body now
--    sources the caller from the right table. The negative half of this (no
--    function reading a ranking column off profiles) is section 3, which
--    covers mm_accept generically, so it is not restated here.
-- ---------------------------------------------------------------------------
do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mm_accept'
     and pg_get_function_identity_arguments(p.oid) = 'p_match_id uuid, p_partner_id uuid';
  if v_src is null then
    raise exception 'mm_accept(uuid, uuid) not found after redefinition';
  end if;
  if v_src !~ 'from player_ratings pr where pr.player_id = v_uid' then
    raise exception 'mm_accept does not read the caller rating from player_ratings';
  end if;
  raise notice 'mm_accept: ranked joins read player_ratings. OK';
end $$;

notify pgrst, 'reload schema';
