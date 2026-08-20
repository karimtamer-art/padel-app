-- ============================================================================
-- 2026-08-20 — username generation: keep the seed's shape when it collides
-- ============================================================================
-- Run this on the live DB. Idempotent (create or replace only). It changes no
-- data: only how a handle is generated from here on.
--
-- Two problems, both about what happens when the handle a player asked for is
-- ALREADY TAKEN. handle_new_user() passes the username typed at signup as the
-- seed, so this is not a rare path — SignUpFlow checks availability on step 1
-- and the account is created two steps later, so anything can happen in
-- between, and isUsernameAvailable() deliberately fails OPEN on a network
-- error.
--
-- 1. The seed was stripped of underscores. `_` is legal in a handle
--    (profiles_username_chk allows [a-z0-9_]), so a taken `karim_h` came back
--    as `karimh` — a different person's-looking name, assigned silently, with
--    nothing telling the player. Now only characters the CHECK actually
--    forbids are stripped, so a collision dedupes to `karim_h1`: still
--    recognisably theirs.
--
-- 2. A seed with no letters or digits at all could produce a base of pure
--    punctuation ('___', or a name written in a non-Latin script once the
--    Latin filter had eaten it). Three underscores passes the CHECK and is a
--    useless handle. Those now fall through to the `player<hex>` branch, which
--    is what the client's OnboardingProfile.isGeneratedUsername looks for — so
--    onboarding ASKS for a real one instead of leaving junk in place. This
--    matters here specifically: an Egyptian player whose Google account name
--    is in Arabic hits it on every signup.
--
-- The fallback's dedupe suffix is unchanged and is deliberately still decimal:
-- `player3f9a1c` → `player3f9a1c1`. Decimal digits are hex digits too, so the
-- suffixed form still matches the client's `^player[0-9a-f]{6,}$` and is still
-- recognised as generated. That pairing is the whole fix for the collision
-- edge case — change one, change the other. It is pinned by
-- test/username_generation_test.dart.
-- ============================================================================

create or replace function public._unique_username(p_seed text, p_fallback_id uuid)
returns text
language plpgsql
security definer set search_path = public as $$
declare
  base text;
  cand text;
  n int := 0;
begin
  -- Strip only what profiles_username_chk forbids. Dropping `_` as well is
  -- what turned a taken `karim_h` into `karimh`.
  base := regexp_replace(lower(coalesce(p_seed, '')), '[^a-z0-9_]+', '', 'g');
  -- Too short, or nothing but punctuation: not a handle however long it is.
  -- The fallback is the shape the client recognises as auto-generated.
  if length(base) < 3 or base !~ '[a-z0-9]' then
    base := 'player' || substr(replace(p_fallback_id::text, '-', ''), 1, 6);
  end if;
  base := substr(base, 1, 16);
  cand := base;
  while exists (select 1 from public.profiles where lower(username) = cand) loop
    n := n + 1;
    cand := substr(base, 1, 16 - length(n::text)) || n::text;
  end loop;
  return cand;
end $$;

-- ── verify ──────────────────────────────────────────────────────────────────
-- Pure function, no writes, so this is safe to re-run. Raises rather than
-- printing a table: a silent wrong answer here is how someone ends up with a
-- handle that is not theirs.
do $$
declare
  v_id  uuid := '00000000-0000-0000-0000-0000000000ab';
  v_out text;
begin
  -- 1. an underscore survives the round trip
  v_out := public._unique_username('karim_h', v_id);
  if v_out !~ '^karim_h' then
    raise exception 'seed karim_h should keep its shape, got %', v_out;
  end if;
  raise notice 'karim_h -> %', v_out;

  -- 2. punctuation-only seed takes the player<hex> fallback
  v_out := public._unique_username('___', v_id);
  if v_out !~ '^player[0-9a-f]{6}' then
    raise exception 'punctuation-only seed should fall back, got %', v_out;
  end if;
  raise notice '___ -> %', v_out;

  -- 3. empty seed still falls back
  v_out := public._unique_username(null, v_id);
  if v_out !~ '^player[0-9a-f]{6}' then
    raise exception 'null seed should fall back, got %', v_out;
  end if;
  raise notice 'null -> %', v_out;

  -- 4. whatever comes out is always a legal handle
  if v_out !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'generated an invalid handle: %', v_out;
  end if;
end $$;
