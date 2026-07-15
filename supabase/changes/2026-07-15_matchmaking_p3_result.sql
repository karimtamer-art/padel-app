-- 2026-07-15 · Matchmaking Phase 3 — post-match result hero + ack
--
-- Drives the home "MATCH COMPLETE" hero (state 8): after a match settles, the
-- player sees a one-time win/loss card with the set scores + rating movement,
-- then taps "Book your next game" which acks it (so it doesn't reappear) and
-- returns the hero to the booking state. Per-player ack lives on match_players.
--
-- No leaderboard exists, so the hero shows the real division/tier standing, not
-- a fabricated numeric rank. Casual matches are unrated → rating_delta is null.
--
-- Idempotent. Also folded into migration_player_app.sql.

alter table public.match_players
  add column if not exists result_ack boolean not null default false;

-- Don't retro-fire the hero for matches already completed before this shipped.
update public.match_players mp
   set result_ack = true
  from public.matches m
 where m.id = mp.match_id
   and m.status = 'completed'
   and coalesce(mp.result_ack, false) = false;

-- The most recent completed match the caller hasn't acked, with the fields the
-- result hero renders. SECURITY DEFINER so it can read the match + ranking_history
-- regardless of RLS; only ever returns the caller's own row.
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

-- Ack the result hero for the caller (idempotent).
create or replace function public.mm_ack_result(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.match_players
     set result_ack = true
   where match_id = p_match_id and player_id = auth.uid();
end $$;

grant execute on function public.mm_result_hero() to authenticated;
grant execute on function public.mm_ack_result(uuid) to authenticated;

notify pgrst, 'reload schema';
