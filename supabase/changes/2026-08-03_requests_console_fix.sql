-- Admin console → Requests (Repairs + Trade-ins) was dead. Three DB-side causes,
-- all drift between migrations/0003 (which created both tables) and the app:
--
--   1. Neither table had an FK to public.profiles — only the legacy one to
--      auth.users. PostgREST cannot embed through that, so the admin join
--      `profiles!..._fkey(name, phone)` errored and the whole screen hung on
--      its spinner (Future.wait failed → _loading never cleared).
--      NOTE: 2026-06-20_trade_requests_access.sql tried to add the profiles FK
--      guarded on the name `trade_requests_player_id_fkey` — which 0003 had
--      ALREADY used for the auth.users FK, so the guard skipped and trades
--      stayed broken too.
--   2. trade_requests_condition_chk only allowed
--      ('new','like_new','good','fair','poor') but the trade-in sheet submits
--      the human labels 'Like New' / 'Good' / 'Fair' / 'Worn' → every player
--      submission failed, so the admin queue was permanently empty.
--   3. Neither status check allowed 'rejected', which is what the console
--      writes when an admin declines a request.
--
-- Idempotent; safe to re-run.

-- ── 1. Named FK to profiles so PostgREST can embed the submitter ──
do $$
declare c text;
begin
  select con.conname into c
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_class tgt on tgt.oid = con.confrelid
   where con.contype = 'f'
     and rel.relname = 'repair_requests'
     and rel.relnamespace = 'public'::regnamespace
     and tgt.relname = 'profiles'
     and tgt.relnamespace = 'public'::regnamespace
   limit 1;
  if c is null then
    -- NOT VALID: legacy rows whose player never got a profiles row would block
    -- validation. PostgREST reads pg_constraint, so the embed works regardless.
    alter table public.repair_requests
      add constraint repair_requests_player_profile_fkey
      foreign key (player_id) references public.profiles(id) not valid;
  elsif c <> 'repair_requests_player_profile_fkey' then
    execute format(
      'alter table public.repair_requests rename constraint %I to repair_requests_player_profile_fkey', c);
  end if;
end $$;

do $$
declare c text;
begin
  select con.conname into c
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_class tgt on tgt.oid = con.confrelid
   where con.contype = 'f'
     and rel.relname = 'trade_requests'
     and rel.relnamespace = 'public'::regnamespace
     and tgt.relname = 'profiles'
     and tgt.relnamespace = 'public'::regnamespace
   limit 1;
  if c is null then
    alter table public.trade_requests
      add constraint trade_requests_player_profile_fkey
      foreign key (player_id) references public.profiles(id) not valid;
  elsif c <> 'trade_requests_player_profile_fkey' then
    execute format(
      'alter table public.trade_requests rename constraint %I to trade_requests_player_profile_fkey', c);
  end if;
end $$;

-- ── 2. Condition is a free-text label chosen in the app, not an enum ──
alter table public.trade_requests
  drop constraint if exists trade_requests_condition_chk;

-- ── 3. Status vocabularies must match the console's state machines ──
alter table public.repair_requests
  drop constraint if exists repair_requests_status_chk;
alter table public.repair_requests
  add constraint repair_requests_status_chk
  check (status in ('pending','quoted','in_repair','ready','collected','rejected'));

alter table public.trade_requests
  drop constraint if exists trade_requests_status_chk;
alter table public.trade_requests
  add constraint trade_requests_status_chk
  check (status in ('pending','offer_made','accepted','rejected','declined','completed'));

-- ── Re-assert access (no-ops if already applied) ──
alter table public.trade_requests add column if not exists note text;
grant select, insert, update on public.repair_requests to authenticated;
grant select, insert, update on public.trade_requests  to authenticated;
