-- ============================================================================
-- Community — join by handle / code (2026-07-11).
-- Run once in the Supabase SQL editor (after the Phase-3 community delta).
-- Idempotent & re-runnable.
--
-- Lets a new/returning player join the SPECIFIC community they belong to by
-- typing its handle (the organizer shares it as a code, e.g. "cairopadel" or
-- "@cairopadel"). Resolves case-insensitively, strips a leading "@", joins the
-- caller, and returns the community id so the client can open its hub. Without
-- this, Home only surfaces the single newest community, so members of any other
-- community could not find theirs.
-- ============================================================================

create or replace function public.join_community_by_handle(p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_h text; v_cid uuid;
begin
  v_h := lower(btrim(regexp_replace(coalesce(p_handle, ''), '^@', '')));
  if v_h = '' then
    return jsonb_build_object('ok', false, 'error', 'Enter a community code.');
  end if;
  select id into v_cid
    from public.communities
   where handle is not null and lower(handle) = v_h
   limit 1;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error', 'No community found for that code.');
  end if;
  insert into public.community_members (community_id, player_id)
  values (v_cid, auth.uid())
  on conflict do nothing;
  return jsonb_build_object('ok', true, 'community_id', v_cid);
end $$;
grant execute on function public.join_community_by_handle(text) to authenticated;

notify pgrst, 'reload schema';
