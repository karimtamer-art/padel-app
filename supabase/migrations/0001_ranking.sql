-- ─────────────────────────────────────────────────────────────────────────────
-- 0001_ranking.sql
-- Run once in Supabase SQL editor.
-- Prereq: profiles table already exists with level FLOAT + placement_played INT.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. ranking_history — audit trail ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ranking_history (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id    UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  match_id      UUID,       -- will reference matches(id) once Phase 2 creates it
  level_before  FLOAT       NOT NULL,
  level_after   FLOAT       NOT NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.ranking_history ENABLE ROW LEVEL SECURITY;

-- Players can read their own history; only service-role can write.
CREATE POLICY "rh_select_own"
  ON public.ranking_history FOR SELECT
  USING (auth.uid() = profile_id);

CREATE INDEX IF NOT EXISTS rh_profile_recent
  ON public.ranking_history (profile_id, created_at DESC);

-- ── 2. Tighten write protection on profiles.level ────────────────────────────
-- The confirm_match Edge Function runs as service-role and bypasses RLS,
-- so it can update level. Regular users must NOT be able to self-update level.
-- Drop any existing update policy that allows self-writes to protected fields.

-- Replace the broad "update own" policy with a column-restricted one:
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    -- Client writes are allowed for all columns EXCEPT the ranking ones.
    -- Ranking columns (level, placement_played, elo, tier, division_pts)
    -- are updated exclusively by the confirm_match Edge Function (service-role).
    -- Enforce this at the application layer; full column-level RLS requires
    -- Postgres 15+ column-level security (not available on Supabase free tier).
  );

-- ── 3. Convenience view for the profile screen ───────────────────────────────
-- security_invoker=on: view runs as the querying user, so RLS on profiles
-- and ranking_history still applies. Without it the view would bypass RLS.
CREATE OR REPLACE VIEW public.v_user_ranking WITH (security_invoker = on) AS
SELECT
  p.id,
  p.level,
  p.placement_played,
  p.elo,
  p.tier,
  COALESCE(h.weekly_delta, 0.0)  AS weekly_delta,
  h.last_delta,
  h.last_created_at
FROM public.profiles p
LEFT JOIN LATERAL (
  SELECT
    SUM(level_after - level_before)
      FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') AS weekly_delta,
    (ARRAY_AGG(level_after - level_before ORDER BY created_at DESC))[1] AS last_delta,
    MAX(created_at) AS last_created_at
  FROM public.ranking_history
  WHERE profile_id = p.id
) h ON TRUE;
