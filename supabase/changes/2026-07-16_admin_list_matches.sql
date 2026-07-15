-- 2026-07-16 · Admin: reliable match list (with player count)
--
-- The console read matches with a `match_players(...)` embed, which is fragile
-- (PostgREST relationship resolution + the locked-down matches RLS). This RPC
-- returns everything the Matches screen needs — creator name + player count —
-- SECURITY DEFINER + _is_admin() gated, so it always works for admins and
-- returns nothing (not an error) for anyone else. Idempotent; folded into canonical.

create or replace function public.admin_list_matches(p_limit int default 100)
returns table(
  id           uuid,
  status       text,
  match_type   text,
  scheduled_at timestamptz,
  created_by   uuid,
  creator_name text,
  players      int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then return; end if;
  return query
    select m.id, m.status, m.match_type, m.scheduled_at, m.created_by,
           (select p.name from public.profiles p where p.id = m.created_by),
           (select count(*)::int from public.match_players mp where mp.match_id = m.id)
      from public.matches m
     order by m.scheduled_at desc nulls last
     limit p_limit;
end $$;
grant execute on function public.admin_list_matches(int) to authenticated;

notify pgrst, 'reload schema';
