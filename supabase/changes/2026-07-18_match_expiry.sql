-- 2026-07-18 · Under-filled match lifecycle: grace window + auto-expire.
--
-- An 'open' match that never reaches 4 players used to sit orphaned forever
-- (invisible to matchmaking after its time, but never cancelled, still on the
-- creator's Home, no way to cancel post-time). Now:
--   * It stays fillable for a GRACE window (default 30 min) past scheduled_at.
--   * expire_stale_matches() cancels any still-under-4 match past its grace and
--     notifies the joined players. Runs via pg_cron every 10 min + a client
--     fallback call on Home load.
--   * cancel_match() lets the host kill their own match anytime.
--
-- Idempotent. The grace applies to DISCOVERY too (mm_candidates /
-- mm_player_sees_match use `now() - mm_grace()`); those two functions are
-- updated in migration_player_app.sql — re-run it (or this file works
-- standalone for the expire/cancel behaviour, just without extending discovery
-- past scheduled_at until the migration is re-run).

create or replace function public.mm_grace()
returns interval language sql stable set search_path = public as $$
  select coalesce((select value::numeric from public.app_settings
                    where key = 'mm_grace_minutes'), 30) * interval '1 minute';
$$;

create or replace function public.expire_stale_matches()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int := 0; r record;
begin
  for r in
    select mt.id from public.matches mt
     where mt.status = 'open'
       and mt.scheduled_at < now() - public.mm_grace()
       and (select count(*) from public.match_players mp where mp.match_id = mt.id) < 4
  loop
    update public.matches set status = 'cancelled' where id = r.id;
    insert into public.notifications (user_id, type, title, body, data)
    select mp.player_id, 'match', 'Match cancelled',
           'Your match didn''t fill up in time, so it was cancelled.',
           jsonb_build_object('match_id', r.id)
      from public.match_players mp where mp.match_id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
grant execute on function public.expire_stale_matches() to authenticated;

create or replace function public.cancel_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_creator uuid; v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select created_by, status into v_creator, v_status
    from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_creator <> v_uid and not public._is_admin() then
    return 'Only the host can cancel this match.';
  end if;
  if v_status in ('completed', 'cancelled') then
    return 'This match is already ' || v_status || '.';
  end if;
  update public.matches set status = 'cancelled' where id = p_match_id;
  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Match cancelled',
         'The host cancelled this match.', jsonb_build_object('match_id', p_match_id)
    from public.match_players mp
   where mp.match_id = p_match_id and mp.player_id <> v_uid;
  return null;
end $$;
grant execute on function public.cancel_match(uuid) to authenticated;

do $$ begin
  perform cron.schedule('padel-expire-matches', '*/10 * * * *',
    'select public.expire_stale_matches()');
exception when others then
  raise notice 'pg_cron not available — expire_stale_matches runs via the client fallback.';
end $$;

notify pgrst, 'reload schema';
