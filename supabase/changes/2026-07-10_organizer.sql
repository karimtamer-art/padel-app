-- ============================================================================
-- Organizer role — Phase 2 of Roles/Organizer/Community.
-- Run once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- Organizers (profiles.admin_role = 'organizer') run THEIR OWN tournaments:
--   • tournaments gain `organizer_id`; a trigger stamps it to the creator when
--     an organizer inserts one, so the existing create flow needs no change.
--   • RLS lets an organizer write only their own tournaments + verify/refund
--     entries on them. Super admins keep full access (owns_tournament() ⊇ admin).
--   • bracket RPCs (generate_draw, record_bracket_winner) open to the owner.
--   • organizer_overview() / organizer_broadcast() power the console home.
-- ============================================================================

alter table public.tournaments
  add column if not exists organizer_id uuid references public.profiles(id) on delete set null;
create index if not exists idx_tournaments_organizer
  on public.tournaments (organizer_id) where organizer_id is not null;

-- ── Helpers ─────────────────────────────────────────────────────────────────
create or replace function public.current_admin_role()
returns text language sql stable security definer set search_path = public as $$
  select admin_role from public.profiles where id = auth.uid();
$$;
grant execute on function public.current_admin_role() to authenticated;

-- True if the caller may manage this tournament: a super admin, or the
-- organizer who owns it.
create or replace function public.owns_tournament(p_tid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public._is_admin() or exists (
    select 1 from public.tournaments t
     where t.id = p_tid
       and t.organizer_id = auth.uid()
       and public.current_admin_role() = 'organizer'
  );
$$;
grant execute on function public.owns_tournament(uuid) to authenticated;

-- ── Auto-stamp organizer_id on insert by an organizer ───────────────────────
create or replace function public.set_tournament_organizer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.organizer_id is null and public.current_admin_role() = 'organizer' then
    new.organizer_id := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists trg_tournaments_set_organizer on public.tournaments;
create trigger trg_tournaments_set_organizer
  before insert on public.tournaments
  for each row execute function public.set_tournament_organizer();

-- ── RLS: organizers write their own tournaments / entries ───────────────────
do $$ begin
  create policy "tournaments: organizer write own" on public.tournaments for all
    using (organizer_id = auth.uid() and public.current_admin_role() = 'organizer')
    with check (organizer_id = auth.uid() and public.current_admin_role() = 'organizer');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "entries: organizer write own" on public.tournament_entries for update
    using (public.owns_tournament(tournament_id))
    with check (public.owns_tournament(tournament_id));
exception when duplicate_object then null; end $$;

-- ── Open the bracket RPCs to the owning organizer ───────────────────────────
-- generate_draw: gate on owns_tournament instead of admin-only.
create or replace function public.generate_draw(p_tournament_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_entries uuid[];
  v_n int;
  v_size int := 2;
  v_slots int;
  i int;
  e1 uuid; e2 uuid;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;

  select array_agg(id order by lvl desc) into v_entries from (
    select te.id,
           ( coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0) ) / 2.0 as lvl
      from tournament_entries te
      join profiles p1 on p1.id = te.player_id
      left join profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status = 'registered'
  ) s;

  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 registered pairs.'; end if;

  while v_size < v_n loop v_size := v_size * 2; end loop;
  v_slots := v_size / 2;

  delete from tournament_matches where tournament_id = p_tournament_id;

  for i in 0 .. v_slots - 1 loop
    e1 := v_entries[i + 1];
    e2 := case when (v_size - i) <= v_n then v_entries[v_size - i] else null end;
    insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, winner_entry)
    values (p_tournament_id, 'wb', 1, i, e1, e2,
            case when e2 is null then e1 else null end);
  end loop;

  for i in 0 .. v_slots - 1 loop
    select entry1, winner_entry into e1, e2
      from tournament_matches
     where tournament_id = p_tournament_id and bracket='wb' and round=1 and slot=i;
    if e2 is not null then
      perform public._advance_winner(p_tournament_id, 'wb', 1, i, e2);
    end if;
  end loop;

  return null;
