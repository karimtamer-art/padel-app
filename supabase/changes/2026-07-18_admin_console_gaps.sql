-- ============================================================================
-- 2026-07-18 · Admin-console audit fixes (draw eligibility, RBAC staff gating,
--              ban/unban, order restock). Idempotent — safe to re-run.
--
-- Run this on the live DB (or re-run the whole canonical migration), then:
--   notify pgrst, 'reload schema';
--
-- Covers four audit findings:
--   1. Paid + guest tournament pairs excluded from every generated draw.
--   2. Support / Analyst console tabs permanently empty (RPCs gated on
--      is_admin=true, which only super_admin has).
--   3. Ban / Unban was a silent no-op (profiles.status is service-role-only).
--   4. Reject / refund / cancel never restored product stock.
-- ============================================================================

-- ── 1. Draw eligibility: include paid + guest pairs ─────────────────────────
-- Free events settle on 'registered'; paid events on 'paid' (never 'registered'),
-- so filtering status='registered' drew paid tournaments from 0 pairs. Guests
-- have player_id NULL, so the old INNER JOIN profiles dropped them — LEFT JOIN
-- keeps them (seeded at level 0, drawn but unrated).

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
      left join profiles p1 on p1.id = te.player_id
      left join profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status in ('registered', 'paid', 'confirmed')
  ) s;

  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 confirmed pairs.'; end if;

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
      left join public.profiles p1 on p1.id = te.player_id
      left join public.profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status in ('registered', 'paid', 'confirmed')
  ) s;
  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 confirmed pairs.'; end if;

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

-- ── 2. RBAC staff gating ────────────────────────────────────────────────────
-- Only super_admin has is_admin=true; organizer/support/analyst hold a console
-- role with is_admin=false. Shared read consoles must let any staffer see data;
-- moderation actions are limited to super admins + Support.

create or replace function public._is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_admin or admin_role is not null from profiles where id = auth.uid()),
    false);
$$;
grant execute on function public._is_staff() to authenticated;

create or replace function public._can_moderate()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_admin or admin_role = 'support' from profiles where id = auth.uid()),
    false);
$$;
grant execute on function public._can_moderate() to authenticated;

-- Re-point the read consoles + moderation RPCs. Bodies unchanged except the
-- guard line; full definitions live in the canonical migration.
do $$
begin
  -- admin_matches_console: swap _is_admin() -> _is_staff()
  execute (
    select replace(pg_get_functiondef('public.admin_matches_console(int)'::regprocedure),
                   'not public._is_admin()', 'not public._is_staff()'));
  -- admin_players_console
  execute (
    select replace(pg_get_functiondef('public.admin_players_console()'::regprocedure),
                   'not public._is_admin()', 'not public._is_staff()'));
  -- admin_dashboard_counts
  execute (
    select replace(pg_get_functiondef('public.admin_dashboard_counts()'::regprocedure),
                   'not public._is_admin()', 'not public._is_staff()'));
  -- admin_resolve_match: _is_admin() -> _can_moderate() (+ message)
  execute (
    select replace(
             replace(pg_get_functiondef('public.admin_resolve_match(uuid,text,text,text,text)'::regprocedure),
                     'not public._is_admin()', 'not public._can_moderate()'),
             '''Admins only.''', '''Not authorised.'''));
  -- admin_cancel_match
  execute (
    select replace(
             replace(pg_get_functiondef('public.admin_cancel_match(uuid,text,text)'::regprocedure),
                     'not public._is_admin()', 'not public._can_moderate()'),
             '''Admins only.''', '''Not authorised.'''));
end $$;

-- ── 3. Ban / unban / flag a player ──────────────────────────────────────────
create or replace function public.admin_set_status(p_player_id uuid, p_status text)
returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old text; v_target_admin boolean;
begin
  if not public._can_moderate() then return 'Not authorised.'; end if;
  if p_status not in ('active','banned','flagged') then return 'Invalid status.'; end if;
  select coalesce(status, 'active'), coalesce(is_admin, false)
    into v_old, v_target_admin
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  if v_target_admin then return 'Cannot change an admin account.'; end if;
  update public.profiles set status = p_status where id = p_player_id;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'set_player_status', 'profile', p_player_id,
          jsonb_build_object('status', v_old),
          jsonb_build_object('status', p_status), null);
  return null;
end $$;
grant execute on function public.admin_set_status(uuid, text) to authenticated;

-- ── 4. Restore product stock when an order is voided ────────────────────────
alter table public.orders add column if not exists voided_at timestamptz;
alter table public.orders
  add column if not exists voided_by uuid references public.profiles(id) on delete set null;

create or replace function public.restock_on_void()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  if new.status in ('cancelled', 'refunded')
     and old.status not in ('cancelled', 'refunded') then
    for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
      update public.products
         set stock = coalesce(stock, 0) + coalesce((it->>'qty')::int, 0)
       where id = nullif(it->>'product_id', '')::uuid;
    end loop;
    new.voided_at := now();
    new.voided_by := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists trg_restock_on_void on public.orders;
create trigger trg_restock_on_void before update on public.orders
  for each row when (old.status is distinct from new.status)
  execute function public.restock_on_void();

notify pgrst, 'reload schema';
