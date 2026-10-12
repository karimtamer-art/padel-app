-- ============================================================================
-- ASSESSMENT CENTERS + BOOKABLE SLOTS  (2026-10-12)
--
-- Places a player can go to have their level assessed in person, each with a
-- list of time slots the console publishes. A player books a slot from the
-- app; the slot is ONE seat, so booking it closes it for everybody else.
--
--   assessment_centers  — the venue (name, area, address, map link, phone,
--                         price shown to players, live/hidden).
--   assessment_slots    — one row per bookable time. `booked_by` NULL = open.
--
-- How "closes automatically" is enforced:
--   * Booking is ONE conditional UPDATE inside book_assessment_slot
--     (`where booked_by is null and starts_at > now()`), so two players tapping
--     the same slot at the same moment cannot both get it — the loser is told
--     it was just taken.
--   * The slots SELECT policy shows a player only OPEN future slots and their
--     OWN booking. A taken slot simply disappears from everyone else's list,
--     and nobody can read who booked what except staff with the section.
--   * Players have NO write grant on either table. The two RPCs are the only
--     way a player touches a slot.
--
-- A player may hold ONE upcoming booking at a time — otherwise one person can
-- quietly sit on a whole afternoon. Cancelling before the start reopens it.
--
-- NO MONEY lives here. `price_egp` is a label ("pay at the center"), nothing
-- is charged in-app (cash only, CLAUDE.md rule 8) and nothing reaches the P&L.
--
-- NO RATING is written here either. An assessment's outcome still goes through
-- the existing admin rating tools — rule 2, the client never sets a level.
--
-- Adds a grantable console section id 'assessments', so `_role_default` and
-- kSections / _allIds in lib/admin/data/roles_model.dart move together.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.assessment_centers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  area        text,                 -- "New Cairo", "Sheikh Zayed" …
  address     text,
  map_url     text,                 -- pasted Google Maps link, opened as-is
  phone       text,                 -- the CENTER's line, public on purpose
  description text,
  price_egp   numeric(10,2),        -- display only, paid at the center
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Drift guards (see CLAUDE.md "Live-DB drift traps").
alter table public.assessment_centers add column if not exists area        text;
alter table public.assessment_centers add column if not exists address     text;
alter table public.assessment_centers add column if not exists map_url     text;
alter table public.assessment_centers add column if not exists phone       text;
alter table public.assessment_centers add column if not exists description text;
alter table public.assessment_centers add column if not exists price_egp   numeric(10,2);
alter table public.assessment_centers add column if not exists is_active   boolean not null default true;
alter table public.assessment_centers add column if not exists sort_order  int not null default 0;
alter table public.assessment_centers add column if not exists created_at  timestamptz not null default now();
alter table public.assessment_centers add column if not exists updated_at  timestamptz not null default now();

