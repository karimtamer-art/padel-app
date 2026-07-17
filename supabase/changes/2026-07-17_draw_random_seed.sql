-- 2026-07-17 · Random seeding option for the draw generator.
--
-- generate_from_format gains p_random: true shuffles the field, false (default)
-- seeds by pair level as before. The DrawSheet's "Random draw" seeding choice
-- passes it. Signature changed → drop the old 1-arg version first. Idempotent;
-- also folded into migration_player_app.sql.

drop function if exists public.generate_from_format(uuid);
create or replace function public.generate_from_format(
  p_tournament_id uuid, p_random boolean default false)
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

  select array_agg(id order by (case when p_random then random() else lvl end) desc)
    into v_entries from (
    select te.id,
           ((coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0)) / 2.0)::float8 as lvl
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
            insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
            values (p_tournament_id, v_label, 1, v_slot, grp[a], grp[b], 0);
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
          insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
          values (p_tournament_id, 'Round robin', 1, v_slot, v_entries[a], v_entries[b], 0);
          v_slot := v_slot + 1;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind in ('knockout', 'doubleElim', 'consolation') then
    perform public._build_ko_round(p_tournament_id, 0, 1, v_entries);
    return null;

  else
    return 'The first stage (' || coalesce(v_kind, '?') || ') is drawn manually for now.';
  end if;
end $$;
grant execute on function public.generate_from_format(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
