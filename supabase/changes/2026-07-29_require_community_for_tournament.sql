-- ============================================================================
-- 2026-07-29 — Require a community before an organizer can publish a tournament
--
-- Tournaments stay globally visible to players (good for discovery), but a
-- brand-new organizer must create their community first. Enforced server-side
-- in the BEFORE INSERT trigger that stamps organizer ownership. Super admins are
-- unaffected (their role isn't 'organizer'). Editing an existing tournament is
-- an UPDATE, so it isn't gated.
--
-- Safe to re-run.
-- ============================================================================

create or replace function public.set_tournament_organizer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.organizer_id is null and public.current_admin_role() = 'organizer' then
    if not exists (select 1 from public.communities where organizer_id = auth.uid()) then
      raise exception 'Create your community before publishing a tournament.'
        using errcode = 'check_violation';
    end if;
    new.organizer_id := auth.uid();
  end if;
  return new;
end $$;

-- (trigger trg_tournaments_set_organizer already exists and points at this fn)
