-- ============================================================================
-- Format Builder + live draw generator (2026-07-12).
-- Run once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- Organizers design a multi-stage format (stages + config) in the console. The
-- spec is stored on the tournament (tournaments.format_spec) and, optionally, in
-- a reusable library (saved_formats). generate_from_format() turns the FIRST
-- stage of a saved spec into real tournament_matches (groups round-robin,
-- knockout seeding, or a full round robin). Later stages are drawn once the
-- prior stage's results are in (organizer records winners as today).
-- ============================================================================

alter table public.tournaments add column if not exists format_spec jsonb;

create table if not exists public.saved_formats (
  id           uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references public.profiles(id) on delete cascade,
  name         text not null,
  spec         jsonb not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_saved_formats_owner on public.saved_formats(organizer_id);
alter table public.saved_formats enable row level security;
do $$ begin
  create policy "saved_formats: owner all" on public.saved_formats for all
    using (organizer_id = auth.uid() or public._is_admin())
    with check (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

-- Save the built spec onto the tournament (marks it a custom format).
create or replace function public.save_tournament_format(p_tournament_id uuid, p_spec jsonb)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  update public.tournaments
     set format = 'custom', format_spec = p_spec
   where id = p_tournament_id;
  return null;
end $$;
grant execute on function public.save_tournament_format(uuid, jsonb) to authenticated;

-- Build the first stage of the saved format into real matches.
create or replace function public.generate_from_format(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_spec jsonb; v_stage jsonb; v_kind text;
  v_entries uuid[]; v_n int; v_g int;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select format_spec into v_spec from public.tournaments where id = p_tournament_id;
  if v_spec is null or jsonb_array_length(coalesce(v_spec->'stages', '[]'::jsonb)) = 0 then
    return 'No saved format to generate from.';
  end if;
  v_stage := v_spec->'stages'->0;
  v_kind := v_stage->>'kind';

  select array_agg(id order by lvl desc) into v_entries from (
    select te.id, (coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0)) / 2.0 as lvl
      from public.tournament_entries te
      join public.profiles p1 on p1.id = te.player_id
      left join public.profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id and te.status = 'registered'
  ) s;
  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 registered pairs.'; end if;

  delete from public.tournament_matches where tournament_id = p_tournament_id;

  if v_kind = 'groups' then
    v_g := coalesce((v_stage->'cfg'->>'groups')::int, 4);
    declare gi int; a int; b int; v_label text; v_slot int; grp uuid[];
    begin
      for gi in 0 .. v_g - 1 loop
        grp := array(select v_entries[i] from generate_series(1, v_n) i where ((i - 1) % v_g) = gi);
        v_label := 'Group ' || chr(65 + gi);
        v_slot := 0;
        for a in 1 .. coalesce(array_length(grp, 1), 0) loop
          for b in a + 1 .. coalesce(array_length(grp, 1), 0) loop
            insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
            values (p_tournament_id, v_label, 1, v_slot, grp[a], grp[b]);
            v_slot := v_slot + 1;
          end loop;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind = 'roundRobin' then
    declare a int; b int; v_slot int := 0;
    begin
      for a in 1 .. v_n loop
        for b in a + 1 .. v_n loop
          insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
          values (p_tournament_id, 'Round robin', 1, v_slot, v_entries[a], v_entries[b]);
          v_slot := v_slot + 1;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind in ('knockout', 'doubleElim', 'consolation') then
    declare v_size int := 2; v_slots int; i int; e1 uuid; e2 uuid;
    begin
      while v_size < v_n loop v_size := v_size * 2; end loop;
      v_slots := v_size / 2;
      for i in 0 .. v_slots - 1 loop
        e1 := v_entries[i + 1];
        e2 := case when (v_size - i) <= v_n then v_entries[v_size - i] else null end;
        insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, winner_entry)
        values (p_tournament_id, 'wb', 1, i, e1, e2, case when e2 is null then e1 else null end);
      end loop;
      for i in 0 .. v_slots - 1 loop
        select entry1, winner_entry into e1, e2 from public.tournament_matches
          where tournament_id = p_tournament_id and bracket = 'wb' and round = 1 and slot = i;
        if e2 is not null then perform public._advance_winner(p_tournament_id, 'wb', 1, i, e2); end if;
      end loop;
    end;
    return null;

  else
    return 'The first stage (' || coalesce(v_kind, '?') || ') is drawn manually for now.';
  end if;
end $$;
grant execute on function public.generate_from_format(uuid) to authenticated;

notify pgrst, 'reload schema';
