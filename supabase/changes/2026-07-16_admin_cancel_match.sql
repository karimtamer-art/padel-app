-- 2026-07-16 · Admin: soft-remove (cancel) a match instead of hard delete
--
-- Replaces admin_delete_match (which physically deleted the row + players).
-- admin_cancel_match just marks the match 'cancelled', so it drops out of every
-- player-facing query (they only surface active statuses) while KEEPING the
-- match, its players, and its ranking history in the DB — recoverable and still
-- listed in the admin console. Idempotent; also folded into migration_player_app.sql.

drop function if exists public.admin_delete_match(uuid);

create or replace function public.admin_cancel_match(p_match_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Admins only.'; end if;
  update public.matches set status = 'cancelled' where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  return null;
end $$;
grant execute on function public.admin_cancel_match(uuid) to authenticated;

notify pgrst, 'reload schema';