create table if not exists public.assessment_slots (
  id           uuid primary key default gen_random_uuid(),
  center_id    uuid not null references public.assessment_centers(id) on delete cascade,
  starts_at    timestamptz not null,
  duration_min int not null default 60,
  booked_by    uuid,
  booked_at    timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.assessment_slots add column if not exists duration_min int not null default 60;
alter table public.assessment_slots add column if not exists booked_by    uuid;
alter table public.assessment_slots add column if not exists booked_at    timestamptz;
alter table public.assessment_slots add column if not exists created_at   timestamptz not null default now();

-- Named explicitly: the console embeds `profiles!assessment_slots_booked_by_fkey`.
-- SET NULL so deleting an account reopens the slot instead of blocking the delete.
alter table public.assessment_slots drop constraint if exists assessment_slots_booked_by_fkey;
alter table public.assessment_slots add constraint assessment_slots_booked_by_fkey
  foreign key (booked_by) references public.profiles(id) on delete set null;

alter table public.assessment_slots drop constraint if exists assessment_slots_duration_chk;
alter table public.assessment_slots add constraint assessment_slots_duration_chk
  check (duration_min between 5 and 480);

-- The same time twice at one center is a double-publish, never intended. The
-- console's bulk add relies on this to skip times that already exist.
create unique index if not exists assessment_slots_center_time_uq
  on public.assessment_slots (center_id, starts_at);
create index if not exists assessment_slots_open_idx
  on public.assessment_slots (starts_at) where booked_by is null;
create index if not exists assessment_slots_booked_by_idx
  on public.assessment_slots (booked_by) where booked_by is not null;
create index if not exists assessment_centers_active_idx
  on public.assessment_centers (is_active, sort_order);

comment on table public.assessment_centers is
  'In-person level assessment venues. Display only — no money, no rating.';
comment on table public.assessment_slots is
  'One bookable seat per row. booked_by NULL = open. Players book only via '
  'book_assessment_slot / cancel_assessment_booking.';

-- ── RLS ─────────────────────────────────────────────────────────
alter table public.assessment_centers enable row level security;
alter table public.assessment_slots   enable row level security;

drop policy if exists "assessment_centers: read" on public.assessment_centers;
create policy "assessment_centers: read" on public.assessment_centers for select
  using (is_active = true
         or public._has_access('assessments')
         or exists (select 1 from public.assessment_slots s
                     where s.center_id = assessment_centers.id
                       and s.booked_by = auth.uid()));

drop policy if exists "assessment_centers: admin write" on public.assessment_centers;
create policy "assessment_centers: admin write" on public.assessment_centers for all
  using (public._can_edit('assessments')) with check (public._can_edit('assessments'));

-- Open + future, or mine, or staff. A taken slot is invisible to everyone else,
-- which is both the "closes automatically" UX and the privacy rule.
drop policy if exists "assessment_slots: read" on public.assessment_slots;
create policy "assessment_slots: read" on public.assessment_slots for select
  using (booked_by = auth.uid()
         or public._has_access('assessments')
         or (booked_by is null and starts_at > now()));

drop policy if exists "assessment_slots: admin write" on public.assessment_slots;
create policy "assessment_slots: admin write" on public.assessment_slots for all
  using (public._can_edit('assessments')) with check (public._can_edit('assessments'));

drop trigger if exists trg_assessment_centers_touch on public.assessment_centers;
create trigger trg_assessment_centers_touch before update on public.assessment_centers
  for each row execute function public.touch_updated_at();

grant select on public.assessment_centers to authenticated;
grant select on public.assessment_slots   to authenticated;
-- Writes are granted so the console's RLS-guarded table edits work; for a
-- player the "admin write" policies above refuse every row.
grant insert, update, delete on public.assessment_centers to authenticated;
grant insert, update, delete on public.assessment_slots   to authenticated;

-- ── Book a slot ─────────────────────────────────────────────────
-- Returns the booked slot's id. Errors are sentences, shown to the player.
create or replace function public.book_assessment_slot(p_slot uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_id     uuid;
  v_center uuid;
  v_start  timestamptz;
  v_cname  text;
  v_pname  text;
begin
  if v_uid is null then
    raise exception 'Sign in to book an assessment.';
  end if;

  -- Serialise this player's own bookings, so two quick taps on two different
  -- slots can't both slip past the one-booking rule below.
  perform pg_advisory_xact_lock(hashtext('assessment_booking:' || v_uid::text));

  if exists (select 1 from public.assessment_slots
              where booked_by = v_uid and starts_at > now()) then
    raise exception 'You already have an assessment booked. Cancel it first to pick another time.';
  end if;

  -- THE close: one conditional update. Whoever commits first wins the seat.
  update public.assessment_slots s
     set booked_by = v_uid, booked_at = now()
   where s.id = p_slot
     and s.booked_by is null
     and s.starts_at > now()
     and exists (select 1 from public.assessment_centers c
                  where c.id = s.center_id and c.is_active)
  returning s.id, s.center_id, s.starts_at into v_id, v_center, v_start;

  if v_id is null then
    raise exception 'Sorry, that slot was just taken. Please pick another time.';
  end if;

  select name into v_cname from public.assessment_centers where id = v_center;
  select name into v_pname from public.profiles where id = v_uid;

  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'admin_assessment', 'New assessment booking',
         coalesce(v_pname, 'A player') || ' · ' || coalesce(v_cname, 'center')
           || ' · ' || to_char(v_start at time zone 'Africa/Cairo', 'Dy DD Mon HH24:MI'),
         jsonb_build_object('slot_id', v_id, 'admin', true)
    from public.profiles p
   where p.is_admin = true;

  return v_id;
end $$;

revoke all on function public.book_assessment_slot(uuid) from public;
grant execute on function public.book_assessment_slot(uuid) to authenticated;

-- ── Player cancels their own booking (before it starts) ────────
create or replace function public.cancel_assessment_booking(p_slot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_id    uuid;
  v_start timestamptz;
  v_cname text;
  v_pname text;
begin
  update public.assessment_slots s
     set booked_by = null, booked_at = null
   where s.id = p_slot
     and s.booked_by = v_uid
     and s.starts_at > now()
  returning s.id, s.starts_at,
            (select c.name from public.assessment_centers c where c.id = s.center_id)
       into v_id, v_start, v_cname;

  if v_id is null then
    raise exception 'That booking can no longer be cancelled.';
  end if;

  select name into v_pname from public.profiles where id = v_uid;

  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'admin_assessment', 'Assessment booking cancelled',
         coalesce(v_pname, 'A player') || ' · ' || coalesce(v_cname, 'center')
           || ' · ' || to_char(v_start at time zone 'Africa/Cairo', 'Dy DD Mon HH24:MI'),
         jsonb_build_object('slot_id', v_id, 'admin', true)
    from public.profiles p
   where p.is_admin = true;
end $$;

revoke all on function public.cancel_assessment_booking(uuid) from public;
grant execute on function public.cancel_assessment_booking(uuid) to authenticated;

-- ── Staff releases a booking (no-show, center closed, …) ───────
-- An RPC rather than a plain update so the player is told their seat is gone.
create or replace function public.admin_release_assessment_slot(p_slot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_player uuid;
  v_start  timestamptz;
  v_cname  text;
begin
  if not public._can_edit('assessments') then
    raise exception 'Not authorised.';
  end if;

  select s.booked_by, s.starts_at, c.name
    into v_player, v_start, v_cname
    from public.assessment_slots s
    join public.assessment_centers c on c.id = s.center_id
   where s.id = p_slot
   for update of s;

  update public.assessment_slots
     set booked_by = null, booked_at = null
   where id = p_slot;

  if v_player is not null and v_start > now() then
    insert into public.notifications (user_id, type, title, body, data)
    values (v_player, 'assessment', 'Your assessment was cancelled',
            coalesce(v_cname, 'The center') || ' · '
              || to_char(v_start at time zone 'Africa/Cairo', 'Dy DD Mon HH24:MI')
              || ' — please book another time.',
            jsonb_build_object('slot_id', p_slot));
  end if;
end $$;

revoke all on function public.admin_release_assessment_slot(uuid) from public;
grant execute on function public.admin_release_assessment_slot(uuid) to authenticated;

-- ── The new console section ────────────────────────────────────
-- Super Admin only by default; grantable from Team & Roles.
-- MUST stay in lockstep with kRoles in lib/admin/data/roles_model.dart.
create or replace function public._role_default(p_role text)
returns text[] language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin' then array['dashboard','reports','players','matches',
                                  'tournaments','formats','courts','assessments',
                                  'store','used_rackets','promotions','sponsors',
                                  'payments','requests','broadcasts','team']
    when 'organizer'   then array['tournaments','formats','courts','broadcasts']
    when 'support'     then array['players','matches','requests']
    when 'analyst'     then array['dashboard','reports']
    else '{}'::text[] end;
$$;
grant execute on function public._role_default(text) to authenticated;

notify pgrst, 'reload schema';
