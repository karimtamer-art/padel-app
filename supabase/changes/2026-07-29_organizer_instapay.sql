-- ============================================================================
-- 2026-07-29 — Organizer InstaPay payout (username + link)
--
-- Problem: players paying a tournament entry fee always transferred to ONE
-- global platform handle (app_settings.instapay_handle). Organizers had no way
-- to collect entry fees to their own account.
--
-- Fix: per-organizer InstaPay username AND payment link on profiles + a resolver
-- used by the player pay sheet (organizer's details → platform default → hard
-- fallback) and a setter gated to organizers/admins for the console.
--
-- Safe to re-run. (Drops the earlier single-field variants of these functions
-- if a prior version of this delta was applied.)
-- ============================================================================

alter table public.profiles add column if not exists instapay_handle text;
alter table public.profiles add column if not exists instapay_link   text;

-- Organizer (or admin) sets their own payout username + link; applies to every
-- event they own. Returns null on success, or an error string.
drop function if exists public.set_my_instapay_handle(text);
create or replace function public.set_my_instapay(p_handle text, p_link text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  update public.profiles
     set instapay_handle = nullif(btrim(p_handle), ''),
         instapay_link   = nullif(btrim(p_link), '')
   where id = auth.uid();
  return null;
end $$;
grant execute on function public.set_my_instapay(text, text) to authenticated;

-- The InstaPay details a player transfers to for a given tournament: the owning
-- organizer's handle/link if set, else the platform-wide app_settings handle,
-- else a hard default. SECURITY DEFINER so it reads across profiles/app_settings.
drop function if exists public.tournament_pay_handle(uuid);
create or replace function public.tournament_pay_info(p_tournament_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'handle', coalesce(
      nullif(btrim(p.instapay_handle), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_handle')), ''),
      'padelpro@instapay'),
    'link', nullif(btrim(p.instapay_link), ''))
    from public.tournaments t
    left join public.profiles p on p.id = t.organizer_id
   where t.id = p_tournament_id;
$$;
grant execute on function public.tournament_pay_info(uuid) to authenticated, anon;

notify pgrst, 'reload schema';
