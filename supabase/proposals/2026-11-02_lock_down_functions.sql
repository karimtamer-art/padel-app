-- PROPOSAL, NOT APPLIED. Lock down public functions. Don't run this until it has been
-- checked against the live privilege audit AND a schema dump: it can take the app down
-- if the lists below miss something, and the failure is a raw "permission denied".
--
-- Supabase grants every new function in public to anon and authenticated, so an
-- internal SECURITY DEFINER helper is callable by anyone with the public anon key.
-- This closes every public function, then re-opens three groups:
--   1. RPCs the app calls: authenticated. Listed from lib/, plus the ones only OLD
--      builds still call, or their buttons would lose 4b's friendly refusal.
--   2. RPCs that work signed out (login checks, the website): anon too.
--   3. Whatever Postgres runs AS THE CALLER, found from the catalog rather than a list:
--      functions used by RLS policies, column defaults, CHECKs and views, and what
--      those call if they aren't definer. Revoking these breaks every read of the
--      table, for both roles, so they stay open, and show in the check at the end.
-- Triggers need no grant: execute is only checked when the trigger is created. Cron
-- and service-role callers keep working (service_role is granted everything here).
--
-- ROLLBACK: the block at the bottom restores the exact previous grants.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.function_acl_backup_20261102 (
  sig text primary key, acl aclitem[], taken_at timestamptz not null default now());
insert into private.function_acl_backup_20261102 (sig, acl)
select p.oid::regprocedure::text, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
on conflict (sig) do nothing;

do $$
declare
  v_auth text[] := array[
    'add_announcement_comment', 'add_custom_match', 'admin_add_report_recipient',
    'admin_adjust_season_points', 'admin_cancel_match', 'admin_close_season',
    'admin_create_season', 'admin_dashboard_counts', 'admin_delete_banner',
    'admin_delete_season_bracket', 'admin_finance_summary', 'admin_grant_role',
    'admin_list_matches', 'admin_list_staff', 'admin_matches_console',
    'admin_players_console', 'admin_product_sales',
    'admin_release_assessment_slot', 'admin_remove_report_recipient',
    'admin_report_link', 'admin_report_recipients', 'admin_reports',
    'admin_resolve_match', 'admin_resolve_report', 'admin_revoke_report_link',
    'admin_revoke_role', 'admin_save_banner', 'admin_save_season_bracket',
    'admin_save_season_rule', 'admin_search_users', 'admin_season_console',
    'admin_season_find_players', 'admin_season_player', 'admin_set_match_info',
    'admin_set_rating', 'admin_set_report_recipient', 'admin_set_season_flag',
    'admin_set_status', 'admin_void_season_points', 'admin_web_registrations',
    'admin_web_to_draw', 'admin_weekly_finance', 'advance_stage',
    'announcement_comments', 'apply_promo', 'approve_join_request', 'block_user',
    'book_assessment_slot', 'cancel_assessment_booking', 'cancel_match',
    'clear_conversation', 'clear_must_change_password', 'community_channel_list',
    'community_channel_unreads', 'community_feed', 'community_inbox_typed',
    'community_member_card', 'community_unread_count', 'confirm_match_result',
    'confirm_tournament_result', 'create_community_channel',
    'create_match_request', 'delete_account_self', 'delete_community_channel',
    'delete_tournament_match', 'dm_inbox', 'email_exists', 'email_login_methods',
    'expire_stale_matches', 'finalize_tournament', 'generate_draw',
    'generate_from_format', 'get_home_products', 'get_or_create_conversation',
    'join_community', 'join_community_by_handle', 'leave_community', 'leave_match',
    'mark_channel_read', 'mark_placement_revealed', 'mark_ticket_read',
    'match_pending_invites', 'mm_ack_result', 'mm_result_hero', 'my_blocked_users',
    'my_contact_shares', 'my_number_requests', 'organizer_add_entry',
    'organizer_broadcast', 'organizer_community_stats', 'organizer_courts',
    'organizer_delete_court', 'organizer_overview', 'organizer_remove_entry',
    'organizer_save_court', 'organizer_set_court_active',
    'organizer_set_court_maintenance', 'pay_partner_share', 'player_phone',
    'post_announcement', 'record_bracket_winner', 'register_for_tournament',
    'reply_community_message', 'report_content', 'request_number',
    'resolve_match_request', 'respond_number_request', 'revoke_contact_share',
    'save_tournament_format', 'season_overview', 'send_community_message',
    'set_channel_post', 'set_channel_settings', 'set_community_approval',
    'set_match_winner', 'set_my_instapay', 'set_phone_public',
    'snapshot_season_ranks', 'submit_match_result', 'submit_tournament_result',
    'ticket_inbox', 'ticket_roster', 'ticket_unread_total',
    'toggle_announcement_like', 'toggle_rsvp', 'tournament_pay_info',
    'tournament_standings', 'unblock_user', 'upsert_my_community',
    'username_available', 'verify_entry_share', 'web_levels',
    'web_open_tournaments', 'web_register', 'web_upcoming_tournaments',
    'withdraw_from_tournament'
  ];
  v_old_builds text[] := array[
    'admin_delete_match', 'admin_set_player_rating', 'community_inbox',
    'create_match', 'join_match', 'join_match_by_code', 'mark_community_read',
    'mm_accept', 'mm_cancel_search', 'mm_candidates', 'mm_count_candidates',
    'mm_start_search', 'my_match_invites', 'respond_match_invite'
  ];
  v_anon text[] := array[
    'email_exists', 'email_login_methods', 'tournament_pay_info',
    'username_available', 'web_levels', 'web_open_tournaments', 'web_register',
    'web_upcoming_tournaments'
  ];
  v_caller text[];
  v_more text[];
  r record;
