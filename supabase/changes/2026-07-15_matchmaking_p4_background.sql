-- 2026-07-15 · Matchmaking Phase 4 — background search + notify-to-confirm
--
-- Searching persists server-side as a "ticket" so it survives the app closing.
-- When a band match appears while the player is away, we drop a `notifications`
-- row (type 'match', NO match_id so it can't deep-link into a match they can't
-- read yet) → the push-notify Edge Function pushes it → tapping opens the app to
-- home, where the radar hero resumes, re-polls, and shows the candidate to
-- Accept/Decline. Notify-to-confirm: we never auto-join.
--
-- No pg_cron: matching fires on (a) start-search (existing matches) and (b) an
-- AFTER INSERT trigger on matches (a new match in your band). Tickets older than
-- mm_ticket_ttl_hours are ignored (and cleaned up client-side on restore).
--
-- Idempotent. Also folded into migration_player_app.sql.

insert into public.app_settings (key, value) values ('mm_ticket_ttl_hours', '6')
  on conflict (key) do nothing;

create table if not exists public.matchmaking_tickets (
  player_id              uuid primary key references public.profiles(id) on delete cascade,
  created_at             timestamptz not null default now(),
  last_notified_match_id uuid,
  last_notified_at       timestamptz
);
alter table public.matchmaking_tickets enable row level security;
do $$ begin
  create policy "mm_tickets: read own" on public.matchmaking_tickets
    for select using (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select on public.matchmaking_tickets to authenticated;

-- Band predicate for a single (player, match) pair. The AFTER INSERT trigger
-- runs as the match creator, so it can't use auth.uid()-based mm_candidates for
-- OTHER players — this evaluates the same band/placement/city/time rules for an
-- explicit player.
create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = p_player;
  if not found then return false; end if;

  select m.status, m.created_by, coalesce(m.mm_center_rating, 2.0), m.created_at, m.scheduled_at, m.court_id
    into v_status, v_cby, v_center, v_created, v_sched, v_court
    from public.matches m where m.id = p_match;
  if not found or v_status <> 'open' or v_cby = p_player then return false; end if;
  if v_sched <= now() then return false; end if;

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

  if v_plac or v_cplac then
    if not (v_plac and v_cplac) then return false; end if;
  elsif abs(v_rating - v_center)
        > public.mm_band_halfwidth(extract(epoch from (now() - v_created)) / 60.0) then
    return false;
  end if;

  if v_city is not null and coalesce(v_courtcity, v_ccity) is not null
     and coalesce(v_courtcity, v_ccity) <> v_city then
    return false;
  end if;
  return true;
end $$;

-- New match created → ping every fresh, active ticket that would see it.
create or replace function public.mm_on_match_created()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ttl numeric;
begin
  if new.status <> 'open' then return new; end if;
  v_ttl := coalesce((select value::numeric from public.app_settings where key = 'mm_ticket_ttl_hours'), 6);

  insert into public.notifications (user_id, type, title, body, data)
  select t.player_id, 'match', 'Match found',
         'We found a match near your level — open Padel Rivals to confirm.',
         jsonb_build_object('kind', 'mm_found')
    from public.matchmaking_tickets t
   where t.created_at > now() - (v_ttl * interval '1 hour')
     and t.last_notified_match_id is distinct from new.id
     and public.mm_player_sees_match(t.player_id, new.id);

  update public.matchmaking_tickets t
     set last_notified_match_id = new.id, last_notified_at = now()
   where t.created_at > now() - (v_ttl * interval '1 hour')
     and t.last_notified_match_id is distinct from new.id
     and public.mm_player_sees_match(t.player_id, new.id);

  return new;
end $$;
drop trigger if exists trg_mm_on_match_created on public.matches;
create trigger trg_mm_on_match_created after insert on public.matches
  for each row execute function public.mm_on_match_created();

-- Start searching (create/refresh ticket); ping immediately if a match already
-- exists, so backgrounding right after Find still reaches them.
create or replace function public.mm_start_search()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_mid uuid;
begin
  if v_uid is null then return; end if;
  insert into public.matchmaking_tickets(player_id) values (v_uid)
    on conflict (player_id) do update
      set created_at = now(), last_notified_match_id = null, last_notified_at = null;

  select match_id into v_mid from public.mm_candidates(1);
  if v_mid is not null then
    insert into public.notifications (user_id, type, title, body, data)
    values (v_uid, 'match', 'Match found',
            'We found a match near your level — open Padel Rivals to confirm.',
            jsonb_build_object('kind', 'mm_found'));
    update public.matchmaking_tickets
       set last_notified_match_id = v_mid, last_notified_at = now()
     where player_id = v_uid;
  end if;
end $$;

create or replace function public.mm_cancel_search()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.matchmaking_tickets where player_id = auth.uid();
end $$;

grant execute on function public.mm_player_sees_match(uuid, uuid) to authenticated;
grant execute on function public.mm_start_search() to authenticated;
grant execute on function public.mm_cancel_search() to authenticated;

notify pgrst, 'reload schema';
