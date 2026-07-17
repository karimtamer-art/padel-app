-- 2026-07-17 · New players start UNRANKED (no seeded 1000 elo / Lv 1.0).
--
--   * handle_new_user seeds elo/level/tier = NULL (rating already NULL, sigma
--     default 0.85, placement_played 0). A player is "unranked" while in
--     placement (< 5 competitive matches); they earn a rating over 5 placement
--     matches, or an admin sets it. This matches the player app's existing
--     Unranked/placement card.
--   * admin_players_console now returns placement_played so the admin console
--     can show the Unranked state (previously it derived a division from the
--     seeded Lv 1.0 and showed "Division D").
--
-- Idempotent; also folded into migration_player_app.sql. To also reset EXISTING
-- players to unranked, run 2026-07-17_reset_players_unranked.sql (opt-in).

-- Legacy elo/level/tier must allow NULL (older DBs created elo NOT NULL) so an
-- unranked player can have no elo/level/tier.
alter table public.profiles alter column elo   drop not null;
alter table public.profiles alter column level drop not null;
alter table public.profiles alter column tier  drop not null;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public as $$
declare
  v_name     text;
  v_username text;
  v_dob      date;
  v_gender   text;
  v_hand     text;
  v_side     text;
begin
  v_name := nullif(trim(coalesce(new.raw_user_meta_data->>'name',
                                 new.raw_user_meta_data->>'full_name', '')), '');

  v_username := nullif(lower(trim(coalesce(new.raw_user_meta_data->>'username', ''))), '');
  if v_username is null
     or v_username !~ '^[a-z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where lower(username) = v_username) then
    v_username := public._unique_username(coalesce(v_username, v_name), new.id);
  end if;
  begin
    v_dob := nullif(new.raw_user_meta_data->>'date_of_birth', '')::date;
  exception when others then
    v_dob := null;
  end;
  if v_dob is not null and (v_dob > current_date - interval '13 years'
                         or v_dob < current_date - interval '100 years') then
    v_dob := null;
  end if;
  v_gender := nullif(new.raw_user_meta_data->>'gender', '');
  if v_gender not in ('male','female','other') then v_gender := null; end if;
  v_hand := nullif(new.raw_user_meta_data->>'preferred_hand', '');
  if v_hand not in ('right','left') then v_hand := null; end if;
  v_side := nullif(new.raw_user_meta_data->>'preferred_court_side', '');
  if v_side not in ('left','right','both') then v_side := null; end if;

  begin
    insert into public.profiles
      (id, name, username, avatar_url, phone, bio,
       date_of_birth, gender, preferred_hand, preferred_court_side,
       elo, level, tier, division_pts, placement_played)
    values
      (new.id, v_name, v_username,
       new.raw_user_meta_data->>'avatar_url',
       nullif(new.raw_user_meta_data->>'phone', ''),
       nullif(new.raw_user_meta_data->>'bio', ''),
       v_dob, v_gender,
       coalesce(v_hand, 'right'),
       coalesce(v_side, 'both'),
       -- Start UNRANKED: no seeded elo/level/tier.
       null, null, null, 0, 0)
    on conflict (id) do nothing;
  exception when others then
    raise warning 'handle_new_user: % — inserting minimal profile for %', sqlerrm, new.id;
    begin
      insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
    exception when others then
      raise warning 'handle_new_user minimal insert also failed: %', sqlerrm;
    end;
  end;
  return new;
end $$;

-- admin_players_console: add placement_played (drives the Unranked state).
create or replace function public.admin_players_console()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(row_to_json(x) order by x.rating desc nulls last), '[]'::json)
    from (
      select
        p.id,
        p.name,
        p.username,
        p.avatar_url,
        p.city,
        p.phone,
        u.email,
        u.last_sign_in_at,
        p.created_at                                          as joined,
        coalesce(p.rating, p.level, 0)::numeric               as rating,
        coalesce(p.level, p.rating, 0)::numeric               as level,
        p.sigma::numeric                                      as sigma,
        p.reliability::numeric                                as reliability,
        coalesce(p.is_provisional,
                 coalesce(p.competitive_matches, 0) < 5)      as is_provisional,
        coalesce(p.competitive_matches, 0)                    as competitive_matches,
        coalesce(p.placement_played, 0)                       as placement_played,
        coalesce(p.is_anchor, false)                          as is_anchor,
        coalesce(p.status, 'active')                          as status,
        coalesce(agg.played, 0)                               as played,
        coalesce(agg.wins, 0)                                 as wins,
        coalesce(agg.played, 0) - coalesce(agg.wins, 0)       as losses,
        rank() over (order by coalesce(p.rating, p.level, 0) desc) as rank
      from public.profiles p
      left join auth.users u on u.id = p.id
      left join lateral (
        select
          count(*)::int                                        as played,
          count(*) filter (where m.winner_team = mp.team)::int as wins
        from public.match_players mp
        join public.matches m on m.id = mp.match_id
        where mp.player_id = p.id
          and m.status = 'completed'
          and m.winner_team is not null
      ) agg on true
      where coalesce(p.is_admin, false) = false
    ) x
  );
end $$;
grant execute on function public.admin_players_console() to authenticated;

notify pgrst, 'reload schema';
