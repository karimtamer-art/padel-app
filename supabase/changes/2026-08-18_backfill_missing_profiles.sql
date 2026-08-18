-- 2026-08-18 — repair: auth users with no profiles row
--
-- WHY THIS IS POSSIBLE AT ALL
-- handle_new_user() is an AFTER INSERT trigger on auth.users that catches its
-- own exceptions and only `raise warning`s. That is deliberate — a profile
-- insert must never be able to block a signup — but the cost is that a failure
-- is INVISIBLE: the account is created, sign-in works, and the person lands in
-- an app where they have no profile, no player_ratings row, and therefore no
-- existence in rankings, matches or search. Its fallback path (`insert into
-- profiles (id)`) does not help when the failure comes from a trigger ON
-- profiles, because the minimal insert fires that same trigger.
--
-- Found via an Apple sign-in on 2026-08-18. Run the SELECT at the bottom first:
-- if it returns rows for signups other than that one, the cause is not
-- Apple-specific and the trigger itself still needs fixing — this file only
-- repairs the damage, it does not stop it happening again.
--
-- Safe to re-run: every statement is guarded on the row being absent.

-- ── 1. profiles ─────────────────────────────────────────────────────────────
-- Row by row, NOT one INSERT ... SELECT. _unique_username checks uniqueness by
-- querying profiles, and rows inserted earlier in the same statement are not
-- visible to it — a set-based insert could hand two users the same handle and
-- fail on profiles_username_key.
do $$
declare
  r      record;
  v_name text;
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
         v_name,
         public._unique_username(v_name, r.id),
         r.raw_user_meta_data->>'avatar_url',
         'right',
         'both')
      on conflict (id) do nothing;
      raise notice 'backfilled profile for %', r.id;
    exception when others then
      -- Loudly, unlike the trigger. If this fires, the message is the root
      -- cause we are looking for.
      raise warning 'could NOT backfill profile for %: %', r.id, sqlerrm;
    end;
  end loop;
end $$;

-- ── 2. player_ratings ───────────────────────────────────────────────────────
-- trg_player_ratings_row normally creates this on profile insert. Any profile
-- missing one either predates that trigger or hit the same failure. Defaults
-- give the correct cold start: rating NULL (unranked), sigma 0.95.
insert into public.player_ratings (player_id)
select p.id
from public.profiles p
left join public.player_ratings r on r.player_id = p.id
where r.player_id is null
on conflict (player_id) do nothing;

-- ── 3. verify — both must return zero rows ──────────────────────────────────
select 'auth user with no profile' as problem, u.id, u.email, u.created_at
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
union all
select 'profile with no player_ratings', p.id, null, p.created_at
from public.profiles p
left join public.player_ratings r on r.player_id = p.id
where r.player_id is null;
