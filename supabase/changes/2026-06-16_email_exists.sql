-- ============================================================
-- Incremental change · 2026-06-16
-- email_exists() — lets sign-in tell "unknown email" from "wrong password"
-- ------------------------------------------------------------
-- Supabase returns one generic "Invalid login credentials" for both cases.
-- This function checks whether an email is registered so the app can show a
-- precise message. TRADEOFF: this is an account-enumeration vector (callers
-- can discover which emails have accounts). Accepted deliberately.
-- Also folded into the canonical migration. Idempotent.
-- ============================================================

create or replace function public.email_exists(p_email text)
returns boolean
language sql
security definer
set search_path = auth, public
stable as $$
  select exists (
    select 1 from auth.users where lower(email) = lower(trim(p_email))
  );
$$;

-- Callable before login (anon) and after.
grant execute on function public.email_exists(text) to anon, authenticated;

notify pgrst, 'reload schema';
