-- ============================================================================
-- WEEKLY REPORT RECIPIENTS  (2026-08-07)
--
-- Until now the weekly report went to exactly one hardcoded address — the
-- `REPORT_TO` secret, changeable only from the Supabase CLI. That is the wrong
-- place for a list that changes whenever the team does, and the person who
-- manages the team is not the person with a terminal.
--
-- So the mailing list becomes data:
--
--   report_recipients        one row per address. The single source of truth
--                            for who gets the Monday mail. Managed from the
--                            console, super admin only.
--
--   admin_report_recipients  what the console reads: the current list, PLUS
--                            the staff who could be added but aren't yet, so
--                            adding a teammate is a tap and not a typed email.
--
--   report_recipients_active what the `weekly-report-send` Edge Function reads
--                            with the service-role key. Granted to service_role
--                            ONLY. If it comes back empty the function falls
--                            back to REPORT_TO, so an unrun migration degrades
--                            to today's behaviour instead of mailing nobody.
--
-- WHO CAN BE ADDED. The picker offers only staff who can already see the money
-- (`_can_see_finance_of`) — super admins, and analysts holding Reports. Anyone
-- else (an accountant with no app account, say) can still be added, but their
-- address has to be typed. That keeps "add a colleague" one tap without making
-- it easy to mail the P&L to a Support moderator by mistake.
--
-- Note this is a mailing list, not a permission: the report link opens without
-- a login, so being on this list IS access to that week's numbers. Adding
-- someone is therefore super-admin-only, the same rule as minting the link.
--
-- Requires 2026-08-06_weekly_report_links.sql.
-- Safe to re-run.
-- ============================================================================

-- ── Per-user versions of the two access guards ─────────────────
-- `_access_ids()` only ever answered for the CALLER, which is all any RLS
-- policy needed. Listing candidate recipients means asking about someone else,
-- so the body moves into a function that takes a user and the original becomes
-- a one-line wrapper. Same logic, same results — every existing policy that
-- calls `_access_ids()` is unaffected.
create or replace function public._access_ids_of(p_user uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare
  v_is_admin boolean; v_role text; v_access jsonb;
begin
  select coalesce(is_admin, false), admin_role, admin_access
    into v_is_admin, v_role, v_access
    from public.profiles where id = p_user;
  if not found then return '{}'::text[]; end if;
  if v_is_admin then return public._role_default('super_admin'); end if;
  if v_role is null then return '{}'::text[]; end if;
  if jsonb_typeof(v_access) = 'array' and jsonb_array_length(v_access) > 0 then
    return (select array(select jsonb_array_elements_text(v_access)));
  end if;
  return public._role_default(v_role);
end $$;
grant execute on function public._access_ids_of(uuid) to authenticated;

create or replace function public._access_ids()
returns text[] language sql stable security definer set search_path = public as $$
  select public._access_ids_of(auth.uid());
$$;
grant execute on function public._access_ids() to authenticated;

-- Mirrors _can_see_finance(), for an arbitrary user.
create or replace function public._can_see_finance_of(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select p.is_admin
        or (p.admin_role = 'analyst' and 'reports' = any (public._access_ids_of(p.id)))
      from public.profiles p
     where p.id = p_user), false);
$$;
grant execute on function public._can_see_finance_of(uuid) to authenticated;

