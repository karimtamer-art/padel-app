-- ============================================================================
-- 2026-08-01 — Casual matches are visible to EVERYONE (ranked + unranked)
--
-- Matchmaking discovery gated every match two ways:
--   1. rating band  — |my rating − match centre| <= mm_band_halfwidth(age)
--   2. placement    — a placement player (placement_played < 5) could only see
--                     other placement players' matches, and vice versa
-- Both were applied to CASUAL matches too, even though casual is unrated and
-- can never move anyone's rating. Net effect: a new/unranked player and a
-- placed player could never find each other's casual games.
--
-- Now: casual skips BOTH gates — only city, the time window, "still open",
-- "not full" and "not already in it" apply. COMPETITIVE is unchanged (band +
-- placement split intact), so rated results stay inside the band.
--
-- Touches mm_candidates (the radar + the "N near you" count) and
-- mm_player_sees_match (the background search-ticket notifier). Safe to re-run.
-- Also folded into migration_player_app.sql.
-- ============================================================================

create or replace function public.mm_candidates(
  p_limit int default null,
  p_from  timestamptz default null,
  p_to    timestamptz default null
)
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

  -- Qualify with the table alias: the RETURNS TABLE column `city` shadows an
  -- unqualified `city` here (42702 ambiguous reference otherwise).
  select coalesce(p.rating, p.level, 2.0)::numeric, p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_placement
    from public.profiles p where p.id = v_uid;

  v_window := coalesce(
    (select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);

  -- ::numeric casts: profiles.level is double precision on the live DB, so the
  -- coalesces would promote to double and mismatch the numeric out-columns (42804).
  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         m.created_by, cp.name,
         coalesce(cp.rating, cp.level, 2.0)::numeric, coalesce(cp.level, cp.rating, 2.0)::numeric,
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)::numeric,
         greatest(0, round((1 - abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) / 3.5) * 100))::int
    from public.matches m
    join public.profiles cp on cp.id = m.created_by
    left join public.courts c on c.id = m.court_id
   where m.status = 'open'
     and m.created_by <> v_uid
     and m.scheduled_at > now() - public.mm_grace()  -- still fillable during grace
     -- Time window: explicit [p_from, p_to] when given, else the rolling window.
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
     -- Casual matches are UNRATED, so neither the rating band nor the
     -- placement/placed split applies — every player sees every open casual
     -- match in their city. Competitive keeps both gates.
     and (
       m.match_type = 'casual'
       or case when v_placement
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

-- Same rule for the background search ticket (push "Match found").
create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
  v_type text;
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = p_player;
  if not found then return false; end if;

  select m.status, m.created_by, coalesce(m.mm_center_rating, 2.0), m.created_at,
         m.scheduled_at, m.court_id, m.match_type
    into v_status, v_cby, v_center, v_created, v_sched, v_court, v_type
    from public.matches m where m.id = p_match;
  if not found or v_status <> 'open' or v_cby = p_player then return false; end if;
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

notify pgrst, 'reload schema';

-- Check: as a signed-in player, casual matches from outside your band now show.
-- select match_id, match_type, creator_name, center_rating
--   from public.mm_candidates(20) order by match_type;
