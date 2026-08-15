-- ===========================================================================
-- player_ratings — move the ranking columns off `profiles` (2026-08-15)
--
-- Moves the 11 ranking columns off `profiles` into their own table. They do
-- not describe a person: they are engine state, written on every settled match
-- (where the rest of the row is written almost never), owned exclusively by
-- the server, and they are the anti-cheat boundary.
--
-- DONE IN ONE MOVE, not phased behind a mirror. A phased version — keep the
-- profiles columns as trigger-maintained copies, migrate readers later, drop
-- them last — buys uptime, and this app has no users yet beyond testers.
-- Paying for uptime you do not need costs a duplicate write path, a mirror
-- trigger and eleven columns that everyone has to remember are not the real
-- ones. Better to land it clean while that is still cheap.
--
-- The safety net instead is section 6: before the old columns are dropped, the
-- catalog is swept for any function still reading profiles.<ranking column>,
-- and the migration ABORTS naming it. A missed reader is caught here rather
-- than at runtime.
--
-- A REAL GAIN: player_ratings has NO column grants to
-- `authenticated` at all. On profiles, `rating` is safe because somebody
-- remembered not to grant it — and that exact omission is what broke the
-- notify_* columns for six weeks (2026-08-14). Here it is safe by
-- construction: clients cannot write the table, full stop.
--
-- Idempotent.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The table. Same types, same defaults, same generated expressions as the
--    profiles columns it replaces, so the backfill is a straight copy.
-- ---------------------------------------------------------------------------
create table if not exists public.player_ratings (
  player_id uuid primary key references public.profiles(id) on delete cascade,

  -- ── engine state (V3-F5) ──
  -- Full internal precision; the engine does no rounding of its own.
  rating      numeric(9,6),
  sigma       numeric not null default 0.95,
  is_anchor   boolean not null default false,
  competitive_matches int not null default 0,
  last_competitive_match_at timestamptz,

  -- ── display mirrors of rating, never read back into the math ──
  level       numeric,
  tier        text,

  -- ── placement / reveal ──
  placement_played   int     not null default 0,
  placement_revealed boolean not null default false,

  updated_at timestamptz not null default now()
);

do $$ begin
  alter table public.player_ratings
    add constraint player_ratings_sigma_range check (sigma >= 0.12 and sigma <= 1.0);
exception when duplicate_object then null; end $$;

alter table public.player_ratings
  add column if not exists reliability numeric
    generated always as (round((1 - sigma / 1.0) * 100, 0)) stored;
alter table public.player_ratings
  add column if not exists is_provisional boolean
    generated always as (sigma > 0.58 or competitive_matches < 20) stored;

comment on table public.player_ratings is
  'V3-F5 engine state, one row per player. Server-written only: no column '
  'grants to authenticated exist, so the anti-cheat boundary is structural '
  'rather than a rule someone has to remember. The equivalent profiles '
  'columns were dropped in the same change; there is no mirror.';

create index if not exists player_ratings_rating_idx
  on public.player_ratings (rating desc nulls last);

-- ---------------------------------------------------------------------------
-- 2. Backfill. Every profile gets a row, so readers never need to care about
--    a missing one.
-- ---------------------------------------------------------------------------
-- Guarded: section 5 drops the source columns, so on any RE-RUN this copy
-- must not be attempted. The second branch still gives every profile a row.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='rating') then
    execute $q$
      insert into public.player_ratings (
        player_id, rating, sigma, is_anchor, competitive_matches,
        last_competitive_match_at, level, tier, placement_played,
        placement_revealed)
      select p.id, p.rating, coalesce(p.sigma, 0.95),
             coalesce(p.is_anchor, false), coalesce(p.competitive_matches, 0),
             p.last_competitive_match_at, p.level, p.tier,
             coalesce(p.placement_played, 0), coalesce(p.placement_revealed, false)
        from public.profiles p
      on conflict (player_id) do nothing
    $q$;
  else
    insert into public.player_ratings (player_id)
    select p.id from public.profiles p
    on conflict (player_id) do nothing;
  end if;
end $$;

