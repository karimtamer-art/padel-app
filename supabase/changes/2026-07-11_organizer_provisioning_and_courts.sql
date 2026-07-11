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
create index if not exists idx_courts_owner on public.courts(owner_id);

notify pgrst, 'reload schema';
