-- ============================================================================
-- Padel · Profiles + mandatory onboarding (Supabase / Postgres)
-- Run in the Supabase SQL editor or as a migration.
--
-- Adds the four onboarding fields to `profiles`, a SERVER-COMPUTED
-- `onboarding_completed` flag (so the client can never lie about it), the RLS
-- policies that let a user read/write only their own row, and a trigger that
-- auto-creates a profile row the moment a user signs up (incl. Google OAuth).
-- ============================================================================

-- 1. BASE TABLE --------------------------------------------------------------
-- Safe whether or not `profiles` already exists.
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 2. ONBOARDING FIELDS -------------------------------------------------------
alter table public.profiles
  add column if not exists date_of_birth        date,
  add column if not exists gender               text,
  add column if not exists preferred_hand       text,
  add column if not exists preferred_court_side text;

-- Allowed values (match the Flutter enums). Re-runnable.
alter table public.profiles drop constraint if exists profiles_gender_chk;
alter table public.profiles add  constraint profiles_gender_chk
  check (gender is null or gender in ('male','female'));

alter table public.profiles drop constraint if exists profiles_hand_chk;
alter table public.profiles add  constraint profiles_hand_chk
  check (preferred_hand is null or preferred_hand in ('right','left'));

alter table public.profiles drop constraint if exists profiles_side_chk;
alter table public.profiles add  constraint profiles_side_chk
  check (preferred_court_side is null or preferred_court_side in ('left','right'));

-- Reasonable DOB bound (13–100). The client validates too; this is the backstop.
alter table public.profiles drop constraint if exists profiles_dob_chk;
alter table public.profiles add  constraint profiles_dob_chk
  check (
    date_of_birth is null
    or (date_of_birth <= (current_date - interval '13 years')
        and date_of_birth >= (current_date - interval '100 years'))
  );

-- 3. SERVER-OWNED COMPLETION FLAG -------------------------------------------
-- Generated column: true only when ALL four fields are present. The app reads
-- this; it cannot be set directly, so onboarding can't be skipped client-side.
alter table public.profiles drop column if exists onboarding_completed;
alter table public.profiles add  column onboarding_completed boolean
  generated always as (
    date_of_birth is not null
    and gender is not null
    and preferred_hand is not null
    and preferred_court_side is not null
  ) stored;

-- 4. updated_at TOUCH --------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end; $$;

drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- 5. AUTO-CREATE PROFILE ON SIGNUP ------------------------------------------
-- Fires for every new auth user — email/password AND Google OAuth. Pulls name
-- + avatar from the OAuth metadata when present. Onboarding fields stay null,
-- so a fresh Google user lands in onboarding until they finish it.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill: create rows for any existing users that predate the trigger.
insert into public.profiles (id)
select u.id from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

-- 6. ROW-LEVEL SECURITY ------------------------------------------------------
alter table public.profiles enable row level security;

drop policy if exists "profiles: read own" on public.profiles;
create policy "profiles: read own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles: insert own" on public.profiles;
create policy "profiles: insert own" on public.profiles
  for insert with check (auth.uid() = id);

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- NOTE: `onboarding_completed` is a generated column — it is NOT writable, so
-- even the owner cannot mark themselves complete without supplying real values.
-- For public profile data (leaderboards/opponents) expose a separate VIEW with
-- only the non-sensitive columns rather than loosening these policies.
