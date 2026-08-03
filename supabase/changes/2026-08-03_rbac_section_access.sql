-- ============================================================================
-- RBAC phase 2 — make the DB honour GRANTED SECTIONS, not just the role.
-- Run this whole file once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- THE BUG
-- -------
-- `admin_grant_role` stores `profiles.admin_access` (the section ids a super
-- admin ticked), but nothing in the database ever read it. Every guard was
-- role-shaped:
--     _is_admin()       → super_admin only
--     _can_moderate()   → super_admin or admin_role = 'support'
--     owns_tournament() → super_admin or the OWNING organizer
-- So giving a Support user the Store section, or an Organizer the Players
-- section, showed the tab (nav is filtered client-side from admin_access) and
-- then failed on every call with "Not authorised." Only the role's own default
-- sections ever worked.
--
-- THE FIX
-- -------
-- One access resolver, used by every section-scoped guard:
--     _access_ids()        → the caller's effective section ids
--                            (super admin → all; else admin_access, or the
--                             role's default set when admin_access is null)
--     _has_access(section) → can OPEN that section (read)
--     _can_edit(section)   → can CHANGE things in it (read + not an analyst)
-- The role defaults here MUST stay in lockstep with `kRoles` in
-- lib/admin/data/roles_model.dart.
--
-- `_is_admin()` is deliberately NOT widened — it stays "super admin", because
-- it is the blanket god-check behind unrelated RLS. Only the section-scoped
-- guards move.
-- ============================================================================

-- ── The access resolver ─────────────────────────────────────────────────────

-- Default sections per role — mirrors kRoles[...].defaultAccess in Dart.
create or replace function public._role_default(p_role text)
returns text[] language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin' then array['dashboard','reports','players','matches',
                                  'tournaments','formats','courts','store',
                                  'promotions','payments','requests',
                                  'broadcasts','team']
    when 'organizer'   then array['tournaments','formats','courts','broadcasts']
    when 'support'     then array['players','matches','requests']
    when 'analyst'     then array['dashboard','reports']
    else '{}'::text[] end;
$$;
grant execute on function public._role_default(text) to authenticated;

-- The caller's effective sections. A super admin always gets everything (that
-- also covers a legacy admin whose admin_role backfill never ran).
create or replace function public._access_ids()
returns text[] language plpgsql stable security definer set search_path = public as $$
declare
  v_is_admin boolean; v_role text; v_access jsonb;
begin
  select coalesce(is_admin, false), admin_role, admin_access
    into v_is_admin, v_role, v_access
    from public.profiles where id = auth.uid();
  if not found then return '{}'::text[]; end if;
  if v_is_admin then return public._role_default('super_admin'); end if;
  if v_role is null then return '{}'::text[]; end if;
  if jsonb_typeof(v_access) = 'array' and jsonb_array_length(v_access) > 0 then
    return (select array(select jsonb_array_elements_text(v_access)));
  end if;
  return public._role_default(v_role);
end $$;
grant execute on function public._access_ids() to authenticated;

