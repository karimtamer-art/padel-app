-- 2026-08-19 — profiles.name must be NULLABLE, or Apple signups get no profile
--
-- THE FAILURE
--   handle_new_user: null value in column "name" of relation "profiles"
--                    violates not-null constraint
--   handle_new_user minimal insert also failed: <the same message>
--
-- Apple puts the user's name in the CREDENTIAL, not the ID token, and only on
-- the very first authorization ever — so an Apple signup reaches
-- handle_new_user() with no name at all and v_name is NULL. On live,
-- profiles.name is NOT NULL (the repo declares profiles inside a
-- `create table if not exists` block, which is skipped on a database that
-- already had the table, so the repo's nullable definition never applied).
--
-- Both branches then die the same death: the main insert violates the
-- constraint, and the exception handler's fallback `insert into profiles (id)`
-- leaves name NULL too, so it violates it as well. The trigger only
-- `raise warning`s — deliberately, so a profile insert can never block a
-- signup — and the result is an auth user with NO profile row, no
-- player_ratings row, and no existence in rankings, matches or search.
--
-- WHY NOBODY SAW IT UNTIL NOW
-- The old client wrote `user.email` as the display name when it had nothing
-- better, which satisfied NOT NULL by accident and created the row. That is why
-- Hide-My-Email players were listed as x7k2m9@privaterelay.appleid.com. Fixing
-- that (2026-08-18, commit 1012000) correctly stopped writing an email as a
-- name — and removed the accident that was hiding this constraint.
--
-- NULL is the CORRECT state for a nameless signup: OnboardingProfile.isUsableName
-- treats NULL as "still need to ask", and the onboarding flow now has a name
-- step that asks. Defaulting to 'Player' here instead would make the account
-- look answered and skip the question.

-- ── 1. the fix ──────────────────────────────────────────────────────────────
-- Guarded so re-running is a no-op and so this is safe on a database where the
-- column is already nullable (a fresh one built from migration_player_app.sql).
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'profiles'
       and column_name  = 'name'
       and is_nullable  = 'NO'
  ) then
    alter table public.profiles alter column name drop not null;
    raise notice 'profiles.name is now nullable';
  else
    raise notice 'profiles.name was already nullable — nothing to do';
  end if;
end $$;

-- ── 2. repair the accounts this already broke ───────────────────────────────
-- Row by row, NOT one INSERT ... SELECT: _unique_username checks uniqueness by
-- querying profiles, and rows inserted earlier in the same statement are not
-- visible to it, so a set-based insert could hand two users the same handle and
-- fail on profiles_username_key.
do $$
declare
  r      record;
  v_name text;
  n      int := 0;
begin
  for r in
    select u.id, u.raw_user_meta_data
      from auth.users u
      left join public.profiles p on p.id = u.id
     where p.id is null
     order by u.created_at
  loop
    v_name := nullif(trim(coalesce(r.raw_user_meta_data->>'name',
                                   r.raw_user_meta_data->>'full_name', '')), '');
    begin
      insert into public.profiles
        (id, name, username, avatar_url, preferred_hand, preferred_court_side)
      values
        (r.id,
         v_name,                                        -- may be NULL; onboarding asks
         public._unique_username(v_name, r.id),
         r.raw_user_meta_data->>'avatar_url',
         'right',
         'both')
      on conflict (id) do nothing;
      n := n + 1;
    exception when others then
      raise warning 'could NOT backfill profile for %: %', r.id, sqlerrm;
    end;
  end loop;
  raise notice 'backfilled % missing profile row(s)', n;
end $$;

-- Accounts that got a row from the OLD client-side insert never went through
-- _unique_username, so they have no handle and cannot be found in any partner
-- picker. Give them one.
do $$
declare r record; n int := 0;
begin
  for r in select id, name from public.profiles where username is null loop
    update public.profiles
       set username = public._unique_username(r.name, r.id)
     where id = r.id;
    n := n + 1;
  end loop;
  raise notice 'minted % missing username(s)', n;
end $$;

-- player_ratings for anything the above created (trg_player_ratings_row handles
-- new inserts; this catches rows that predate it or hit the same failure).
insert into public.player_ratings (player_id)
select p.id
  from public.profiles p
  left join public.player_ratings r on r.player_id = p.id
 where r.player_id is null
on conflict (player_id) do nothing;

-- ── 3. verify — all three must return zero rows ─────────────────────────────
select 'profiles.name still NOT NULL' as problem, null::uuid as id
  from information_schema.columns
 where table_schema='public' and table_name='profiles'
   and column_name='name' and is_nullable='NO'
union all
select 'auth user with no profile', u.id
  from auth.users u
  left join public.profiles p on p.id = u.id
 where p.id is null
union all
select 'profile with no username', p.id
  from public.profiles p
 where p.username is null;
