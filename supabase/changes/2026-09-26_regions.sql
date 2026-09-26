-- ===========================================================================
-- Regions: one app, many countries (2026-09-26)
--
-- The app is pivoting to tournament-first and is meant to run in Egypt AND
-- outside it from ONE binary and ONE store listing. The alternative -- a
-- second Egypt-only app -- was rejected: the expensive part of this app is not
-- the Dart, it is the rigging (three Android SHA-1s across two Cloud projects,
-- the Supabase redirect allow-list, the Cloudflare/Resend mail stack, two
-- store review queues). Forking that doubles the surface that can drift.
--
-- So region is DATA, not a build flag. This delta is the scaffolding only:
-- nothing is removed, nothing changes behaviour for an existing Egyptian
-- player, and pickup matches keep working. It ships ahead of the pivot so each
-- release stays reviewable.
--
-- WHAT A REGION DECIDES
--   * currency_code    -- what money is displayed in (the store also has its
--                         own products.currency, which wins where set)
--   * dial_code        -- the phone prefix, hardcoded '+20' in three screens
--   * commerce_enabled -- whether the Store exists at all. Cash-on-delivery
--                         and the Egyptian `addresses` table (governorate /
--                         city / area) do not export, so the store stays
--                         Egypt-only by DATA rather than by an `if` in Dart.
--
-- WHAT IT DELIBERATELY DOES NOT DECIDE
--   * the rating engine. V3-F5 is one global 0.00-7.00 scale so a player's
--     strength travels with them between countries. Untouched here.
--   * the P&L. `_finance_core` is not redefined by this delta -- commerce is
--     Egypt-only, so the money shapes are unchanged.
--
-- `regions.id` is a TEXT code ('EG'), not a uuid, because it appears in every
-- row of four tables and in log output; a readable key is worth more than the
-- uniformity.
--
-- ON `seasons.region`: that column already exists (added with the seasons
-- block) and is read into the Dart `Season` model, but NO SQL logic has ever
-- used it -- it is free text that nothing writes. It is NOT reused as the key
-- here, because a FK wants a known-good domain and this one has an unknown
-- one. `seasons.region_id` is added alongside it and is the real key; the old
-- `region` column is now STALE and comes out in a follow-up cleanup, the same
-- treatment `profiles.instapay_handle` got.
--
-- Communities are still city-scoped only. They are a candidate for region in a
-- follow-up; deliberately out of scope here.
--
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The regions table.
--
--    Self-healing alters follow the create, for the reason documented on
--    `sponsors` and `banners`: on the live database a drifted table would make
--    `create table if not exists` a silent no-op and none of these columns
--    would exist.
-- ---------------------------------------------------------------------------
create table if not exists public.regions (
  id               text primary key,                    -- 'EG', 'AE', 'SA'
  name             text not null,
  currency_code    text not null,
  dial_code        text not null,
  commerce_enabled boolean not null default false,
  active           boolean not null default true,
  sort             int not null default 0,
  created_at       timestamptz not null default now()
);

alter table public.regions add column if not exists name             text;
alter table public.regions add column if not exists currency_code    text;
alter table public.regions add column if not exists dial_code        text;
alter table public.regions add column if not exists commerce_enabled boolean not null default false;
alter table public.regions add column if not exists active           boolean not null default true;
alter table public.regions add column if not exists sort             int not null default 0;
alter table public.regions add column if not exists created_at       timestamptz not null default now();

create index if not exists regions_active_idx on public.regions (active, sort);

-- ---------------------------------------------------------------------------
-- 2. Seed Egypt.
--
--    This MUST run before section 3: the region_id columns below default to
--    'EG' and carry a foreign key, so the row has to exist first or every
--    alter fails on an unsatisfiable default.
--
--    `commerce_enabled` is true for Egypt only. A new region added later
--    starts with the store switched off, which is the safe default -- turning
--    it on is a deliberate act that implies delivery and payment exist there.
-- ---------------------------------------------------------------------------
insert into public.regions (id, name, currency_code, dial_code, commerce_enabled, active, sort)
values ('EG', 'Egypt', 'EGP', '+20', true, true, 0)
on conflict (id) do update
  set name          = excluded.name,
      currency_code = excluded.currency_code,
      dial_code     = excluded.dial_code;
