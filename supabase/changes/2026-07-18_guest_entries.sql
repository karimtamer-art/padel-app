-- 2026-07-18 · Guest tournament entries + organizer entry manager.
--
-- Organizers running a WhatsApp crowd need to enter pairs whose players aren't
-- on the app yet — names only, no profile. player_id becomes nullable; the
-- display layer already reads player_name/partner_name (no profile join) so
-- guests render as-is. Guests can't be rated (finalize skips non-profile pairs)
-- and can't self-report results (no account). Idempotent; also folded into
-- migration_player_app.sql.

alter table public.tournament_entries alter column player_id drop not null;

create or replace function public.organizer_add_entry(
  p_tournament_id uuid,
  p_player_id     uuid default null,
  p_player_name   text default null,
  p_partner_id    uuid default null,
  p_partner_name  text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_pname text; v_partname text;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  if p_player_id is not null then
    select name into v_pname from public.profiles where id = p_player_id;
    if not found then return 'Player not found.'; end if;
    if exists (select 1 from public.tournament_entries
                where tournament_id = p_tournament_id and player_id = p_player_id
                  and status <> 'withdrawn') then
      return 'That player is already entered.';
    end if;
  end if;
  v_pname := coalesce(v_pname, nullif(btrim(p_player_name), ''));
  if v_pname is null then return 'Enter a name for the first player.'; end if;
  if p_partner_id is not null then
    select name into v_partname from public.profiles where id = p_partner_id;
  end if;
  v_partname := coalesce(v_partname, nullif(btrim(p_partner_name), ''));
  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status)
  values (p_tournament_id, p_player_id, v_pname, p_partner_id, v_partname, 'registered');
  return null;
end $$;
grant execute on function public.organizer_add_entry(uuid, uuid, text, uuid, text) to authenticated;

create or replace function public.organizer_remove_entry(p_entry_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_tid uuid;
begin
  select tournament_id into v_tid from public.tournament_entries where id = p_entry_id;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_tid) then return 'Not authorised.'; end if;
  if exists (select 1 from public.tournament_matches
              where entry1 = p_entry_id or entry2 = p_entry_id or winner_entry = p_entry_id) then
    update public.tournament_entries set status = 'withdrawn' where id = p_entry_id;
  else
    delete from public.tournament_entries where id = p_entry_id;
  end if;
  return null;
end $$;
grant execute on function public.organizer_remove_entry(uuid) to authenticated;

notify pgrst, 'reload schema';