begin
  -- Close everything that isn't an extension's.
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not exists (select 1 from pg_depend d
                        where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on routine %s from public, anon, authenticated', r.sig);
    execute format('grant execute on routine %s to service_role', r.sig);
  end loop;

  -- Run as the caller: named in a policy, default, CHECK or view.
  select coalesce(array_agg(distinct p.proname::text), '{}') into v_caller
    from pg_depend d
    join pg_proc p on p.oid = d.refobjid and d.refclassid = 'pg_proc'::regclass
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where d.classid in ('pg_policy'::regclass, 'pg_attrdef'::regclass,
                       'pg_constraint'::regclass, 'pg_rewrite'::regclass);

  -- A function that isn't definer runs its body as the caller too, so what it calls
  -- needs the grant as well. Repeat until nothing new turns up.
  loop
    select coalesce(array_agg(distinct q.proname::text), '{}') into v_more
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
      join pg_proc q on q.pronamespace = n.oid
       and p.prosrc ~ ('\m' || q.proname || '\s*\(')
     where not p.prosecdef
       and p.proname::text = any (v_auth || v_old_builds || v_anon || v_caller)
       and not q.proname::text = any (v_auth || v_old_builds || v_anon || v_caller);
    exit when v_more = '{}';
    v_caller := v_caller || v_more;
  end loop;

  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname::text = any (v_auth || v_old_builds || v_anon || v_caller)
  loop
    execute format('grant execute on routine %s to authenticated', r.sig);
    if r.proname::text = any (v_anon || v_caller) then
      execute format('grant execute on routine %s to anon', r.sig);
    end if;
  end loop;

  drop table if exists private.lockdown_report_20261102;
  create table private.lockdown_report_20261102 as
  select v_auth || v_old_builds as named_for_app, v_anon as named_for_anon, v_caller as caller_rights;
end $$;

-- VERIFY: every `ok` must be true. Read the `detail` columns: the first is every name
-- in these lists that live doesn't have, and the second is what stays open because
-- Postgres runs it as the caller.
select * from (values
  ('helpers named _ are closed, apart from caller-rights ones',
   not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.prosecdef and p.proname like '\_%'
                  and has_function_privilege('anon', p.oid, 'execute')
                  and not p.proname::text = any ((select caller_rights from private.lockdown_report_20261102)::text[])),
   ''),
  ('names in the lists that live does not have', true,
   coalesce((select string_agg(x, ', ') from unnest((select named_for_app || named_for_anon from private.lockdown_report_20261102)::text[]) x
              where not exists (select 1 from pg_proc p where p.proname = x
                                   and p.pronamespace = 'public'::regnamespace)), '')),
  ('open because they run as the caller', true,
   (select array_to_string(caller_rights, ', ') from private.lockdown_report_20261102))
) as v(check_name, ok, detail);

-- ── ROLLBACK (run on its own to undo) ───────────────────────────────────────────
-- do $$
-- declare r record; g record;
-- begin
--   for r in select sig, acl from private.function_acl_backup_20261102 where to_regprocedure(sig) is not null loop
--     execute format('revoke all on routine %s from public, anon, authenticated, service_role', r.sig);
--     if r.acl is null then
--       -- never granted explicitly: the Postgres default, which is PUBLIC
--       execute format('grant execute on routine %s to public', r.sig);
--     else
--       for g in select grantee from aclexplode(r.acl) where privilege_type = 'EXECUTE' loop
--         execute format('grant execute on routine %s to %s', r.sig,
--           case when g.grantee = 0 then 'public' else (select quote_ident(rolname) from pg_roles where oid = g.grantee) end);
--       end loop;
--     end if;
--   end loop;
-- end $$;

-- ── OPTIONAL, separate step: new functions start locked ─────────────────────────
-- Both lines are needed. Default privileges for PUBLIC are global, so the first can't
-- be scoped to a schema; the second removes what Supabase adds for public.
-- alter default privileges for role postgres revoke execute on functions from public;
-- alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
