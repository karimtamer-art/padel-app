-- ============================================================================
-- RBAC — role-based console access (Phase 1 of Roles/Organizer/Community).
-- Run this whole file once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- Model: the console was gated by a single `profiles.is_admin` boolean. This
-- adds a finer role on top WITHOUT weakening the existing security:
--   • admin_role  = super_admin | organizer | support | analyst  (null = not staff)
--   • admin_access = jsonb array of section ids; null → the role's default set
--   • admin_scope  = optional region/venue text (organizers)
--   • is_owner     = the locked super admin; can't be demoted or removed
--
-- SECURITY: only super admins keep `is_admin = true` (full DB access via every
-- existing `_is_admin()`-gated RLS policy). organizer/support/analyst get
-- `is_admin = false`, so payments/store/players-write etc. stay locked at the
-- database — the nav is filtered client-side, but the DB is the real guard.
-- Their section-specific write access is added per-section in later phases.
-- ============================================================================

-- ── Columns ─────────────────────────────────────────────────────────────────
alter table public.profiles add column if not exists admin_role   text;
alter table public.profiles add column if not exists admin_access jsonb;
alter table public.profiles add column if not exists admin_scope  text;
alter table public.profiles add column if not exists is_owner     boolean not null default false;

do $$ begin
  alter table public.profiles
    add constraint profiles_admin_role_chk
    check (admin_role is null or admin_role in ('super_admin','organizer','support','analyst'));
exception when duplicate_object then null; end $$;

create index if not exists idx_profiles_admin_role
  on public.profiles (admin_role) where admin_role is not null;

-- ── One-time backfill: existing admins become super_admins ──────────────────
-- Guarded by app_settings so a re-run never clobbers roles assigned later.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'rbac_backfilled') then
    update public.profiles
       set admin_role = 'super_admin'
     where coalesce(is_admin, false) = true
       and admin_role is null;
    -- Oldest admin becomes the locked owner (only if none is set yet).
    if not exists (select 1 from public.profiles where is_owner = true) then
      update public.profiles set is_owner = true
       where id = (select id from public.profiles
                    where coalesce(is_admin, false) = true
                    order by created_at nulls last, id
                    limit 1);
    end if;
    insert into public.app_settings (key, value)
    values ('rbac_backfilled', 'true')
    on conflict (key) do nothing;
  end if;
end $$;

-- ── Grant / update a staffer's role & access (super admin only) ──────────────
create or replace function public.admin_grant_role(
  p_user   uuid,
  p_role   text,
  p_access jsonb default null,
  p_scope  text  default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_old_access jsonb; v_old_scope text; v_owner boolean;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if p_role not in ('super_admin','organizer','support','analyst') then
    return 'Unknown role.';
  end if;

  select admin_role, admin_access, admin_scope, coalesce(is_owner, false)
    into v_old_role, v_old_access, v_old_scope, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner always has full access and can''t be changed.'; end if;

  update public.profiles set
    admin_role   = p_role,
    admin_access = p_access,                 -- null → client uses role default
    admin_scope  = nullif(btrim(coalesce(p_scope, '')), ''),
    -- only super admins keep full DB access; every other role is is_admin=false
    is_admin     = (p_role = 'super_admin')
  where id = p_user;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'grant_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role, 'access', v_old_access, 'scope', v_old_scope),
    jsonb_build_object('role', p_role,     'access', p_access,     'scope', p_scope),
    null);
  return null;
end $$;
grant execute on function public.admin_grant_role(uuid, text, jsonb, text) to authenticated;

-- ── Revoke all console access (super admin only) ────────────────────────────
create or replace function public.admin_revoke_role(p_user uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_owner boolean;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  select admin_role, coalesce(is_owner, false) into v_old_role, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner can''t be removed.'; end if;

  update public.profiles set
    admin_role = null, admin_access = null, admin_scope = null, is_admin = false
  where id = p_user;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'revoke_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role), jsonb_build_object('role', null), null);
  return null;
end $$;
grant execute on function public.admin_revoke_role(uuid) to authenticated;

-- ── List all staff for the Team & Roles screen (super admin only) ───────────
-- Email lives in auth.users, so this join needs SECURITY DEFINER.
create or replace function public.admin_list_staff()
returns table (
  id uuid, name text, email text, username text,
  admin_role text, admin_access jsonb, admin_scope text,
  is_owner boolean, avatar_url text, level numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return; end if;
  return query
    select p.id, p.name, u.email::text, p.username,
           p.admin_role, p.admin_access, p.admin_scope,
           coalesce(p.is_owner, false), p.avatar_url, p.level::numeric
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is not null
     order by coalesce(p.is_owner, false) desc, p.name nulls last;
end $$;
grant execute on function public.admin_list_staff() to authenticated;

-- ── Search non-staff users to invite (super admin only) ─────────────────────
create or replace function public.admin_search_users(p_term text)
returns table (id uuid, name text, email text, level numeric, avatar_url text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return; end if;
  if length(btrim(coalesce(p_term, ''))) < 2 then return; end if;
  return query
    select p.id, p.name, u.email::text, p.level::numeric, p.avatar_url
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is null
       and (p.name ilike '%' || p_term || '%' or u.email ilike '%' || p_term || '%')
     order by p.name nulls last
     limit 8;
end $$;
grant execute on function public.admin_search_users(text) to authenticated;

notify pgrst, 'reload schema';
