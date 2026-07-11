-- ============================================================================
-- Organizer provisioning + court ownership (2026-07-11).
-- Run once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- 1) Admin provisions an organizer with a username + temp password (via the
--    `create-organizer` Edge Function, service-role). The new account is flagged
--    must_change_password so they are forced to set a real password on first
--    login. `clear_must_change_password()` clears the flag once they do.
-- 2) Courts get an owner + a public flag. An organizer adds his OWN courts
--    (owner_id = him, is_public = false → only his community sees them). The
--    super admin can flip is_public = true to publish a court to ALL players.
--    Existing courts default is_public = true, so nothing changes for them.
-- ============================================================================

-- ── 1) Forced first-login password change ───────────────────────────────────
alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create or replace function public.clear_must_change_password()
returns void language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid();
$$;
grant execute on function public.clear_must_change_password() to authenticated;

-- ── 2) Court ownership + visibility ─────────────────────────────────────────
alter table public.courts
  add column if not exists owner_id uuid references public.profiles(id) on delete set null;
alter table public.courts
  add column if not exists is_public boolean not null default true;
alter table public.courts add column if not exists city text;
alter table public.courts add column if not exists surface text;
create index if not exists idx_courts_owner on public.courts(owner_id);

-- Organizers are is_admin = false, so they can't write to courts directly under
-- RLS. These SECURITY DEFINER helpers let an organizer manage ONLY their own
-- courts (community-only), and admins manage any. Gated by role.
drop function if exists public.organizer_save_court(uuid, text, text, text, numeric, boolean);
create or replace function public.organizer_save_court(
  p_id uuid, p_venue text, p_name text, p_area text, p_city text,
  p_surface text, p_price numeric, p_indoor boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  if p_id is null then
    insert into public.courts (venue_name, name, area, city, surface,
                               price_per_hour, indoor,
                               is_active, in_maintenance, owner_id, is_public)
    values (p_venue, coalesce(nullif(btrim(p_name), ''), 'Court'), p_area,
            nullif(btrim(coalesce(p_city, '')), ''),
            nullif(btrim(coalesce(p_surface, '')), ''),
            p_price, coalesce(p_indoor, false), true, false, v_uid, false)
    returning id into v_id;
    return v_id;
  else
    update public.courts set
      venue_name = p_venue,
      name = coalesce(nullif(btrim(p_name), ''), 'Court'),
      area = p_area,
      city = nullif(btrim(coalesce(p_city, '')), ''),
      surface = nullif(btrim(coalesce(p_surface, '')), ''),
      price_per_hour = p_price, indoor = coalesce(p_indoor, false)
    where id = p_id and (owner_id = v_uid or public._is_admin());
    return p_id;
  end if;
end $$;
grant execute on function public.organizer_save_court(uuid, text, text, text, text, text, numeric, boolean) to authenticated;

create or replace function public.organizer_delete_court(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  delete from public.courts
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_delete_court(uuid) to authenticated;

create or replace function public.organizer_set_court_maintenance(p_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  update public.courts set in_maintenance = coalesce(p_on, false)
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_set_court_maintenance(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
