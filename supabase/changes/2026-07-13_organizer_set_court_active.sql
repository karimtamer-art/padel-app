-- ============================================================================
-- Organizer can activate/deactivate their own court (2026-07-13). Run once.
-- Idempotent. Organizers are is_admin=false so they write via this SECURITY
-- DEFINER helper (owner-scoped), like the maintenance/save helpers.
-- ============================================================================

create or replace function public.organizer_set_court_active(p_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  update public.courts set is_active = coalesce(p_on, true)
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_set_court_active(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