-- New signups get their row automatically, so handle_new_user does not have to
-- remember (and neither does any future path that creates a profile).
create or replace function public._player_ratings_row()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.player_ratings (player_id) values (new.id)
  on conflict (player_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_player_ratings_row on public.profiles;
create trigger trg_player_ratings_row
  after insert on public.profiles
  for each row execute function public._player_ratings_row();

-- ---------------------------------------------------------------------------
-- 3. RLS. Ratings are not secret — they are on every player card, lobby row
--    and leaderboard — so any signed-in user may READ. Nobody may write:
--    there is no insert/update/delete policy and no column grant, so the only
--    writers are SECURITY DEFINER functions (the engine and the admin RPC).
-- ---------------------------------------------------------------------------
alter table public.player_ratings enable row level security;

do $$ begin
  create policy "player_ratings: read all" on public.player_ratings
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

grant select on public.player_ratings to authenticated;
revoke insert, update, delete on public.player_ratings from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 4. Every reader and writer now uses player_ratings. Before the old columns
--    go, prove nothing still reaches for them.
--
--    This is the check that makes a one-shot move safe: ~22 functions were
--    rewritten by hand against a database this environment cannot compile
--    against, so the catalog gets the last word.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname not in ('_player_ratings_row')
     and p.prosrc ~ 'profiles'
     and p.prosrc ~ '\m(rating|sigma|is_anchor|competitive_matches|placement_played|placement_revealed|last_competitive_match_at|is_provisional|reliability)\M'
     and p.prosrc !~ 'player_ratings';
  if v_bad is not null then
    raise exception 'function(s) still read a ranking column off profiles: %', v_bad
      using hint = 'Point them at player_ratings before dropping the columns.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Drop the old columns. Views first, if anything grew on them.
-- ---------------------------------------------------------------------------
do $$
declare v_dep text;
begin
  select string_agg(distinct dep.relname, ', ') into v_dep
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    join pg_class dep  on dep.oid = rw.ev_class
    join pg_class src  on src.oid = d.refobjid
    join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
   where src.relname = 'profiles'
     and a.attname in ('rating','sigma','level','tier','is_anchor',
                       'competitive_matches','last_competitive_match_at',
                       'placement_played','placement_revealed',
                       'is_provisional','reliability')
     and dep.relkind = 'v';
  if v_dep is not null then
    raise exception 'view(s) depend on the ranking columns: %', v_dep;
  end if;
end $$;

alter table public.profiles drop column if exists is_provisional;
alter table public.profiles drop column if exists reliability;
alter table public.profiles drop column if exists rating;
alter table public.profiles drop column if exists sigma;
alter table public.profiles drop column if exists level;
alter table public.profiles drop column if exists tier;
alter table public.profiles drop column if exists is_anchor;
alter table public.profiles drop column if exists competitive_matches;
alter table public.profiles drop column if exists last_competitive_match_at;
alter table public.profiles drop column if exists placement_played;
alter table public.profiles drop column if exists placement_revealed;

-- ---------------------------------------------------------------------------
-- 6. Verify before anyone relies on it.
-- ---------------------------------------------------------------------------
do $$
declare v_p bigint; v_r bigint; v_bad bigint;
begin
  select count(*) into v_p from public.profiles;
  select count(*) into v_r from public.player_ratings;
  if v_p <> v_r then
    raise exception 'player_ratings has % row(s) for % profile(s)', v_r, v_p
      using hint = 'the backfill missed someone — investigate before phase 2';
  end if;

  select count(*) into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name in ('rating','sigma','level','tier','is_anchor',
                         'competitive_matches','last_competitive_match_at',
                         'placement_played','placement_revealed',
                         'is_provisional','reliability');
  if v_bad > 0 then
    raise exception '% ranking column(s) still on profiles', v_bad;
  end if;

  -- the boundary this whole table exists to make structural
  if exists (select 1 from information_schema.column_privileges
              where table_schema='public' and table_name='player_ratings'
                and grantee in ('authenticated','anon')
                and privilege_type in ('UPDATE','INSERT','DELETE')) then
    raise exception 'a client can write player_ratings — that is the anti-cheat boundary';
  end if;

  raise notice 'player_ratings: % row(s) backfilled and mirrored.', v_r;
end $$;

notify pgrst, 'reload schema';
