-- 2026-08-10 — How did this email sign up?
--
-- "Forgot password?" happens while signed OUT, so the app cannot read
-- auth.identities to find out whether the account even HAS a password. A
-- Google-only or Apple-only account has nothing to reset: Supabase happily
-- mails a recovery link, the player sets a password that was never the way
-- they log in, and the confusion looks like a broken app.
--
-- This returns the providers behind an email so the sign-in screen can say
-- "you signed up with Google — use that button" instead of sending a useless
-- email.
--
-- ENUMERATION. Yes, this tells a caller whether an email is registered and how.
-- That trade-off was already made deliberately for `email_exists()` right above
-- this in the schema (so login can tell an unknown email from a wrong
-- password); this is the same decision, one field wider. If the project ever
-- revisits it, both functions go together.
--
-- Safe to re-run. Also folded into migration_player_app.sql.

create or replace function public.email_login_methods(p_email text)
returns text[]
language sql
security definer
set search_path = auth, public
stable as $$
  select coalesce(array_agg(distinct i.provider order by i.provider), '{}'::text[])
    from auth.users u
    join auth.identities i on i.user_id = u.id
   where lower(u.email) = lower(trim(p_email));
$$;
grant execute on function public.email_login_methods(text) to anon, authenticated;

notify pgrst, 'reload schema';
