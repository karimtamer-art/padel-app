-- 2026-07-16 · Players console rework — one real-data feed for the admin tab
--
-- The old admin Players tab read profiles directly and headlined the dead
-- legacy `elo` column (rating engine v2 uses the 0..7 `rating`). The redesign
-- also needs per-player win/loss, last-active, email, global rank and username
-- — none of which the plain profiles select carried.
--
-- admin_players_console() returns ONE json array of every non-admin player with:
--   identity : id, name, username, avatar_url, city, phone, email (auth.users)
--   rating   : rating, level, sigma, reliability, is_provisional, is_anchor,
--              competitive_matches, global rank (by rating desc)
--   activity : joined (created_at), last_sign_in_at, played, wins, losses
--   status   : moderation status ('active'|'flagged'|'banned')
-- KPIs and the division split are derived client-side from this array.
--
-- Wins/played count DECIDED completed matches (winner_team not null). SECURITY
-- DEFINER so it can read auth.users; admin-gated. Idempotent; also folded into
-- migration_player_app.sql.

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
