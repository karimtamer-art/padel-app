-- ============================================================================
-- 2026-08-20 — profiles.username_chosen: did a HUMAN pick this handle?
-- ============================================================================
-- Run this on the live DB. Safe to re-run: the column add is guarded, and the
-- one-time backfill is gated on app_settings('username_chosen_backfilled') so
-- it cannot re-nag players who have since settled their handle.
--
-- ⚠️ RUN THIS BEFORE SHIPPING THE CLIENT THAT GOES WITH IT. The new client
--    SELECTs username_chosen and writes it when onboarding finishes. The read
--    degrades safely (ProfileService.fetch falls back and treats the answer as
--    "already chosen", so nobody is prompted), but do not leave the two out of
--    step longer than a deploy.
--
-- ── Why ─────────────────────────────────────────────────────────────────────
-- Until now the only handle onboarding offered to fix was one matching
-- `player<6hex>` — the branch _unique_username takes when it has NOTHING to
-- work with. Everything else was assumed chosen. It usually was not:
--
--   * a Google signup never types a handle. `Karim Tamer` becomes `karimtamer`
--     server-side, which looks chosen and is not, and that player was never
--     asked once.
--   * an email signup whose typed handle was TAKEN got a near-miss generated
--     for it (see 2026-08-20_username_collision.sql), which also looks chosen.
--
-- A pattern can't tell those from a real choice, because there is nothing in
-- the string to tell. So record the fact at the moment it is known instead of
-- trying to infer it afterwards. That is the entire point of this column.
--
-- ── The backfill grandfathers existing players, on purpose ──────────────────
-- Existing rows are marked chosen when their handle does NOT look generated.
-- We cannot actually know whether those were typed or derived, and the cost of
-- guessing wrong in each direction is not symmetric: marking one chosen that
-- was not means someone keeps a name-derived handle they would probably have
-- picked anyway, while marking every existing player unchosen drops the ENTIRE
-- user base into onboarding on their next launch to answer a question most of
-- them do not have a problem with. Only handles that are visibly junk
-- (`player3f9a1c`, or missing entirely) are left false, and those people
-- genuinely need the prompt.
--
-- To nag everyone instead, run this by hand afterwards — it is deliberately
-- not the default:
--     update public.profiles set username_chosen = false;
-- ============================================================================

-- ── 1. the column ───────────────────────────────────────────────────────────
alter table public.profiles
  add column if not exists username_chosen boolean not null default false;

comment on column public.profiles.username_chosen is
  'True when a human picked this handle (typed at signup, confirmed in '
  'onboarding, or edited in Edit Profile). False means _unique_username '
  'generated it and onboarding still owes the player a prompt. Set from the '
  'client, so it carries a column grant; it gates nothing but a question.';

-- The client writes this when onboarding finishes. profiles uses COLUMN-LEVEL
-- grants (migrations/0004), so without this line the write is refused silently
-- and the player is asked the same question on every launch. It is not a
-- ranking or privilege column — the worst a forged `true` buys you is skipping
-- a prompt you could have answered anyway.
grant update (username_chosen) on public.profiles to authenticated;

-- ── 2. record the answer at signup ──────────────────────────────────────────
-- Identical to the current handle_new_user except for v_typed / the
-- username_chosen column. The handle is "chosen" only when the username that
-- arrived in the signup metadata was used VERBATIM — that is exactly the case
-- where a person typed it and got what they asked for. Every other path
-- (invalid, absent, or taken and therefore deduped) leaves it false so
-- onboarding asks.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public as $$
declare
  v_name     text;
  v_username text;
  v_typed    boolean := false;
  v_dob      date;
  v_gender   text;
  v_hand     text;
  v_side     text;