end $$;
grant execute on function public.generate_draw(uuid) to authenticated;

-- record_bracket_winner: resolve the tournament from the match, then gate on
-- owns_tournament (moved after the SELECT so we know the tournament).
create or replace function public.record_bracket_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_loser uuid;
  v_format text;
  v_lb_round int;
  v_lb_slot int;
  v_open record;
begin
  select * into m from tournament_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if m.winner_entry is not null then return 'Winner already recorded.'; end if;
  if p_winner not in (m.entry1, m.entry2) then return 'Winner must be one of the two pairs.'; end if;
  if m.entry1 is null or m.entry2 is null then return 'This match is still waiting for a pair.'; end if;

  v_loser := case when p_winner = m.entry1 then m.entry2 else m.entry1 end;

  update tournament_matches
     set winner_entry = p_winner, score = p_score
   where id = p_match_id;

  select format into v_format from tournaments where id = m.tournament_id;

  perform public._advance_winner(m.tournament_id, m.bracket, m.round, m.slot, p_winner);

  if v_format = 'double_elim' and m.bracket = 'wb' then
    select * into v_open
      from tournament_matches
     where tournament_id = m.tournament_id and bracket = 'lb'
       and winner_entry is null and (entry1 is null or entry2 is null)
     order by round, slot
     limit 1;
    if found then
      if v_open.entry1 is null then
        update tournament_matches set entry1 = v_loser where id = v_open.id;
      else
        update tournament_matches set entry2 = v_loser where id = v_open.id;
      end if;
    else
      select coalesce(max(round), 0) into v_lb_round
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb';
      select coalesce(max(slot) + 1, 0) into v_lb_slot
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb'
         and round = greatest(v_lb_round, 1);
      insert into tournament_matches (tournament_id, bracket, round, slot, entry1)
      values (m.tournament_id, 'lb', greatest(v_lb_round, 1), v_lb_slot, v_loser);
    end if;
  end if;

  return null;
end $$;
grant execute on function public.record_bracket_winner(uuid, uuid, text) to authenticated;

-- ── Organizer console home: scoped KPIs ─────────────────────────────────────
create or replace function public.organizer_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return json_build_object('error', 'not_organizer');
  end if;
  return json_build_object(
    'tournaments', (select count(*) from tournaments where organizer_id = v_uid),
    'accepting',   (select count(*) from tournaments
                     where organizer_id = v_uid and status in ('open','upcoming')),
    'entrants',    (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'reach',       (select count(distinct te.player_id) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'fees',        (select coalesce(sum(coalesce(paid_amount,0)),0) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'paid'),
    'to_verify',   (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'pending')
  );
end $$;
grant execute on function public.organizer_overview() to authenticated;

-- ── Organizer broadcast: message my participants (push + in-app) ────────────
-- Inserts one notifications row per distinct participant; the existing
-- push-notify webhook fans each out to devices. p_tournament_id null = all my
-- events. Returns an error string, or null on success.
create or replace function public.organizer_broadcast(
  p_title text, p_body text, p_tournament_id uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  if p_tournament_id is not null and not public.owns_tournament(p_tournament_id) then
    return 'Not your tournament.';
  end if;
  insert into public.notifications (user_id, type, title, body, data)
  select distinct te.player_id, 'broadcast', p_title, nullif(btrim(p_body), ''),
         jsonb_build_object('from', 'organizer')
    from public.tournament_entries te
   where te.status not in ('withdrawn','cancelled')
     and te.tournament_id in (
       select id from public.tournaments
        where organizer_id = v_uid
          and (p_tournament_id is null or id = p_tournament_id));
  return null;
end $$;
grant execute on function public.organizer_broadcast(text, text, uuid) to authenticated;

notify pgrst, 'reload schema';
