-- ===========================================================================
-- One season ladder per region (2026-09-26)
--
-- Part of the tournament-first pivot. `2026-09-26_regions.sql` added
-- `seasons.region_id`; this delta makes the season ENGINE actually honour it.
--
-- ⚠️ RUN 2026-09-26_regions.sql FIRST. Section 1 refuses otherwise.
--
-- ── Why this is a correctness fix, not a feature ────────────────────────────
-- Two things in the schema assumed exactly one season existed at a time:
--
--   1. `seasons_one_live_key` -- a unique index on `(status) where status =
--      'live'` -- makes a second live season IMPOSSIBLE. One region per ladder
--      is not just unimplemented, it is structurally forbidden.
--
--   2. Six lookups shaped `select ... from seasons where status = 'live'
--      limit 1`. With one live season that is exact. With two it silently picks
--      an ARBITRARY one, so Egyptian match points could land in the UAE ladder
--      and nobody would get an error -- the points would simply be in the wrong
--      table rows, and `season_standings` would faithfully render the wrong
--      board. That is the kind of bug you find months later with no way to
--      reconstruct the truth.
--
-- So this had to land before a second region is ever seeded, not after.
--
-- `seasons_no_key` (unique on `no`) goes the same way: season numbers are now
-- per region, so Egypt and every later market each count 1, 2, 3.
--
-- ── Which region decides ────────────────────────────────────────────────────
-- Per-MATCH points resolve the season per PLAYER, from `profiles.region_id`.
-- Points are inserted per player anyway, and a player's ladder is their own
-- market's -- so two players from different regions in one match each score in
-- their own season. That also means `season_rules` (win/loss/streak/upset
-- values) must be read per season rather than once for the match, since two
-- regions can price a win differently.
--
-- TOURNAMENT placement points resolve from the TOURNAMENT's region, not the
-- player's: an event belongs to one market, and its title should not land in
-- two ladders because a visitor entered.
--
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Preconditions.
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'seasons'
       and column_name = 'region_id')
  then
    raise exception 'seasons.region_id is missing — run 2026-09-26_regions.sql first';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The two indexes that forbade more than one ladder.
--
--    Dropped by name and rebuilt scoped to the region. A database that somehow
--    already has two live seasons in one region will fail the create, which is
--    the correct outcome -- fix the data rather than drop the guarantee.
-- ---------------------------------------------------------------------------
drop index if exists public.seasons_one_live_key;
create unique index if not exists seasons_one_live_key
  on public.seasons (region_id) where status = 'live';

drop index if exists public.seasons_no_key;
create unique index if not exists seasons_no_key
  on public.seasons (region_id, no);

-- ---------------------------------------------------------------------------
-- 3. Helpers, so "the live season" is defined exactly once.
--
--    `_live_season` does NOT filter on `frozen`: viewing a frozen season is
--    fine, awarding into one is not, so that call stays with the award
--    functions that care. `order by starts_on desc` makes it deterministic even
--    if the unique index above is ever dropped again.
-- ---------------------------------------------------------------------------
create or replace function public._live_season(p_region text)
returns uuid language sql stable security definer set search_path = public as $$
  select s.id from public.seasons s
   where s.status = 'live'
     and s.region_id = coalesce(nullif(btrim(p_region), ''), 'EG')
   order by s.starts_on desc
   limit 1;
$$;

