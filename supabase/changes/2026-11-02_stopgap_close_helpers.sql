-- STOPGAP: close the eight internal functions that do the most damage if called
-- directly. Supabase grants every public function to anon and authenticated, and the
-- 2026-11-02 live audit shows all eight callable by both, with only the public anon key.
--
-- Safe to re-run. It stops before changing anything if anything on the database that
-- runs AS THE CALLER (a non-definer function, RLS policy, view, default or CHECK) uses
-- one of the eight, because closing it would break that for everyone.
--
-- Everything that calls these in the repo is SECURITY DEFINER and owned by postgres, as
-- are the eight themselves, so it keeps working: finalise, draws, score confirmation,
-- reports and the weekly decay job. No client in git history, old builds included, ever
-- called them directly.
--
-- This is not the full lock-down. See supabase/proposals/2026-11-02_lock_down_functions.sql.
-- ROLLBACK: supabase/rollbacks/2026-11-02_stopgap_close_helpers_rollback.sql (reopens the hole).

do $stopgap$
declare
  v_pattern constant text := '\y(_finance_core|_advance_winner|apply_rating_decay|'
    || '_award_tournament_season_points|_award_season_points|_settle_rating|'
    || '_invite_partner|_seed_season_defaults)\y';
  v_found text;
begin
  select string_agg(what, ', ') into v_found from (
    select 'function ' || p.proname as what
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog', 'information_schema')
       and not p.prosecdef and p.prosrc ~ v_pattern
    union all
    select 'policy ' || pol.polname
      from pg_policy pol
     where coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ~ v_pattern
        or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') ~ v_pattern
    union all
    select 'view ' || c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('v', 'm') and n.nspname = 'public'
       and pg_get_viewdef(c.oid) ~ v_pattern
    union all
    select 'column default on ' || ad.adrelid::regclass::text
      from pg_attrdef ad
     where pg_get_expr(ad.adbin, ad.adrelid) ~ v_pattern
    union all
    select 'check ' || con.conname
      from pg_constraint con
     where con.contype = 'c' and pg_get_constraintdef(con.oid) ~ v_pattern
  ) uses;

  if v_found is not null then
    raise exception 'Stopgap stopped, nothing changed. These run as the caller and use a function being closed: %', v_found;
  end if;

  revoke all on function public._finance_core(date, date) from public, anon, authenticated;
  revoke all on function public._advance_winner(uuid, text, int, int, uuid) from public, anon, authenticated;
  revoke all on function public.apply_rating_decay() from public, anon, authenticated;
  revoke all on function public._award_tournament_season_points(uuid) from public, anon, authenticated;
  revoke all on function public._award_season_points(uuid) from public, anon, authenticated;
  revoke all on function public._settle_rating(uuid) from public, anon, authenticated;
  revoke all on function public._invite_partner(uuid, uuid, text) from public, anon, authenticated;
  revoke all on function public._seed_season_defaults(uuid) from public, anon, authenticated;
end $stopgap$;

-- ── VERIFY: every row should say ok = true ──────────────────────────────────
select 'closed: ' || f as check_name,
       not has_function_privilege('anon', f, 'execute')
         and not has_function_privilege('authenticated', f, 'execute') as ok,
       'anon and signed-in users refused' as detail
  from unnest(array[
    'public._finance_core(date, date)',
    'public._advance_winner(uuid, text, int, int, uuid)',
    'public.apply_rating_decay()',
    'public._award_tournament_season_points(uuid)',
    'public._award_season_points(uuid)',
    'public._settle_rating(uuid)',
    'public._invite_partner(uuid, uuid, text)',
    'public._seed_season_defaults(uuid)']) f
union all
select 'still open to the app: ' || f,
       has_function_privilege('authenticated', f, 'execute'),
       'signed-in users allowed'
  from unnest(array[
    'public.admin_finance_summary(date, date)',
    'public.finalize_tournament(uuid)',
    'public.record_bracket_winner(uuid, uuid, text)',
    'public.confirm_match_result(uuid, boolean)',
    'public.join_match(uuid, text, uuid)']) f;