-- NOTE: the conflict branch deliberately does not touch commerce_enabled,
-- active or sort -- those are operational switches and a re-run of this delta
-- must not flip one back that somebody turned off on purpose.

-- ---------------------------------------------------------------------------
-- 3. region_id on the four tables that need it.
--
--    Done in four steps per table rather than one `add column ... not null
--    default ... references ...`, so that a database where a previous run
--    added the column as nullable still converges:
--      a) add nullable
--      b) backfill nulls to 'EG'
--      c) set the default
--      d) set not null
--      e) add the FK if it is missing (there is no `add constraint if not
--         exists`, hence the do-block)
--
--    Every existing row becomes Egyptian, which is correct -- that is the only
--    market the app has run in.
-- ---------------------------------------------------------------------------

-- profiles ----------------------------------------------------------------
alter table public.profiles add column if not exists region_id text;
update public.profiles set region_id = 'EG' where region_id is null;
alter table public.profiles alter column region_id set default 'EG';
alter table public.profiles alter column region_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_region_id_fkey') then
    alter table public.profiles add constraint profiles_region_id_fkey
      foreign key (region_id) references public.regions(id);
  end if;
end $$;

-- courts ------------------------------------------------------------------
alter table public.courts add column if not exists region_id text;
update public.courts set region_id = 'EG' where region_id is null;
alter table public.courts alter column region_id set default 'EG';
alter table public.courts alter column region_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'courts_region_id_fkey') then
    alter table public.courts add constraint courts_region_id_fkey
      foreign key (region_id) references public.regions(id);
  end if;
end $$;

-- tournaments -------------------------------------------------------------
alter table public.tournaments add column if not exists region_id text;
update public.tournaments set region_id = 'EG' where region_id is null;
alter table public.tournaments alter column region_id set default 'EG';
alter table public.tournaments alter column region_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tournaments_region_id_fkey') then
    alter table public.tournaments add constraint tournaments_region_id_fkey
      foreign key (region_id) references public.regions(id);
  end if;
end $$;

-- seasons -----------------------------------------------------------------
-- One season per region: Egypt runs its ladder, each new market runs its own.
-- `season_standings(p_season_id)` is already per-season, so the standings
-- builder needs no change -- only the choice of WHICH season a player sees.
alter table public.seasons add column if not exists region_id text;
update public.seasons set region_id = 'EG' where region_id is null;
alter table public.seasons alter column region_id set default 'EG';
alter table public.seasons alter column region_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'seasons_region_id_fkey') then
    alter table public.seasons add constraint seasons_region_id_fkey
      foreign key (region_id) references public.regions(id);
  end if;
end $$;

create index if not exists tournaments_region_idx on public.tournaments (region_id, start_date);
create index if not exists seasons_region_live_idx on public.seasons (region_id, status);
create index if not exists courts_region_city_idx  on public.courts (region_id, city);

-- ---------------------------------------------------------------------------
-- 4. RLS + grants on regions.
--
--    Everyone reads the active list (the sign-up screen needs it before the
--    user is authenticated, hence `anon`). Only a SUPER ADMIN writes: a region
--    row decides whether money is shown and whether the store exists, so it is
--    structural config rather than a section somebody can be granted. Same
--    reasoning as minting a report link.
-- ---------------------------------------------------------------------------
alter table public.regions enable row level security;

drop policy if exists "regions: read active" on public.regions;
create policy "regions: read active" on public.regions for select
  using (active = true or public._is_admin());

drop policy if exists "regions: super admin write" on public.regions;
create policy "regions: super admin write" on public.regions for all
  using (public._is_admin()) with check (public._is_admin());

grant select on public.regions to anon, authenticated;
grant insert, update, delete on public.regions to authenticated;  -- RLS still gates it

-- ---------------------------------------------------------------------------
-- 5. The column grant on profiles.region_id.
--
--    `profiles` has COLUMN-LEVEL grants (migrations/0004 revoked blanket
--    UPDATE), so onboarding cannot write region_id unless it is named here.
--    Forgetting is INVISIBLE -- Postgres refuses the write and a
--    fire-and-forget call swallows it, which is how notify_* spent six weeks
--    unable to save. test/sql_raise_arity_test.dart checks this both ways.
--
--    region_id is safe to let the client set: it is not a ranking or privilege
--    column. The worst a user can do by changing it is show themselves a store
--    that cannot deliver to them.
-- ---------------------------------------------------------------------------
grant update (region_id) on public.profiles to authenticated;


