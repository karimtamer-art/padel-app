-- ============================================================================
-- WEEKLY REPORT LINKS  (2026-08-06)
--
-- The Monday-to-Sunday P&L, as a link that can be emailed. Until now the
-- weekly report only existed inside the admin console, behind a Supabase
-- login — nothing you can put in an email.
--
-- How it fits together:
--
--   report_links        one row per week, holding a long random token.
--                       Permanent and reusable by design: the same week always
--                       resolves to the same link, so a forwarded mail keeps
--                       working and re-sending never mints a second URL.
--                       Revocable if a link ever needs killing.
--
--   admin_report_link   super admin only. Mints the token for a week, or hands
--                       back the one that already exists.
--
--   report_render       what the `weekly-report` Edge Function calls with the
--                       service-role key. Validates the token, counts the view
--                       and returns the FULL report as json. Granted to
--                       service_role ONLY — never to anon or authenticated, so
--                       the token is useless against PostgREST directly.
--
-- The rendered page is read-only on purpose: it is a statement of a week that
-- has already happened, so there is nothing on it to edit.
--
-- SECURITY NOTE: anyone holding a link can read that week's P&L without
-- logging in — that is what makes it work from Gmail. The token is 256 bits of
-- CSPRNG output, so it cannot be guessed; treat the link like the numbers
-- themselves.
--
-- Requires 2026-08-06_expenses_and_pl.sql + 2026-08-06_manual_income.sql.
-- Safe to re-run.
-- ============================================================================

create table if not exists public.report_links (
  token        text primary key,
  week_start   date not null,
  week_end     date not null,
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  view_count   int not null default 0,
  revoked      boolean not null default false
);

-- Drift guards, in case an earlier draft created the table.
alter table public.report_links add column if not exists week_start   date;
alter table public.report_links add column if not exists week_end     date;
alter table public.report_links add column if not exists created_by   uuid references public.profiles(id);
alter table public.report_links add column if not exists created_at   timestamptz not null default now();
alter table public.report_links add column if not exists last_seen_at timestamptz;
alter table public.report_links add column if not exists view_count   int not null default 0;
alter table public.report_links add column if not exists revoked      boolean not null default false;

-- One live link per week. A revoked link keeps its row (so the token stays
-- burned) but stops being the one a new request hands back — hence the partial
-- unique index rather than a plain unique constraint.
create unique index if not exists report_links_week_live_idx
  on public.report_links (week_start) where not revoked;

comment on table public.report_links is
  'Permanent share tokens for the weekly P&L. One live token per week; the '
  'holder can read that week without logging in.';

alter table public.report_links enable row level security;

-- Only people who may see the money may see the links to it. Writes go through
-- the RPCs below (super admin), never straight from a client.
drop policy if exists "report_links: finance read" on public.report_links;
create policy "report_links: finance read" on public.report_links
  for select using (public._can_see_finance());

grant select on public.report_links to authenticated;

