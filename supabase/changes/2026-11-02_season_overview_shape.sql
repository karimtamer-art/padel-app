-- The season screens get the shape every build of the app reads. NOT APPLIED.
-- changes/2026-09-26_seasons_per_region.sql returned the season's fields at the top level,
-- while the app reads them from a nested "season" object, so on live SeasonOverview fails
-- to parse, overview() returns null, and the player's season data doesn't load. Only the
-- database needs to change, so this fixes every build already installed.
-- The body is the one in migration_player_app.sql. Still scoped to the caller's region.
-- Safe to re-run. Don't re-run 2026-09-26_seasons_per_region.sql afterwards: it brings
-- the old shape back.
-- ROLLBACK: supabase/rollbacks/2026-11-02_season_overview_shape_rollback.sql

create or replace function public.season_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_s record; v_board jsonb; v_me jsonb; v_rules jsonb; v_brackets jsonb;
  v_days int; v_progress numeric; v_span int;
  v_region text;
begin
  -- The CALLER's ladder (2026-09-26). Unscoped, this returned whichever live
  -- published season sorted first — so a player in one market would be shown
  -- another market's board as their own.
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
           'id', id, 'rank_from', rank_from, 'rank_to', rank_to, 'label', label,
           'short', coalesce(short, label), 'icon', icon, 'color', color,
           'prize', prize, 'extras', to_jsonb(extras), 'budget', budget)
         order by rank_from)
    into v_brackets from public.season_brackets where season_id = v_s.id;

  return jsonb_build_object(
    'season', jsonb_build_object(
      'id', v_s.id, 'no', v_s.no, 'name', v_s.name,
      'starts_on', v_s.starts_on, 'ends_on', v_s.ends_on,
      'days_left', v_days, 'progress', round(v_progress, 4),
      'frozen', v_s.frozen, 'region', v_s.region),
    'me', v_me,
    'board', coalesce(v_board, '[]'::jsonb),
    'rules', coalesce(v_rules, '[]'::jsonb),
    'brackets', coalesce(v_brackets, '[]'::jsonb));
end $$;

-- VERIFY: ok = true
select 'season_overview returns a nested season' as check_name,
       pg_get_functiondef('public.season_overview()'::regprocedure)
         like '%''season'', jsonb_build_object%' as ok,
       'season_overview' as detail;
