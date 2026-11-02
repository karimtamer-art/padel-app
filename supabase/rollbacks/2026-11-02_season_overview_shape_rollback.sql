-- ROLLBACK of 2026-11-02_season_overview_shape.sql: back to what live ran on 2 Nov, which
-- the app can't read. Only use this if the fix itself caused a problem.

create or replace function public.season_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as
$$
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
end 
$$;
