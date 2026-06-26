-- Admin alerts + broadcast push (2026-06-26)
-- Run this whole file once on the live project. Idempotent (create or replace
-- + drop/create trigger), safe to re-run. Mirrors the same block now in
-- supabase/migration_player_app.sql.
--
-- Adds four notification producers that previously had none:
--   1. broadcasts         -> one 'broadcast' row per targeted player (push +
--                            bell badge; audience segment finally enforced).
--   2. trade_requests     -> 'admin_trade' to every admin.
--   3. repair_requests    -> 'admin_repair' to every admin.
--   4. tournament_entries -> 'admin_tournament' for InstaPay entries to verify.
-- Each lands in public.notifications, so the existing push-notify webhook fans
-- it out to the recipient's devices automatically.

-- 1. Broadcast fan-out (replaces the player app reading `broadcasts` directly).
create or replace function public.fanout_broadcast()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'broadcast', new.title, new.body,
         jsonb_build_object('broadcast_id', new.id, 'segment', new.segment)
  from public.profiles p
  where p.is_admin = false
    and case coalesce(new.segment, 'all')
          when 'all'      then true
          when 'ranked'   then coalesce(p.placement_played, 0) >= 5
          when 'unranked' then coalesce(p.placement_played, 0) < 5
          when 'specific' then p.id = any(coalesce(new.player_ids, '{}'::uuid[]))
          else true
        end;
  return new;
end $$;

drop trigger if exists trg_fanout_broadcast on public.broadcasts;
create trigger trg_fanout_broadcast
  after insert on public.broadcasts
  for each row
  execute function public.fanout_broadcast();

-- 2. New trade-in request -> alert every admin.
create or replace function public.notify_admins_new_trade()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  select name into v_name from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_trade',
         'New trade-in request',
         coalesce(v_name, 'A player') || ' · ' ||
           coalesce(new.racket_desc, 'racket'),
         jsonb_build_object('trade_id', new.id, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_trade on public.trade_requests;
create trigger trg_notify_admins_new_trade
  after insert on public.trade_requests
  for each row
  execute function public.notify_admins_new_trade();

-- 3. New repair request -> alert every admin.
create or replace function public.notify_admins_new_repair()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  select name into v_name from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_repair',
         'New repair request',
         coalesce(v_name, 'A player') || ' · ' ||
           coalesce(new.racket_desc, 'racket'),
         jsonb_build_object('repair_id', new.id, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_repair on public.repair_requests;
create trigger trg_notify_admins_new_repair
  after insert on public.repair_requests
  for each row
  execute function public.notify_admins_new_repair();

-- 4. New InstaPay tournament entry awaiting verification -> alert every admin.
create or replace function public.notify_admins_tournament_payment()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  if new.status <> 'pending'
     or coalesce(new.payment_method, '') <> 'instapay' then
    return new;
  end if;
  select name into v_name from public.tournaments where id = new.tournament_id;
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_tournament',
         'Tournament payment to verify',
         coalesce(new.player_name, 'A player') || ' · ' ||
           coalesce(v_name, 'tournament') || ' · EGP ' ||
           coalesce(new.paid_amount, 0)::text,
         jsonb_build_object('tournament_id', new.tournament_id,
                            'entry_id', new.id, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_tournament_payment on public.tournament_entries;
create trigger trg_notify_admins_tournament_payment
  after insert on public.tournament_entries
  for each row
  execute function public.notify_admins_tournament_payment();
