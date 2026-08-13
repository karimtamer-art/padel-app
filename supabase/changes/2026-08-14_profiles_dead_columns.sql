-- ===========================================================================
-- profiles: drop three dead columns (2026-08-14)
--
-- All three come from migrations/0003_admin_and_core_tables.sql or the early
-- ranking work, and none has a consumer today:
--
--   store_credit   numeric — referenced NOWHERE in the entire repo. Store
--                  credit was explicitly ruled out of launch scope
--                  (2026-06-19, COD + InstaPay only), and never built.
--   division_pts   int     — written as 0 at signup and SELECTed into two
--                  payloads, but no code ever reads it. A v1 "division points"
--                  idea superseded by rating/tier.
--   verified       boolean — fetched in AdminService's players select string
--                  and never rendered or branched on. NOTE: this is
--                  profiles.verified. communities.verified is a DIFFERENT
--                  column, is live, and is untouched.
--
-- The 2026-06-16 schema cleanup audited store_credit's neighbours and kept the
-- "wired-but-empty" ones on the theory they would fill in once used. Two
-- months on they have not, and matches.max_elo was kept by that same reasoning
-- and had to be dropped anyway on 2026-08-14. Empty-and-unreferenced after a
-- couple of months is just dead.
--
-- NOT touched, because they look dead to a repo grep and are not:
--   notify_push / notify_match / notify_tournament / notify_order — read by
--   the push-notify EDGE FUNCTION (TypeScript), which no SQL or Dart grep
--   sees. Check supabase/functions/ before calling any column unused.
--
-- Idempotent. Aborts rather than destroying data — see section 1.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Refuse to drop anything that actually holds data.
--
--    Each column has a default (0 / 0 / false). A row holding something else
--    means somebody used it, and dropping would destroy that silently. This
--    follows the 2026-06-16 precedent of auditing read-only first, except it
--    is enforced here instead of being done by hand.
-- ---------------------------------------------------------------------------
do $$
declare
  v_credit  bigint := 0;
  v_pts     bigint := 0;
  v_ver     bigint := 0;
  v_msg     text;
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='store_credit') then
    execute 'select count(*) from public.profiles where coalesce(store_credit,0) <> 0'
      into v_credit;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='division_pts') then
    execute 'select count(*) from public.profiles where coalesce(division_pts,0) <> 0'
      into v_pts;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='verified') then
    execute 'select count(*) from public.profiles where coalesce(verified,false)'
      into v_ver;
  end if;

  if v_credit > 0 or v_pts > 0 or v_ver > 0 then
    v_msg := format('store_credit=%s division_pts=%s verified=%s',
                    v_credit, v_pts, v_ver);
    raise exception 'refusing to drop columns that hold data: %', v_msg
      using hint = 'Inspect those rows first. If the data really is '
                   'disposable, delete this guard block and re-run.';
  end if;

  raise notice 'profiles dead-column audit: all three are empty, proceeding.';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Anything depending on them?
--
--    Learned the hard way on 2026-08-14: v_user_ranking, a view from
--    migrations/0001 that no repo grep could find, blocked a column drop with
--    a dependency error. Ask the catalog rather than assuming.
-- ---------------------------------------------------------------------------
do $$
declare v_dep text;
begin
  select string_agg(distinct dependent.relname, ', ') into v_dep
    from pg_depend d
    join pg_rewrite r       on r.oid = d.objid
    join pg_class dependent on dependent.oid = r.ev_class
    join pg_class src       on src.oid = d.refobjid
    join pg_attribute a     on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
   where src.relname = 'profiles'
     and a.attname in ('store_credit','division_pts','verified')
     and dependent.relkind = 'v';
  if v_dep is not null then
    raise exception 'view(s) depend on these columns: %', v_dep
      using hint = 'Inspect with select pg_get_viewdef(''<name>'', true), then '
                   'drop or port them before re-running.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Drop.
-- ---------------------------------------------------------------------------
alter table public.profiles drop column if exists store_credit;
alter table public.profiles drop column if exists division_pts;
alter table public.profiles drop column if exists verified;

-- ---------------------------------------------------------------------------
-- 4. Confirm.
-- ---------------------------------------------------------------------------
do $$
declare v_left text;
begin
  select string_agg(column_name, ', ') into v_left
    from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name in ('store_credit','division_pts','verified');
  if v_left is not null then
    raise exception 'still present on profiles: %', v_left;
  end if;
  raise notice 'profiles is down to % columns.',
    (select count(*) from information_schema.columns
      where table_schema='public' and table_name='profiles');
end $$;

notify pgrst, 'reload schema';