begin
  v_name := nullif(trim(coalesce(new.raw_user_meta_data->>'name',
                                 new.raw_user_meta_data->>'full_name', '')), '');

  -- keep a valid, free handle from signup metadata; otherwise generate one
  v_username := nullif(lower(trim(coalesce(new.raw_user_meta_data->>'username', ''))), '');
  if v_username is null
     or v_username !~ '^[a-z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where lower(username) = v_username) then
    v_username := public._unique_username(coalesce(v_username, v_name), new.id);
  else
    v_typed := true;
  end if;
  begin
    v_dob := nullif(new.raw_user_meta_data->>'date_of_birth', '')::date;
  exception when others then
    v_dob := null;
  end;
  if v_dob is not null and (v_dob > current_date - interval '13 years'
                         or v_dob < current_date - interval '100 years') then
    v_dob := null;
  end if;
  v_gender := nullif(new.raw_user_meta_data->>'gender', '');
  if v_gender is not null and v_gender not in ('male','female') then v_gender := null; end if;
  v_hand := nullif(new.raw_user_meta_data->>'preferred_hand', '');
  if v_hand not in ('right','left') then v_hand := null; end if;
  v_side := nullif(new.raw_user_meta_data->>'preferred_court_side', '');
  if v_side not in ('left','right','both') then v_side := null; end if;

  begin
    insert into public.profiles
      (id, name, username, username_chosen, avatar_url, phone, bio,
       date_of_birth, gender, preferred_hand, preferred_court_side)
    values
      (new.id, v_name, v_username, v_typed,
       new.raw_user_meta_data->>'avatar_url',
       nullif(new.raw_user_meta_data->>'phone', ''),
       nullif(new.raw_user_meta_data->>'bio', ''),
       v_dob, v_gender,
       coalesce(v_hand, 'right'),
       coalesce(v_side, 'both'))
    -- Ranking state is NOT set here. trg_player_ratings_row creates the
    -- player_ratings row from its defaults: rating NULL (unranked), sigma
    -- 0.95 (the V3-F5 prior's uncertainty), placement_played 0. The player
    -- earns a rating over 5 placement matches, or an admin sets one.
    on conflict (id) do nothing;
  exception when others then
    raise warning 'handle_new_user: % — inserting minimal profile for %', sqlerrm, new.id;
    begin
      insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
    exception when others then
      raise warning 'handle_new_user minimal insert also failed: %', sqlerrm;
    end;
  end;
  return new;
end $$;

-- ── 3. one-time backfill ────────────────────────────────────────────────────
do $$
declare
  v_marked int;
begin
  if exists (select 1 from public.app_settings where key = 'username_chosen_backfilled') then
    raise notice 'username_chosen backfill already ran (%), skipping',
      (select value from public.app_settings where key = 'username_chosen_backfilled');
    return;
  end if;

  -- `{6,}` not `{6}`: _unique_username dedupes by appending a decimal suffix,
  -- and decimal digits are hex digits. Anchored at exactly six, `player3f9a1c1`
  -- reads as a chosen handle and would be grandfathered in as one. Mirrors
  -- OnboardingProfile.isGeneratedUsername.
  update public.profiles
     set username_chosen = true
   where username is not null
     and trim(username) <> ''
     and lower(trim(username)) !~ '^player[0-9a-f]{6,}$';
  get diagnostics v_marked = row_count;

  insert into public.app_settings(key, value)
  values ('username_chosen_backfilled', now()::text)
  on conflict (key) do update set value = excluded.value, updated_at = now();

  raise notice 'username_chosen: % existing handles grandfathered as chosen', v_marked;
end $$;

-- ── verify ──────────────────────────────────────────────────────────────────
do $$
declare
  v_total    int;
  v_chosen   int;
  v_pending  int;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'username_chosen')
  then
    raise exception 'profiles.username_chosen was not created';
  end if;

  -- The grant is the half that fails SILENTLY when forgotten: PostgREST
  -- refuses the write, reports no error, and onboarding re-asks forever.
  if not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'username_chosen'
       and grantee = 'authenticated' and privilege_type = 'UPDATE')
  then
    raise exception 'authenticated has no UPDATE grant on profiles.username_chosen';
  end if;

  select count(*),
         count(*) filter (where username_chosen),
         count(*) filter (where not username_chosen)
    into v_total, v_chosen, v_pending
    from public.profiles;

  raise notice 'profiles: % total, % chosen, % will be asked at next onboarding',
    v_total, v_chosen, v_pending;

  -- Anything still pending should be a junk or missing handle. A large number
  -- here means the backfill pattern did not match what is actually stored.
  perform 1;
end $$;

-- Who is still pending, so the number above can be eyeballed rather than
-- trusted. Expect `player<hex>` handles and NULLs, nothing else.
select coalesce(username, '(null)') as username, count(*) as players
  from public.profiles
 where not username_chosen
 group by 1
 order by 2 desc, 1
 limit 50;
