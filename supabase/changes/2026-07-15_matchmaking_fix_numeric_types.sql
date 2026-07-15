-- 2026-07-15 · Fix: mm_candidates/mm_result_hero return-type mismatch (42804)
--
-- "Returned type double precision does not match expected type numeric".
-- On the live DB profiles.level (and possibly ranking_history.delta/rating_after)
-- are double precision, so coalesce(rating, level, 2.0) promotes to double
-- precision and no longer matches the numeric RETURNS TABLE columns. Cast the
-- rating/level outputs to ::numeric. Re-creates both functions; safe standalone.

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

  select coalesce(p.rating, p.level, 2.0)::numeric, p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_placement
    from public.profiles p where p.id = v_uid;

  v_window := coalesce(
    (select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);

  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         m.created_by, cp.name,
         coalesce(cp.rating, cp.level, 2.0)::numeric,
         coalesce(cp.level, cp.rating, 2.0)::numeric,
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)::numeric,
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
     and (
       case when v_placement
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

create or replace function public.mm_result_hero()
returns table(
  match_id      uuid,
  won           boolean,
  my_team       text,
  score_team_a  text,
  score_team_b  text,
  rating_delta  numeric,
  rating_after  numeric,
  match_type    text
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_mid uuid;
begin
  if v_uid is null then return; end if;

  select mp.match_id into v_mid
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
   where mp.player_id = v_uid
     and m.status = 'completed'
     and m.winner_team is not null
     and coalesce(mp.result_ack, false) = false
   order by m.scheduled_at desc nulls last
   limit 1;
  if v_mid is null then return; end if;

  return query
  select m.id,
         (mp.team = m.winner_team),
         mp.team,
         m.score_team_a,
         m.score_team_b,
         (select rh.delta::numeric from public.ranking_history rh
            where rh.profile_id = v_uid and rh.match_id = m.id
            order by rh.created_at desc limit 1),
         (select rh.rating_after::numeric from public.ranking_history rh
            where rh.profile_id = v_uid and rh.match_id = m.id
            order by rh.created_at desc limit 1),
         m.match_type
    from public.matches m
    join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
   where m.id = v_mid;
end $$;

notify pgrst, 'reload schema';
