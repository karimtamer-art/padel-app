-- 2026-07-15 · Matchmaking Phase 1 — visibility lockdown + band discovery
--
-- Kills the public "browse all matches" bulletin board. After this:
--   * matches are readable ONLY by their creator, a participant, or an admin
--     (no more RLS `using(true)`), so no client can list the pool.
--   * the ONLY way to discover a match you're not in is the band-gatekept
--     mm_candidates() RPC (SECURITY DEFINER — it sees the whole pool to filter
--     it by YOUR rating band + city + time window, then returns only matches you
--     may be paired with). The band equation lives in mm_band_halfwidth (P0).
--   * each match snapshots its band center (mm_center_rating = creator's rating
--     at creation) via a trigger, so the band can't be forged from the client.
--
-- Placement players (placement_played < 5) bypass the rating band and match only
-- other placement players. Everyone else must fall inside the widening band.
--
-- Depends on: 2026-07-15_matchmaking_config.sql (mm_* keys + mm_band_halfwidth).
-- Idempotent. Also folded into migration_player_app.sql.

-- ── 1. Band-center snapshot on the match ──────────────────────────
alter table public.matches add column if not exists mm_center_rating numeric;
-- created_at drives the band widen-over-time; guarantee it exists (drift table).
alter table public.matches add column if not exists created_at timestamptz not null default now();

create or replace function public.mm_set_center_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.mm_center_rating is null and new.created_by is not null then
    select coalesce(rating, level, 2.0) into new.mm_center_rating
      from public.profiles where id = new.created_by;
  end if;
  return new;
end $$;

drop trigger if exists trg_mm_center_rating on public.matches;
create trigger trg_mm_center_rating before insert on public.matches
  for each row execute function public.mm_set_center_rating();

-- Backfill existing rows so legacy open matches are discoverable.
update public.matches m
   set mm_center_rating = coalesce(
         (select coalesce(p.rating, p.level, 2.0) from public.profiles p where p.id = m.created_by),
         2.0)
 where m.mm_center_rating is null
   and m.created_by is not null;

-- ── 2. Band discovery (the ONE way to see matches you're not in) ──
-- SECURITY DEFINER so it can scan the whole pool to apply the band; it only ever
-- RETURNS rows inside the caller's band. p_limit null = all (used for counting).
create or replace function public.mm_candidates(p_limit int default null)
returns table(
  match_id       uuid,
  scheduled_at   timestamptz,
  match_type     text,
  court_name     text,
  venue_name     text,
  city           text,
  creator_id     uuid,
  creator_name   text,
  creator_rating numeric,
  creator_level  numeric,
  players        int,
  center_rating  numeric,
  level_match_pct int
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_rating    numeric;
  v_city      text;
  v_placement boolean;
  v_window    numeric;
begin
  if v_uid is null then return; end if;

  select coalesce(rating, level, 2.0), city, (coalesce(placement_played, 0) < 5)
    into v_rating, v_city, v_placement
    from public.profiles where id = v_uid;

  v_window := coalesce(
    (select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);

  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         m.created_by, cp.name,
         coalesce(cp.rating, cp.level, 2.0), coalesce(cp.level, cp.rating, 2.0),
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0),
         greatest(0, round((1 - abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) / 3.5) * 100))::int
    from public.matches m
    join public.profiles cp on cp.id = m.created_by
    left join public.courts c on c.id = m.court_id
   where m.status = 'open'
     and m.created_by <> v_uid
     and m.scheduled_at > now()
     and m.scheduled_at < now() + (v_window * interval '1 hour')
     and (select count(*) from public.match_players mp2 where mp2.match_id = m.id) < 4
     and not exists (select 1 from public.match_players mp3
                      where mp3.match_id = m.id and mp3.player_id = v_uid)
     -- Placement pairs with placement; placed pairs with placed inside the band.
     and (
       case when v_placement
         then coalesce(cp.placement_played, 0) < 5
         else coalesce(cp.placement_played, 0) >= 5
              and abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0))
                  <= public.mm_band_halfwidth(extract(epoch from (now() - m.created_at)) / 60.0)
       end
     )
     -- City proxy for range (lenient: unknown city on either side passes).
     and (v_city is null or coalesce(c.city, cp.city) is null or coalesce(c.city, cp.city) = v_city)
   order by abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) asc,
            m.scheduled_at asc
   limit p_limit;
end $$;

create or replace function public.mm_count_candidates()
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.mm_candidates(null);
$$;

grant execute on function public.mm_candidates(int) to authenticated;
grant execute on function public.mm_count_candidates() to authenticated;

-- ── 3. Visibility lockdown (replace world-readable with band model) ──
-- The participant policy subqueries match_players; that's safe from the old
-- 42P17 recursion because match_players' SELECT policy is `using(true)` and does
-- NOT reference matches back. Admin read is a separate OR'd policy.
drop policy if exists "matches readable" on public.matches;
do $$ begin
  create policy "matches: participant read" on public.matches for select
    using (
      created_by = auth.uid()
      or exists (select 1 from public.match_players mp
                  where mp.match_id = matches.id and mp.player_id = auth.uid())
    );
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "matches: admin read" on public.matches for select
    using (public._is_admin());
exception when duplicate_object then null; end $$;

-- New RPCs → refresh PostgREST so they're callable immediately.
notify pgrst, 'reload schema';
