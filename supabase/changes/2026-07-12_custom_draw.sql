-- ============================================================================
-- Custom draw building (2026-07-12). Run once in the Supabase SQL editor.
-- Idempotent & re-runnable.
--
-- For a 'custom' format tournament the organizer builds the draw by hand:
-- add matches between registered pairs under any label (Group A, Semifinal,
-- Final…), set winners WITHOUT auto-advancing, and delete matches. All gated by
-- owns_tournament. The label is stored in tournament_matches.bracket.
-- ============================================================================

create or replace function public.add_custom_match(
  p_tournament_id uuid, p_label text, p_entry1 uuid, p_entry2 uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_label text; v_slot int;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  v_label := coalesce(nullif(btrim(p_label), ''), 'Round 1');
  if p_entry1 is null and p_entry2 is null then return 'Pick at least one pair.'; end if;
  if p_entry1 is not null and p_entry1 = p_entry2 then return 'Pick two different pairs.'; end if;
  if p_entry1 is not null and not exists (
       select 1 from tournament_entries where id = p_entry1 and tournament_id = p_tournament_id)
     then return 'Pair not in this tournament.'; end if;
  if p_entry2 is not null and not exists (
       select 1 from tournament_entries where id = p_entry2 and tournament_id = p_tournament_id)
     then return 'Pair not in this tournament.'; end if;
  select coalesce(max(slot) + 1, 0) into v_slot
    from tournament_matches
   where tournament_id = p_tournament_id and bracket = v_label and round = 1;
  insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
  values (p_tournament_id, v_label, 1, v_slot, p_entry1, p_entry2);
  return null;
end $$;
grant execute on function public.add_custom_match(uuid, text, uuid, uuid) to authenticated;

-- Set (or clear, with null) a match winner without advancing to a next round —
-- used by the custom builder where the organizer controls progression by hand.
create or replace function public.set_match_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from tournament_matches where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if p_winner is not null and p_winner not in (m.entry1, m.entry2) then
    return 'Winner must be one of the two pairs.';
  end if;
  update tournament_matches set winner_entry = p_winner, score = p_score
   where id = p_match_id;
  return null;
end $$;
grant execute on function public.set_match_winner(uuid, uuid, text) to authenticated;

create or replace function public.delete_tournament_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from tournament_matches where id = p_match_id;
  if not found then return null; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  delete from tournament_matches where id = p_match_id;
  return null;
end $$;
grant execute on function public.delete_tournament_match(uuid) to authenticated;

notify pgrst, 'reload schema';
