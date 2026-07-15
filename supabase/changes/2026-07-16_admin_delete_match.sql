-- 2026-07-16 · Admin: delete a match from the console
--
-- Lets an admin remove a faulty match (e.g. an orphaned/player-less one) from
-- the Matches screen. SECURITY DEFINER + _is_admin() gate. Clears the FKs that
-- would otherwise block the delete: ranking_history.match_id → null, then the
-- match_players rows, then the match. Idempotent; also folded into the canonical.

create or replace function public.admin_delete_match(p_match_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Admins only.'; end if;
  update public.ranking_history set match_id = null where match_id = p_match_id;
  delete from public.match_players where match_id = p_match_id;
  delete from public.matches where id = p_match_id;
  return null;
end $$;
grant execute on function public.admin_delete_match(uuid) to authenticated;

notify pgrst, 'reload schema';