-- ── Mint (or return) the link for a week ───────────────────────
-- The work itself, unguarded. Never granted to anyone — the two wrappers below
-- are the only ways in, and they carry the permission checks.
create or replace function public._report_link_ensure(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_start date;
begin
  -- Snap to the Monday of whatever week the caller names, so the same week can
  -- never end up with two links because of an off-by-a-day.
  v_start := date_trunc('week', p_week_start::timestamp)::date;

  select token into v_token
    from public.report_links
   where week_start = v_start and not revoked;

  if v_token is null then
    -- Two uuids = 256 bits of CSPRNG output, no pgcrypto dependency.
    v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.report_links (token, week_start, week_end, created_by)
      values (v_token, v_start, v_start + 6, auth.uid())
      -- Two admins tapping at once: keep the row that won, return its token.
      on conflict do nothing;
    select token into v_token
      from public.report_links
     where week_start = v_start and not revoked;
  end if;

  return json_build_object(
    'token',      v_token,
    'week_start', v_start,
    'week_end',   v_start + 6);
end $$;
revoke all on function public._report_link_ensure(date) from public, anon, authenticated;

-- What the console calls. Super admin only: handing out a login-free link to
-- the P&L is a bigger decision than reading it, so an Analyst who can see the
-- numbers still can't create a link to them.
create or replace function public.admin_report_link(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then
    return json_build_object('error', 'not_allowed');
  end if;
  return public._report_link_ensure(p_week_start);
end $$;
grant execute on function public.admin_report_link(date) to authenticated;

-- What the `weekly-report-send` Edge Function calls. It runs unattended from
-- pg_cron, so there is no auth.uid() to check — service_role IS the trust.
create or replace function public.report_link_ensure(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
begin
  return public._report_link_ensure(p_week_start);
end $$;
revoke all on function public.report_link_ensure(date) from public, anon, authenticated;
grant execute on function public.report_link_ensure(date) to service_role;

-- ── Kill a link ────────────────────────────────────────────────
create or replace function public.admin_revoke_report_link(p_token text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  update public.report_links set revoked = true where token = p_token;
  return null;
end $$;
grant execute on function public.admin_revoke_report_link(text) to authenticated;

-- ── What the Edge Function renders ─────────────────────────────
-- Everything the page shows, in one call. No guard of its own beyond the token
-- because it is reachable only by service_role — the Edge Function holds that
-- key, the public internet does not.
create or replace function public.report_render(p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_row public.report_links%rowtype;
  v_this date := date_trunc('week', (now() at time zone 'Africa/Cairo'))::date;
begin
  select * into v_row from public.report_links
   where token = p_token and not revoked;
  if not found then
    return json_build_object('error', 'not_found');
  end if;

  update public.report_links
     set view_count = view_count + 1, last_seen_at = now()
   where token = p_token;

  return json_build_object(
    'week_start', v_row.week_start,
    'week_end',   v_row.week_end,
    -- A link to the running week renders "so far" rather than pretending the
    -- week is closed.
    'is_current', v_row.week_start = v_this,
    'report',     public._finance_core(v_row.week_start, v_row.week_start + 7));
end $$;
revoke all on function public.report_render(text) from public, anon, authenticated;
grant execute on function public.report_render(text) to service_role;

notify pgrst, 'reload schema';

-- ============================================================================
-- WEEKLY AUTO-SEND  (optional — fill in and run separately)
--
-- The console's "Email report" button works without any of this. Uncomment
-- the block below to have last week's report mail itself every Monday.
--
-- Needs, in the Supabase dashboard:
--   1. Database → Extensions → enable `pg_cron` AND `pg_net`.
--   2. The Edge Functions deployed (see supabase/functions/weekly-report*).
--   3. Secrets set:
--        supabase secrets set RESEND_API_KEY=re_...
--        supabase secrets set REPORT_FROM='Padel Rivals <reports@YOURDOMAIN>'
--        supabase secrets set REPORT_TO=padelrivals@gmail.com
--        supabase secrets set CRON_SECRET=<any long random string>
--
-- Replace <PROJECT_REF> and <CRON_SECRET> below with your own before running.
-- The CRON_SECRET here must match the secret you set above — it is what stops
-- anyone else from triggering the send.
--
-- Runs 06:00 Cairo on Mondays (04:00 UTC), reporting the week that just ended.
-- ============================================================================
-- do $$
-- begin
--   perform cron.schedule(
--     'padel-weekly-report',
--     '0 4 * * 1',
--     $cron$
--       select net.http_post(
--         url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/weekly-report-send',
--         headers := jsonb_build_object(
--                      'Content-Type', 'application/json',
--                      'x-cron-secret', '<CRON_SECRET>'),
--         body    := '{}'::jsonb);
--     $cron$);
-- exception when others then
--   raise notice 'pg_cron/pg_net not available — enable both extensions, then re-run this block.';
-- end $$;
