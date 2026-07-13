-- ============================================================================
-- TEST SEED — finish placement for 4 players (rating engine v2)
-- ----------------------------------------------------------------------------
-- Runs 5 *settled* ranked doubles matches through the real _settle_rating()
-- engine, so every one of the 4 players ends at 5/5 placement with a real
-- rating / sigma / tier and 5 ranking_history rows (fuels the ELO chart).
--
-- Safe to read, NOT idempotent: each run ADDS 5 more matches. Run it ONCE.
-- (placement_played caps at 5, but competitive_matches + rating keep moving.)
-- Cleanup block at the very bottom removes what this created.
--
-- Run in the Supabase SQL editor. Then run PART 2 to see the results.
-- ============================================================================

-- ── PART 1: seed ────────────────────────────────────────────────────────────
do $$
declare
  v_p    uuid[];              -- the 4 players (index 1..4)
  v_creator uuid;
  v_mid  uuid;
  -- match plan (team-A perspective). Indices 0..3 map to v_p[1..4].
  -- Partners rotate every match so ratings spread instead of moving in lockstep.
  v_plan jsonb := '[
    {"ta":[0,1],"tb":[2,3],"w":"a","s":"6-4,6-3"},
    {"ta":[0,2],"tb":[1,3],"w":"a","s":"6-2,6-4"},
    {"ta":[1,3],"tb":[0,2],"w":"a","s":"7-5,6-4"},
    {"ta":[0,3],"tb":[1,2],"w":"a","s":"6-1,6-2"},
    {"ta":[1,2],"tb":[0,3],"w":"a","s":"6-4,3-6,6-3"}
  ]'::jsonb;
  v_row jsonb; i int; v_idx int; v_code text; v_n int := 0;
begin
  -- The 4 players to place (provided 2026-07-13). Clear this to auto-pick instead.
  v_p := array[
    'af52b527-d0c5-4cbf-9661-320780182fda',
    '6576d16d-b625-4f51-b80f-6f2d00590c02',
    '30007fb3-4215-4ad1-9863-0df86d05b9cf',
    '5eb2f3bf-49d7-43e6-bfe8-e30ad9a5117b'
  ]::uuid[];

  -- Otherwise auto-pick the 4 users who have already played the most matches.
  if v_p is null then
    select array_agg(id) into v_p from (
      select p.id
        from profiles p
        left join match_players mp on mp.player_id = p.id
       group by p.id
       order by count(mp.match_id) desc, p.id
       limit 4
    ) q;
  end if;

  if v_p is null or array_length(v_p, 1) < 4 then
    raise exception 'Need at least 4 profiles; found %', coalesce(array_length(v_p,1),0);
  end if;

  v_creator := v_p[1];

  for v_row in select * from jsonb_array_elements(v_plan) loop
    v_n   := v_n + 1;
    v_code := 'TSTPL-' || v_n;                     -- tag for easy cleanup
    delete from matches where invite_code = v_code; -- allow a clean re-run

    insert into matches (status, match_type, scheduled_at, created_by,
                         is_private, min_elo, winner_team,
                         score_team_a, score_team_b, rating_applied, invite_code)
    values ('completed', 'ranked', now() - interval '1 hour', v_creator,
            false, 0, v_row->>'w',
            v_row->>'s', null, false, v_code)
    returning id into v_mid;

    for i in 0..1 loop
      v_idx := (v_row->'ta'->>i)::int;
      insert into match_players(match_id, player_id, team) values (v_mid, v_p[v_idx+1], 'a');
    end loop;
    for i in 0..1 loop
      v_idx := (v_row->'tb'->>i)::int;
      insert into match_players(match_id, player_id, team) values (v_mid, v_p[v_idx+1], 'b');
    end loop;

    perform public._settle_rating(v_mid);          -- the real engine settles it
  end loop;

  raise notice 'Seeded 5 ranked matches for players %', v_p;
end $$;

-- ── PART 2: verify the ranks (run this after PART 1) ────────────────────────
select p.name,
       p.rating,
       public.tier_from_level(p.rating)              as tier,
       p.sigma,
       p.competitive_matches,
       p.placement_played,
       p.is_provisional,
       (select count(*) from ranking_history rh where rh.profile_id = p.id) as history_rows
  from profiles p
 where p.id in (
   select mp.player_id
     from match_players mp
     join matches m on m.id = mp.match_id
    where m.invite_code like 'TSTPL-%'
   group by mp.player_id
 )
 order by p.rating desc;

-- ── CLEANUP (optional) — undo this seed ─────────────────────────────────────
-- Removes the 5 test matches + their players + ranking_history rows.
-- Note: it does NOT roll back the rating/placement changes already applied to
-- profiles (settlement is one-way). Re-seed only on players you don't mind
-- re-rating, or reset those profiles' rating/sigma/competitive_matches/
-- placement_played manually.
--
-- delete from ranking_history rh using matches m
--   where rh.match_id = m.id and m.invite_code like 'TSTPL-%';
-- delete from match_players mp using matches m
--   where mp.match_id = m.id and m.invite_code like 'TSTPL-%';
-- delete from matches where invite_code like 'TSTPL-%';
