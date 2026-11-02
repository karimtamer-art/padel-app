-- Players must not be able to write their own tournament_entries row. NOT APPLIED.
-- Live has FOUR player write policies (2 Nov schema dump). Two came from older migrations
-- and aren't in migration_player_app.sql:
--   "register self"                  insert, any column, including status = 'paid'
--   "tournament_entries: insert own" the same
--   "withdraw self"                  update, any column, including status = 'paid'
--   "t_entries: withdraw own"        update to withdrawn, skipping the refund rule
-- So a signed-in player can confirm themselves with no payment, and that entry then
-- counts as income in the P&L. Every player path now goes through a SECURITY DEFINER RPC
-- (register_for_tournament, withdraw_from_tournament, pay_partner_share,
-- resubmit_payment_proof), so nothing the current app does needs these policies.
-- Organiser and admin writes have their own policies and are untouched.
--
-- Builds from before InstaPay payments wrote directly; that was June 2026.
-- ROLLBACK: supabase/rollbacks/2026-11-02_entries_no_self_write_rollback.sql

drop policy if exists "register self" on public.tournament_entries;
drop policy if exists "tournament_entries: insert own" on public.tournament_entries;
drop policy if exists "withdraw self" on public.tournament_entries;
drop policy if exists "t_entries: withdraw own" on public.tournament_entries;

-- VERIFY: ok = true, and detail lists what remains (organiser and admin only for writes).
select 'no player write policies remain' as check_name,
       not exists (select 1 from pg_policies
                    where schemaname = 'public' and tablename = 'tournament_entries'
                      and policyname in ('register self', 'tournament_entries: insert own',
                                         'withdraw self', 't_entries: withdraw own')) as ok,
       (select string_agg(policyname || ' (' || cmd || ')', ', ')
          from pg_policies where schemaname = 'public'
           and tablename = 'tournament_entries') as detail;