-- Defaults to 'EG' for a missing profile for the same reason everything else
-- does: Egypt is the only market that has actually run, so it is the correct
-- answer when there is no better one.
create or replace function public._player_region(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(p.region_id, 'EG') from public.profiles p where p.id = p_player;
$$;

grant execute on function public._live_season(text)   to authenticated;
grant execute on function public._player_region(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. _award_season_points — season and rules resolved PER PLAYER.
--
--    UNCHANGED: the upset threshold (0.5), the streak definition (3+ wins
--    counting back through ranking_history), the casual/unranked guard, and
--    every `on conflict do nothing`. The only change is WHICH season each row
--    is written to, and that the rule values are read per season.
-- ---------------------------------------------------------------------------
create or replace function public._award_season_points(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_win int; v_loss int; v_streak int; v_upset int;
  v_winner text; v_type text;
  v_avg_a numeric; v_avg_b numeric;
  v_upset_a boolean; v_upset_b boolean;
  r record; v_prev_wins int; v_won boolean; v_is_upset boolean;
  v_sid uuid; v_frozen boolean;
begin
  select m.winner_team, m.match_type into v_winner, v_type
    from public.matches m where m.id = p_match_id;
  if v_winner is null then return; end if;
  if coalesce(v_type, 'ranked') <> 'ranked' then return; end if;  -- casual is unrated

  select avg(coalesce((select rating from public.player_ratings where player_id = p.id), 2.0)) filter (where mp.team = 'a'),
         avg(coalesce((select rating from public.player_ratings where player_id = p.id), 2.0)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b
    from public.match_players mp join public.profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 2.0); v_avg_b := coalesce(v_avg_b, 2.0);
  -- an upset = the winning pair was rated at least 0.5 below the pair it beat
  v_upset_a := (v_winner = 'a' and v_avg_b - v_avg_a >= 0.5);
  v_upset_b := (v_winner = 'b' and v_avg_a - v_avg_b >= 0.5);

  for r in
    select mp.player_id, mp.team from public.match_players mp
     where mp.match_id = p_match_id
  loop
    -- This player's OWN ladder.
    v_sid := public._live_season(public._player_region(r.player_id));
    if v_sid is null then continue; end if;
    select s.frozen into v_frozen from public.seasons s where s.id = v_sid;
    if coalesce(v_frozen, false) then continue; end if;

    -- Read per season, not once per match: two regions may price a win
    -- differently, and before this delta there was only ever one price.
    select coalesce((select pts from public.season_rules where season_id = v_sid and code = 'win'), 0),
           coalesce((select pts from public.season_rules where season_id = v_sid and code = 'loss'), 0),
           coalesce((select pts from public.season_rules where season_id = v_sid and code = 'streak'), 0),
           coalesce((select pts from public.season_rules where season_id = v_sid and code = 'upset'), 0)
      into v_win, v_loss, v_streak, v_upset;

    v_won := (r.team = v_winner);
    v_is_upset := (r.team = 'a' and v_upset_a) or (r.team = 'b' and v_upset_b);

    insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
    values (v_sid, r.player_id, case when v_won then 'win' else 'loss' end,
            case when v_won then v_win else v_loss end, p_match_id)
    on conflict do nothing;

    if v_won and v_streak > 0 then
      -- consecutive wins BEFORE this match (ranking_history for this match is
      -- written after this call, so counting back from the newest row is safe)
      with h as (
        select rh.won, row_number() over (order by rh.created_at desc) as rn
          from public.ranking_history rh
         where rh.profile_id = r.player_id and rh.match_id is not null and rh.won is not null
         order by rh.created_at desc
         limit 30
      ), first_loss as (
        select coalesce(min(rn), 999) as rn from h where h.won is false
      )
      select count(*)::int into v_prev_wins
        from h, first_loss where h.rn < first_loss.rn and h.won;

      if coalesce(v_prev_wins, 0) + 1 >= 3 then
        insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
        values (v_sid, r.player_id, 'streak', v_streak, p_match_id)
        on conflict do nothing;
      end if;
    end if;

    if v_won and v_is_upset and v_upset > 0 then
      insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
      values (v_sid, r.player_id, 'upset', v_upset, p_match_id)
      on conflict do nothing;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. _award_tournament_season_points — season from the TOURNAMENT's region.
--
--    UNCHANGED: the final/semi-final detection, the champion + runner-up +
--    both losing semi-finalists payout shape, and the guest (`pid is not
--    null`) skip. Only the season lookup moves.
-- ---------------------------------------------------------------------------
create or replace function public._award_tournament_season_points(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; v_frozen boolean; v_title int; v_podium int;
  v_final_round int; f record; m record;
  v_champ uuid; v_runner uuid; v_region text;
begin
  select coalesce(t.region_id, 'EG') into v_region
    from public.tournaments t where t.id = p_tournament_id;

  v_sid := public._live_season(v_region);
  if v_sid is null then return; end if;
  select s.frozen into v_frozen from public.seasons s where s.id = v_sid;
  if coalesce(v_frozen, false) then return; end if;

  select coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_win'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_podium'), 0)
    into v_title, v_podium;

  select max(tm.round) into v_final_round
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.winner_entry is not null;
  if v_final_round is null then return; end if;

  -- the final: champion + runner-up
  select tm.entry1, tm.entry2, tm.winner_entry into f
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.round = v_final_round and tm.winner_entry is not null
   order by tm.slot limit 1;
  if not found then return; end if;

  v_champ  := f.winner_entry;
  v_runner := case when f.winner_entry = f.entry1 then f.entry2 else f.entry1 end;

  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_win', v_title, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_champ and v.pid is not null
  on conflict do nothing;

  -- podium: the runner-up plus everyone who lost a semi-final
  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_runner and v.pid is not null
  on conflict do nothing;

  for m in
    select tm.entry1, tm.entry2, tm.winner_entry
      from public.tournament_matches tm
     where tm.tournament_id = p_tournament_id
       and coalesce(tm.bracket, 'wb') = 'wb'
       and tm.round = v_final_round - 1
       and tm.winner_entry is not null
  loop
    insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
    select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
      from public.tournament_entries e,
           lateral (values (e.player_id), (e.partner_id)) as v(pid)
     where e.id = (case when m.winner_entry = m.entry1 then m.entry2 else m.entry1 end)
       and v.pid is not null
    on conflict do nothing;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. season_overview() — the CALLER's ladder.
--
--    Unchanged apart from the region filter on the season lookup. Still
--    returns null when there is no published live season, which is what makes
--    the Home card hide itself.
-- ---------------------------------------------------------------------------
create or replace function public.season_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_s record; v_board jsonb; v_me jsonb; v_rules jsonb; v_brackets jsonb;
  v_days int; v_progress numeric; v_span int;
  v_region text;
begin
  v_region := coalesce(public._player_region(v_uid), 'EG');

  select * into v_s from public.seasons
   where status = 'live' and published and region_id = v_region
   order by starts_on desc limit 1;
  if not found then return null; end if;

  v_days := greatest(0, v_s.ends_on - current_date);
  v_span := greatest(1, v_s.ends_on - v_s.starts_on);
  v_progress := greatest(0, least(1, (current_date - v_s.starts_on)::numeric / v_span));

  select jsonb_agg(jsonb_build_object(
           'rank', st.rank, 'player_id', st.player_id, 'name', st.name,
           'avatar_url', st.avatar_url, 'tier', st.tier, 'pts', st.pts,
           'played', st.played, 'trend', st.trend,
           'me', st.player_id = v_uid) order by st.rank)
    into v_board
    from public.season_standings(v_s.id) st;

  select e into v_me
    from jsonb_array_elements(coalesce(v_board, '[]'::jsonb)) e
   where (e->>'player_id')::uuid = v_uid;

  select jsonb_agg(jsonb_build_object(
           'code', code, 'label', label, 'pts', pts, 'note', note, 'icon', icon)
         order by sort, code)
    into v_rules from public.season_rules where season_id = v_s.id;

  select jsonb_agg(jsonb_build_object(
           'rank_from', rank_from, 'rank_to', rank_to, 'label', label,
           'short', short, 'icon', icon, 'color', color, 'prize', prize,
           'extras', extras) order by rank_from)
    into v_brackets from public.season_brackets where season_id = v_s.id;

  return jsonb_build_object(
    'id', v_s.id, 'no', v_s.no, 'name', v_s.name,
    'starts_on', v_s.starts_on, 'ends_on', v_s.ends_on,
    'days_left', v_days, 'progress', v_progress,
    'region_id', v_s.region_id,
    'board', coalesce(v_board, '[]'::jsonb),
    'me', v_me,
    'rules', coalesce(v_rules, '[]'::jsonb),
    'brackets', coalesce(v_brackets, '[]'::jsonb));
end $$;
grant execute on function public.season_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. snapshot_season_ranks() — snapshot EVERY live season.
--
--    It used to take the one live season. With a ladder per region, taking
--    "the" live season would leave every other market with no trend data --
--    and trend silently reads as 0, so nobody would notice it was missing.
-- ---------------------------------------------------------------------------
create or replace function public.snapshot_season_ranks()
returns int language plpgsql security definer set search_path = public as $$
declare v_sid uuid; v_n int := 0; v_this int;
begin
  for v_sid in select id from public.seasons where status = 'live' loop
    insert into public.season_rank_snapshots (season_id, player_id, taken_on, rank, pts)
    select v_sid, s.player_id, current_date, s.rank, s.pts
      from public.season_standings(v_sid) s
    on conflict (season_id, player_id, taken_on) do update
      set rank = excluded.rank, pts = excluded.pts;
    get diagnostics v_this = row_count;
    v_n := v_n + coalesce(v_this, 0);
  end loop;
  return v_n;
end $$;
grant execute on function public.snapshot_season_ranks() to authenticated;

-- ---------------------------------------------------------------------------
-- 8. admin_create_season — takes a region.
--
--    The old 4-argument signature is DROPPED rather than left beside the new
--    one. An overload would make the existing `grant execute` line name a
--    signature that should no longer exist, and PostgREST cannot choose between
--    two candidates when the client omits the new argument.
--
--    `no` is now counted WITHIN the region, so each market runs Season 1, 2, 3.
--    Going live immediately also checks only that region.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_create_season(text, date, date, uuid);

create or replace function public.admin_create_season(
  p_name text, p_starts date, p_ends date, p_copy_from uuid default null,
  p_region text default 'EG')
returns text
language plpgsql security definer set search_path = public as $$
declare v_no int; v_id uuid; v_status text; v_region text;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if p_name is null or btrim(p_name) = '' then return 'Name the season.'; end if;
  if p_ends <= p_starts then return 'The season must end after it starts.'; end if;

  v_region := coalesce(nullif(btrim(p_region), ''), 'EG');
  if not exists (select 1 from public.regions where id = v_region) then
    return 'No such region: ' || v_region;
  end if;

  select coalesce(max(no), 0) + 1 into v_no
    from public.seasons where region_id = v_region;

  -- goes live immediately only if nothing else is live IN THIS REGION and it
  -- has already started
  v_status := case
    when p_starts <= current_date
     and not exists (select 1 from public.seasons
                      where status = 'live' and region_id = v_region) then 'live'
    else 'scheduled' end;

  insert into public.seasons (no, name, starts_on, ends_on, status, published, region_id)
  values (v_no, btrim(p_name), p_starts, p_ends, v_status, false, v_region)
  returning id into v_id;

  if p_copy_from is not null then
    insert into public.season_rules (season_id, code, label, pts, note, icon, sort)
    select v_id, code, label, pts, note, icon, sort
      from public.season_rules where season_id = p_copy_from;
    insert into public.season_brackets
      (season_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget)
    select v_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget
      from public.season_brackets where season_id = p_copy_from;
  else
    perform public._seed_season_defaults(v_id);
  end if;
  return null;
end $$;
grant execute on function public.admin_create_season(text, date, date, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. admin_close_season — promote the next season IN THE SAME REGION.
--
--    Unchanged except that lookup. Left as-is, it would close Egypt's season
--    and promote whichever scheduled season happened to start soonest
--    anywhere -- quietly starting another market's ladder early.
-- ---------------------------------------------------------------------------
create or replace function public.admin_close_season(p_season_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare v_champ uuid; v_n int := 0; v_next uuid; v_name text; v_region text;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  select name, coalesce(region_id, 'EG') into v_name, v_region
    from public.seasons where id = p_season_id;
  if v_name is null then return 'Season not found.'; end if;

  select st.player_id into v_champ
    from public.season_standings(p_season_id) st where st.rank = 1;

  update public.seasons
     set status = 'ended', frozen = true, paid_out = true, champion_id = v_champ
   where id = p_season_id;

  insert into public.notifications (user_id, type, title, body, data)
  select st.player_id, 'season',
         v_name || ' — you finished #' || st.rank,
         'You placed in ' || b.label || '. Reward: ' || coalesce(b.prize, 'see the app') ||
         '. It will be issued within 7 days.',
         jsonb_build_object('season_id', p_season_id, 'rank', st.rank, 'bracket', b.label)
    from public.season_standings(p_season_id) st
    join public.season_brackets b
      on b.season_id = p_season_id and st.rank between b.rank_from and b.rank_to;
  get diagnostics v_n = row_count;

  select id into v_next from public.seasons
   where status = 'scheduled' and region_id = v_region
   order by starts_on limit 1;
  if v_next is not null then
    update public.seasons set status = 'live' where id = v_next;
  end if;

  return 'Season closed — ' || v_n || ' player' || (case when v_n = 1 then '' else 's' end)
         || ' in a reward bracket were notified.';
end $$;
grant execute on function public.admin_close_season(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Run these one at a time; the editor shows only the last result set.

-- Both indexes are now region-scoped. Expect seasons_one_live_key on
-- (region_id) WHERE status='live', and seasons_no_key on (region_id, no).
select indexname, indexdef
  from pg_indexes
 where schemaname = 'public' and tablename = 'seasons'
   and indexname in ('seasons_one_live_key', 'seasons_no_key')
 order by indexname;

-- One live season per region at most, and which.
select s.region_id, count(*) filter (where s.status = 'live') as live_seasons,
       max(s.name) filter (where s.status = 'live') as live_name,
       count(*) as total_seasons
  from public.seasons s
 group by s.region_id
 order by s.region_id;

-- admin_create_season must exist ONCE, with five arguments.
select p.proname, pg_get_function_arguments(p.oid) as args
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('admin_create_season', '_live_season', '_player_region')
 order by p.proname;

-- Nothing should still resolve the live season without a region. Expect zero
-- rows; anything listed is a lookup this delta missed.
select p.proname
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.prosrc like '%status = ''live'' limit 1%'
 order by 1;

-- Every existing season points row still belongs to the season's own region's
-- players. Expect zero rows: a non-zero count means points were awarded across
-- regions before this delta ran.
select sp.season_id, s.region_id as season_region,
       public._player_region(sp.player_id) as player_region, count(*) as rows
  from public.season_points sp
  join public.seasons s on s.id = sp.season_id
 where s.region_id <> public._player_region(sp.player_id)
 group by 1, 2, 3
 order by 4 desc;
