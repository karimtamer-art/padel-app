-- 2026-08-10 — Let the console RECORD a trade-in, not just answer one.
--
-- Trade-ins that happen at the counter never passed through the app, so there
-- was no row for them and their credit never reached the P&L. The only insert
-- policy on trade_requests was "create own trade" (auth.uid() = player_id), so
-- an admin filing one on a player's behalf was refused by RLS.
--
-- Safe to re-run.

-- ── 1. Staff may insert, scoped to the Requests section ─────────────────────
-- Mirrors the existing "trades: admin update" policy. Permissive policies OR
-- together, so the player's own "create own trade" path is untouched.
drop policy if exists "trades: staff insert" on public.trade_requests;
create policy "trades: staff insert" on public.trade_requests for insert
  with check (public._can_edit('requests'));

-- ── 2. Don't alert the admins about a trade-in an admin just typed in ───────
-- The insert trigger fires for every row and tells every admin "New trade-in
-- request". That is right when a player submits one and wrong when a staffer
-- records a walk-in — they would all be pinged about their own colleague's
-- data entry, with a title that misdescribes it. Only notify when the row was
-- created by the player it belongs to.
create or replace function public.notify_admins_new_trade()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  -- Staff-recorded (auth.uid() is the admin, not the player): stay quiet.
  -- Also quiet for a walk-in with no account at all, and for service-role /
  -- seed inserts, where auth.uid() is null.
  if new.player_id is null or new.player_id is distinct from auth.uid() then
    return new;
  end if;

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

-- ── 3. Drift guard ──────────────────────────────────────────────────────────
-- The live table (migration 0003) shipped `notes`; the app reads and writes
-- `note`. The console's new sheet writes `note` too, so make sure it is there.
alter table public.trade_requests add column if not exists note text;

-- ── 4. A counter trade-in need not belong to an account ─────────────────────
-- Someone can walk in with a racket without ever having installed the app, so
-- player_id stops being mandatory and a plain typed name stands in for it.
-- Same shape as tournament_entries' partner_id / partner_name pair.
alter table public.trade_requests alter column player_id drop not null;
alter table public.trade_requests add column if not exists player_name text;

-- ...but a trade-in with NEITHER is an anonymous row nobody can ever chase up,
-- so require one of them. Existing rows all carry player_id, so this is safe to
-- add to a populated table.
alter table public.trade_requests drop constraint if exists trade_requests_who_chk;
alter table public.trade_requests
  add constraint trade_requests_who_chk
  check (player_id is not null
         or btrim(coalesce(player_name, '')) <> '');

-- Note on the read policies: they are unchanged on purpose. "own trades read"
-- matches auth.uid() = player_id, and null never equals anything, so a walk-in
-- row is invisible to every player and visible only to staff holding Requests
-- — which is correct, since it belongs to no account.
--
-- The P&L is unaffected too: _finance_core sums trade_requests by status alone
-- and never joins profiles, so a walk-in's credit still lands in money OUT.