-- ── The list ───────────────────────────────────────────────────
create table if not exists public.report_recipients (
  email      text primary key,
  name       text,
  -- Set when the address belongs to a staff account, so the console can show
  -- who they are and stop offering them in the picker. Null for outsiders.
  profile_id uuid references public.profiles(id) on delete set null,
  -- Off keeps the row (and the name) while stopping the mail — for someone on
  -- leave, without losing them from the list.
  active     boolean not null default true,
  added_by   uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- Drift guards, in case an earlier draft created the table.
alter table public.report_recipients add column if not exists name       text;
alter table public.report_recipients add column if not exists profile_id uuid references public.profiles(id) on delete set null;
alter table public.report_recipients add column if not exists active     boolean not null default true;
alter table public.report_recipients add column if not exists added_by   uuid references public.profiles(id);
alter table public.report_recipients add column if not exists created_at timestamptz not null default now();

comment on table public.report_recipients is
  'Who the weekly P&L is emailed to. Being on this list is access to the '
  'numbers — the report link opens without a login.';

alter table public.report_recipients enable row level security;

-- Only people who may see the money may see who else gets it. All writes go
-- through the super-admin RPCs below, never straight from a client.
drop policy if exists "report_recipients: finance read" on public.report_recipients;
create policy "report_recipients: finance read" on public.report_recipients
  for select using (public._can_see_finance());

grant select on public.report_recipients to authenticated;

-- ── Seed, once ─────────────────────────────────────────────────
-- Start the list as every super admin, so the feature works the moment it is
-- switched on. Guarded on the table being empty: someone deliberately removed
-- must not come back on the next re-run.
insert into public.report_recipients (email, name, profile_id)
select distinct on (lower(u.email))
       lower(u.email), p.name, p.id
  from public.profiles p
  join auth.users u on u.id = p.id
 where p.is_admin
   and u.email is not null
   and u.email <> ''
   and not exists (select 1 from public.report_recipients)
 order by lower(u.email)
on conflict (email) do nothing;

-- ── Read: the list + who could join it ─────────────────────────
create or replace function public.admin_report_recipients()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;

  return json_build_object(
    'recipients', coalesce((
      select json_agg(row_to_json(x) order by x.active desc, x.email)
        from (
          select r.email, r.name, r.profile_id, r.active, r.created_at,
                 p.avatar_url,
                 -- Shown as the reason they're on the list; null for outsiders.
                 case when p.is_admin then 'super_admin' else p.admin_role end
                   as admin_role
            from public.report_recipients r
            left join public.profiles p on p.id = r.profile_id
        ) x), '[]'::json),
    -- Staff who can already see the money but aren't on the list. The console
    -- offers these as one-tap adds; anyone else has to be typed.
    'candidates', coalesce((
      select json_agg(row_to_json(y) order by y.name)
        from (
          select p.id, p.name, p.avatar_url, lower(u.email) as email,
                 case when p.is_admin then 'super_admin' else p.admin_role end
                   as admin_role
            from public.profiles p
            join auth.users u on u.id = p.id
           where u.email is not null
             and u.email <> ''
             and public._can_see_finance_of(p.id)
             and not exists (select 1 from public.report_recipients r
                              where r.email = lower(u.email))
        ) y), '[]'::json));
end $$;
grant execute on function public.admin_report_recipients() to authenticated;

-- ── Write: super admin only ────────────────────────────────────
-- Same rule as minting a link. An analyst may read the P&L and read this list,
-- but may not decide who else receives it.
create or replace function public.admin_add_report_recipient(
  p_email      text,
  p_name       text default null,
  p_profile_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;

  v_email := lower(trim(coalesce(p_email, '')));
  if v_email = '' then return 'Enter an email address.'; end if;
  -- Deliberately loose: enough to catch a typo, not a full RFC parser.
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return 'That doesn''t look like an email address.';
  end if;

  -- Aliased so the DO UPDATE can name the existing row unambiguously.
  insert into public.report_recipients as r (email, name, profile_id, added_by)
    values (v_email, nullif(trim(coalesce(p_name, '')), ''), p_profile_id, auth.uid())
  -- Already there: turn them back on rather than complaining.
  on conflict (email) do update
    set active     = true,
        name       = coalesce(excluded.name, r.name),
        profile_id = coalesce(excluded.profile_id, r.profile_id);

  return null;
end $$;
grant execute on function public.admin_add_report_recipient(text, text, uuid) to authenticated;

create or replace function public.admin_set_report_recipient(
  p_email  text,
  p_active boolean)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;
  update public.report_recipients
     set active = p_active
   where email = lower(trim(coalesce(p_email, '')));
  return null;
end $$;
grant execute on function public.admin_set_report_recipient(text, boolean) to authenticated;

create or replace function public.admin_remove_report_recipient(p_email text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;
  delete from public.report_recipients
   where email = lower(trim(coalesce(p_email, '')));
  return null;
end $$;
grant execute on function public.admin_remove_report_recipient(text) to authenticated;

-- ── What the Edge Function sends to ────────────────────────────
-- service_role only: the sender runs unattended from pg_cron, where there is no
-- auth.uid() to check. Returns [] rather than erroring when nobody is listed,
-- which the function reads as "fall back to REPORT_TO".
create or replace function public.report_recipients_active()
returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('email', email, 'name', name)
                           order by email), '[]'::json)
    from public.report_recipients
   where active;
$$;
revoke all on function public.report_recipients_active() from public, anon, authenticated;
grant execute on function public.report_recipients_active() to service_role;

notify pgrst, 'reload schema';

-- Sanity check after running:
--   select * from public.report_recipients;
--   select public.admin_report_recipients();