-- ---------------------------------------------------------------------------
-- 6. profiles.region_chosen — did a HUMAN pick this region?
--
--    `region_id` is NOT NULL and defaults to 'EG', so there is no "unset"
--    state to detect and nothing to tell a real answer from the default. Same
--    problem `username_chosen` solves, solved the same way: record the fact at
--    the moment it is known instead of trying to infer it later.
--
--    Without this, onboarding either asks nobody (the default looks like an
--    answer) or asks everybody -- including a long-standing Egyptian player
--    sent back only to settle a handle, which is exactly the nag that column
--    was added to avoid.
--
--    THE BACKFILL GRANDFATHERS EVERY EXISTING PLAYER, on purpose: Egypt is the
--    only market the app has run in, so every current row is correctly
--    Egyptian and re-asking would be a prompt with one possible answer.
--    Guarded on app_settings so a re-run cannot un-answer a new signup.
--
--    ⚠️ WHEN YOU ADD A SECOND REGION, decide what happens to the accounts
--       created before it existed. They still carry region_chosen = false, so
--       they WILL be asked on their next trip through onboarding. That is
--       usually what you want ("we're in more places now -- where do you
--       play?"). To grandfather them instead, run:
--           update public.profiles set region_chosen = true;
--       It is deliberately not automatic, because which of the two is right
--       depends on whether the new region overlaps the old audience.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists region_chosen boolean not null default false;

comment on column public.profiles.region_chosen is
  'True when a human picked profiles.region_id. False means it is still the '
  '''EG'' default and onboarding owes the player the question -- but only once '
  'more than one region is active, since a one-option question is not worth '
  'asking. Written from the client, so it carries a column grant; it gates '
  'nothing but a prompt.';

-- Same silent-failure trap as username_chosen: without the grant PostgREST
-- refuses the write, reports no error, and onboarding asks again every launch.
-- Not a ranking or privilege column -- the worst a forged `true` buys is
-- skipping a question you could have answered anyway.
grant update (region_chosen) on public.profiles to authenticated;

do $$
declare v_marked int;
begin
  if exists (select 1 from public.app_settings where key = 'region_chosen_backfilled') then
    raise notice 'region_chosen backfill already ran (%), skipping',
      (select value from public.app_settings where key = 'region_chosen_backfilled');
    return;
  end if;

  update public.profiles set region_chosen = true where not region_chosen;
  get diagnostics v_marked = row_count;

  insert into public.app_settings(key, value)
  values ('region_chosen_backfilled', now()::text)
  on conflict (key) do update set value = excluded.value, updated_at = now();

  raise notice 'region_chosen: % existing players grandfathered as Egyptian', v_marked;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Verify the two column grants that fail silently when forgotten.
-- ---------------------------------------------------------------------------
do $$
declare c text;
begin
  for c in select unnest(array['region_id', 'region_chosen']) loop
    if not exists (
      select 1 from information_schema.column_privileges
       where table_schema = 'public' and table_name = 'profiles'
         and column_name = c
         and grantee = 'authenticated' and privilege_type = 'UPDATE')
    then
      raise exception 'authenticated has no UPDATE grant on profiles.%', c;
    end if;
  end loop;
  raise notice 'profiles.region_id and profiles.region_chosen are both writable by the client.';
end $$;
notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- Run these one at a time; the SQL editor shows only the last result set.

-- The region list. Expect exactly one row, EG, commerce on.
select id, name, currency_code, dial_code, commerce_enabled, active, sort
  from public.regions order by sort, id;

-- Every table carries the key and nothing was left null.
select 'profiles'    as tbl, count(*) as rows, count(region_id) as with_region from public.profiles
union all select 'courts',      count(*), count(region_id) from public.courts
union all select 'tournaments', count(*), count(region_id) from public.tournaments
union all select 'seasons',     count(*), count(region_id) from public.seasons;

-- All four foreign keys landed.
select conname, conrelid::regclass as tbl
  from pg_constraint
 where conname in ('profiles_region_id_fkey', 'courts_region_id_fkey',
                   'tournaments_region_id_fkey', 'seasons_region_id_fkey')
 order by conname;

-- The client can write region_id and still cannot write the ranking columns.
select column_name, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'profiles'
   and grantee = 'authenticated' and privilege_type = 'UPDATE'
 order by column_name;
