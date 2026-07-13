-- ============================================================================
-- Organizer can't see their own courts (2026-07-13). Run once. Idempotent.
--
-- courts RLS only lets non-admins SELECT active courts (is_active = true OR
-- is_admin()). An organizer is is_admin = false, so a direct select of their own
-- courts can come back empty (e.g. an inactive/community court). Return their own
-- courts via a SECURITY DEFINER RPC (mirrors organizer_save_court), and add an
-- owner-read policy so the direct path works too.
-- ============================================================================

create or replace function public.organizer_courts()
returns setof public.courts
language sql stable security definer set search_path = public as $$
  select * from public.courts
   where owner_id = auth.uid()
   order by created_at desc;
$$;
grant execute on function public.organizer_courts() to authenticated;

do $$ begin
  create policy "courts: owner read own" on public.courts
    for select using (owner_id = auth.uid());
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