-- Can the caller OPEN this console section?
create or replace function public._has_access(p_section text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_section = any (public._access_ids());
$$;
grant execute on function public._has_access(text) to authenticated;

-- Can the caller CHANGE things in it? Analysts are read-only by definition.
create or replace function public._can_edit(p_section text)
returns boolean language sql stable security definer set search_path = public as $$
  select public._has_access(p_section)
     and coalesce((select is_admin or admin_role is distinct from 'analyst'
                     from public.profiles where id = auth.uid()), false);
$$;
grant execute on function public._can_edit(text) to authenticated;

-- ── Tournaments / Format Builder ────────────────────────────────────────────
-- Organizers stay scoped to their OWN events. Any other staffer holding the
-- Tournaments (or Format Builder) section manages all of them, like an admin.
create or replace function public.owns_tournament(p_tid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public._is_admin()
      or (
        (public._can_edit('tournaments') or public._can_edit('formats'))
        and (
          coalesce(public.current_admin_role(), '') <> 'organizer'
          or exists (select 1 from public.tournaments t
                      where t.id = p_tid and t.organizer_id = auth.uid())
        )
      );
$$;
grant execute on function public.owns_tournament(uuid) to authenticated;

-- ── Re-point the section-scoped RPC guards ──────────────────────────────────
-- Bodies are untouched: each function is re-created from its own live
-- definition with only the guard line swapped. Same trick as
-- 2026-07-18_admin_console_gaps.sql. A function that is missing, or whose guard
-- was already migrated, is skipped with a notice.
do $$
declare
  r record;
  v_def text;
begin
  for r in
    select * from (values
      -- Players
      ('public.admin_set_player_rating(uuid,int)',
       'not public._is_admin()',     'not public._can_edit(''players'')'),
      ('public.admin_set_rating(uuid,numeric,numeric,boolean,text)',
       'not public._is_admin()',     'not public._can_edit(''players'')'),
      ('public.admin_set_status(uuid,text)',
       'not public._can_moderate()', 'not public._can_edit(''players'')'),
      -- Matches
      ('public.admin_cancel_match(uuid,text,text)',
       'not public._can_moderate()', 'not public._can_edit(''matches'')'),
      ('public.admin_resolve_match(uuid,text,text,text,text)',
       'not public._can_moderate()', 'not public._can_edit(''matches'')'),
      ('public.admin_list_matches(int)',
       'not public._is_admin()',     'not public._has_access(''matches'')'),
      -- Promotions
      ('public.admin_save_banner(uuid,text,text,text,text,boolean,int,int,jsonb)',
       'not public._is_admin()',     'not public._can_edit(''promotions'')'),
      ('public.admin_delete_banner(uuid)',
       'not public._is_admin()',     'not public._can_edit(''promotions'')'),
      -- Team & Roles (read side; the write RPCs are re-created in full below)
      ('public.admin_list_staff()',
       'not public._is_admin()',     'not public._has_access(''team'')'),
      ('public.admin_search_users(text)',
       'not public._is_admin()',     'not public._has_access(''team'')'),
      -- Courts
      ('public.organizer_save_court(uuid,text,text,text,text,numeric,boolean,numeric,numeric,text)',
       'public.current_admin_role() <> ''organizer'' and not public._is_admin()',
       'not public._can_edit(''courts'')'),
      ('public.organizer_delete_court(uuid)',
       'public.current_admin_role() <> ''organizer'' and not public._is_admin()',
       'not public._can_edit(''courts'')'),
      ('public.organizer_set_court_maintenance(uuid,boolean)',
       'public.current_admin_role() <> ''organizer'' and not public._is_admin()',
       'not public._can_edit(''courts'')'),
      ('public.organizer_set_court_active(uuid,boolean)',
       'public.current_admin_role() <> ''organizer'' and not public._is_admin()',
       'not public._can_edit(''courts'')'),
      -- Broadcasts (organizer send path)
      ('public.organizer_broadcast(text,text,uuid,text)',
       'public.current_admin_role() <> ''organizer'' and not public._is_admin()',
       'not public._can_edit(''broadcasts'')')
    ) as t(fn, old_guard, new_guard)
  loop
    v_def := null;
    begin
      v_def := pg_get_functiondef(r.fn::regprocedure);
    exception when others then
      raise notice 'rbac: skipping % (not found)', r.fn;
    end;
    if v_def is null then
      null;                                    -- already reported above
    elsif position(r.old_guard in v_def) = 0 then
      raise notice 'rbac: skipping % (guard already migrated or changed)', r.fn;
    else
      execute replace(v_def, r.old_guard, r.new_guard);
    end if;
  end loop;
end $$;

-- ── Team & Roles: grantable, but no privilege escalation ────────────────────
-- A staffer holding the Team section can manage staff — EXCEPT they may never
-- mint or touch a super admin, and may never grant a section they don't
-- themselves hold. Only a real super admin can do either.
create or replace function public.admin_grant_role(
  p_user   uuid,
  p_role   text,
  p_access jsonb default null,
  p_scope  text  default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_old_access jsonb; v_old_scope text; v_owner boolean;
  v_wanted text[];
  v_bad text;
begin
  if not public._can_edit('team') then return 'Not authorised.'; end if;
  if p_role not in ('super_admin','organizer','support','analyst') then
    return 'Unknown role.';
  end if;

  select admin_role, admin_access, admin_scope, coalesce(is_owner, false)
    into v_old_role, v_old_access, v_old_scope, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner always has full access and can''t be changed.'; end if;

  -- Escalation guards — skipped for actual super admins.
  if not public._is_admin() then
    if p_role = 'super_admin' or v_old_role = 'super_admin' then
      return 'Only a super admin can manage super admins.';
    end if;
    v_wanted := case
      when jsonb_typeof(p_access) = 'array' and jsonb_array_length(p_access) > 0
        then (select array(select jsonb_array_elements_text(p_access)))
      else public._role_default(p_role)
    end;
    select t.sec into v_bad from unnest(v_wanted) as t(sec)
     where not public._has_access(t.sec) limit 1;
    if v_bad is not null then
      return 'You can only grant access you have yourself (' || v_bad || ').';
    end if;
  end if;

  update public.profiles set
    admin_role   = p_role,
    admin_access = p_access,                 -- null → the role's default set
    admin_scope  = nullif(btrim(coalesce(p_scope, '')), ''),
    -- only super admins keep the blanket is_admin flag
    is_admin     = (p_role = 'super_admin')
  where id = p_user;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'grant_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role, 'access', v_old_access, 'scope', v_old_scope),
    jsonb_build_object('role', p_role,     'access', p_access,     'scope', p_scope),
    null);
  return null;
end $$;
grant execute on function public.admin_grant_role(uuid, text, jsonb, text) to authenticated;

create or replace function public.admin_revoke_role(p_user uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_owner boolean;
begin
  if not public._can_edit('team') then return 'Not authorised.'; end if;
  select admin_role, coalesce(is_owner, false) into v_old_role, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner can''t be removed.'; end if;
  if v_old_role = 'super_admin' and not public._is_admin() then
    return 'Only a super admin can manage super admins.';
  end if;

  update public.profiles set
    admin_role = null, admin_access = null, admin_scope = null, is_admin = false
  where id = p_user;

  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'revoke_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role), jsonb_build_object('role', null), null);
  return null;
end $$;
grant execute on function public.admin_revoke_role(uuid) to authenticated;

-- ── RLS: the same sections, on the tables the screens read directly ─────────

-- Matches
drop policy if exists "matches: admin read" on public.matches;
create policy "matches: admin read" on public.matches for select
  using (public._has_access('matches'));

drop policy if exists "mrs: player or admin read" on public.match_result_submissions;
create policy "mrs: player or admin read" on public.match_result_submissions for select
  using (
    exists (select 1 from public.match_players mp
             where mp.match_id = match_result_submissions.match_id
               and mp.player_id = auth.uid())
    or public._has_access('matches')
  );

-- Store & Orders  (hidden products are staff-only)
drop policy if exists "products: read visible" on public.products;
create policy "products: read visible" on public.products
  for select using (is_visible = true or public._has_access('store'));
drop policy if exists "products: admin write" on public.products;
create policy "products: admin write" on public.products
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

drop policy if exists "product_costs: admin only" on public.product_costs;
create policy "product_costs: admin only" on public.product_costs
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

drop policy if exists "product_images: read" on public.product_images;
create policy "product_images: read" on public.product_images
  for select using (exists (
    select 1 from public.products p
     where p.id = product_id and (p.is_visible or public._has_access('store'))));
drop policy if exists "product_images: admin write" on public.product_images;
create policy "product_images: admin write" on public.product_images
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

-- storage.objects is owned by supabase_storage_admin on some projects, so
-- policy DDL there can fail with "must be owner of table objects". The whole
-- script runs as ONE transaction in the SQL editor — an unguarded failure here
-- would roll back every fix above it. Guarded so it degrades to a notice.
do $$ begin
  drop policy if exists "product-images admin write" on storage.objects;
  create policy "product-images admin write" on storage.objects
    for all to authenticated
    using (bucket_id = 'product-images' and public._can_edit('store'))
    with check (bucket_id = 'product-images' and public._can_edit('store'));
exception when others then
  raise notice 'rbac: storage policy product-images skipped (%)', sqlerrm;
end $$;

-- Promotions
drop policy if exists "banners: read active" on public.banners;
create policy "banners: read active" on public.banners
  for select using (is_active = true or public._has_access('promotions'));
drop policy if exists "banners: admin write" on public.banners;
create policy "banners: admin write" on public.banners
  for all using (public._can_edit('promotions')) with check (public._can_edit('promotions'));

do $$ begin
  drop policy if exists "banner-images admin write" on storage.objects;
  create policy "banner-images admin write" on storage.objects
    for all to authenticated
    using (bucket_id = 'banner-images' and public._can_edit('promotions'))
    with check (bucket_id = 'banner-images' and public._can_edit('promotions'));
exception when others then
  raise notice 'rbac: storage policy banner-images skipped (%)', sqlerrm;
end $$;

-- Payments (the Store & Orders screen works the same order rows)
drop policy if exists "orders: admin read" on public.orders;
create policy "orders: admin read" on public.orders for select
  using (public._has_access('payments') or public._has_access('store'));
drop policy if exists "orders: admin update" on public.orders;
create policy "orders: admin update" on public.orders for update
  using (public._can_edit('payments') or public._can_edit('store'))
  with check (public._can_edit('payments') or public._can_edit('store'));

do $$ begin
  drop policy if exists "payment-proofs admin read" on storage.objects;
  create policy "payment-proofs admin read" on storage.objects
    for select to authenticated
    using (bucket_id = 'payment-proofs'
           and (public._has_access('payments') or public._has_access('store')));
exception when others then
  raise notice 'rbac: storage policy payment-proofs skipped (%)', sqlerrm;
end $$;

-- Requests (repairs + trade-ins)
drop policy if exists "trades: admin read" on public.trade_requests;
create policy "trades: admin read" on public.trade_requests for select
  using (player_id = auth.uid() or public._has_access('requests'));
drop policy if exists "trades: admin update" on public.trade_requests;
create policy "trades: admin update" on public.trade_requests for update
  using (public._can_edit('requests')) with check (public._can_edit('requests'));

drop policy if exists "repair: read own or admin" on public.repair_requests;
create policy "repair: read own or admin" on public.repair_requests for select
  using (player_id = auth.uid() or public._has_access('requests'));
drop policy if exists "repair: admin update" on public.repair_requests;
create policy "repair: admin update" on public.repair_requests for update
  using (public._can_edit('requests')) with check (public._can_edit('requests'));

-- Broadcasts: the console inserts straight into the table (the fan-out trigger
-- does the rest). There was no insert policy in the repo at all — add one,
-- scoped to the Broadcasts section.
drop policy if exists "broadcasts: staff write" on public.broadcasts;
create policy "broadcasts: staff write" on public.broadcasts
  for insert to authenticated with check (public._can_edit('broadcasts'));
grant select, insert on public.broadcasts to authenticated;

notify pgrst, 'reload schema';

-- ── Verify ──────────────────────────────────────────────────────────────────
-- The result grid below is the proof this file applied. For each staffer,
-- `granted` is what the Team screen saved (null → the role default is used).
-- If `granted` doesn't list the section they're being refused, the grant never
-- reached the database and the problem is the Team screen, not this file.
select p.name,
       p.admin_role,
       coalesce(p.admin_access::text, '(role default)') as granted,
       public._role_default(p.admin_role)               as role_default,
       p.is_admin, p.is_owner
  from public.profiles p
 where p.admin_role is not null
 order by p.admin_role, p.name;
