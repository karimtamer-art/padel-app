-- ============================================================
-- 2026-10-22 · Website registrations → the draw, as REAL players
-- ============================================================
-- A website pair used to be retyped into the entry manager as a GUEST, and a
-- guest has no profile: finalize_tournament rates only clean 2v2s of four real
-- profiles, so any match involving a website player counted for NOBODY in it —
-- including the app players on the other side of the net.
--
-- admin_web_to_draw() moves a website registration into tournament_entries in
-- one tap and looks each person up by PHONE first: if they have an app account
-- (onboarding asks every player for one) they go in as that real player and
-- their results count; otherwise they go in as a guest, exactly as before.
--
--   * _profile_by_phone() matches on the last 10 digits, so 01501800943,
--     +20 150 180 0943 and 201501800943 are the same number. It answers only
--     when EXACTLY ONE profile matches — a shared number links nobody.
--   * Two "find me a partner" solos are paired by passing the second one as
--     p_pair_with; both registrations are marked done.
--   * web_registrations.entry_id records the move, so a row can't be added
--     twice, and capacity stops counting a registration once its entry exists
--     (it used to count both the row and the entry).
--   * Same permission as the entry manager: owns_tournament().
--   * No money moves: the entry goes in as 'registered'. The InstaPay payment
--     stays on the web_registrations row.
--
-- Run AFTER 2026-10-22_one_level_setting.sql (this redefines
-- web_open_tournaments with the same level helpers). Safe to re-run.
-- ============================================================

alter table public.web_registrations
  add column if not exists entry_id uuid
    references public.tournament_entries(id) on delete set null;

-- 1. Phone → app account (one unambiguous match, or NULL) ---------------------
create or replace function public._profile_by_phone(p_phone text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  v_key text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  v_ids uuid[];
begin
  if length(v_key) < 10 then return null; end if;
  select array_agg(id) into v_ids from (
    select p.id from public.profiles p
     where p.phone is not null
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = v_key
     limit 2) s;
  if coalesce(array_length(v_ids, 1), 0) <> 1 then return null; end if;
  return v_ids[1];
end $$;
revoke all on function public._profile_by_phone(text) from public, anon, authenticated;

-- The matched account's display name, for the console list (NULL = no account).
create or replace function public._account_name_by_phone(p_phone text)
returns text language sql stable security definer set search_path = public as $$
  select p.name from public.profiles p where p.id = public._profile_by_phone(p_phone);
$$;
revoke all on function public._account_name_by_phone(text) from public, anon, authenticated;

-- 2. Capacity: a registration already moved into the draw is counted once -----
create or replace function public.web_open_tournaments()
returns table (
  id uuid, name text, venue_name text, start_date date, start_time text,
  entry_fee numeric, category text, min_category text, max_category text,
  spots_left int)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select t.id, t.name, t.venue_name, t.start_date, t.start_time,
         coalesce(t.entry_fee, 0)::numeric, coalesce(t.category, 'open'),
         public._web_level_from_min(t.min_rating), public._web_level_from_max(t.max_rating),
         case when coalesce(t.capacity, 0) <= 0 then null
              else greatest(0, t.capacity
                - (select count(*) from public.tournament_entries e
                    where e.tournament_id = t.id and e.status not in ('withdrawn', 'cancelled'))
                -- a pair takes a slot; two solo players make one pair. Rows
                -- already in the draw (entry_id) are counted as entries above.
                - (select count(*) filter (where not w.needs_partner)
                          + ceil(count(*) filter (where w.needs_partner) / 2.0)
                     from public.web_registrations w
                    where w.tournament_id = t.id and w.status in ('pending', 'confirmed')
                      and w.entry_id is null)
                )::int
         end
    from public.tournaments t
   where coalesce(t.status, 'auto') not in ('cancelled', 'completed', 'in_progress')
     and coalesce(t.region_id, 'EG') = 'EG'
     and (t.registration_opens is null or current_date >= t.registration_opens)
     and not coalesce(t.registration_closed, false)
     and t.start_date >= current_date
     and (public.tournament_reg_deadline(t.start_date, t.start_time) is null
          or now() < public.tournament_reg_deadline(t.start_date, t.start_time))
   order by t.start_date, t.start_time nulls last;
end $$;
revoke all on function public.web_open_tournaments() from public;
grant execute on function public.web_open_tournaments() to anon, authenticated;

-- 3. Console list: a tournament's website registrations + who has an account --
create or replace function public.admin_web_registrations(p_tournament uuid)
returns table (
  id uuid, name text, phone text, email text, level text, needs_partner boolean,
  partner_name text, partner_phone text, partner_level text,
  amount_due numeric, instapay_sender text, proof_path text,
  status text, entry_id uuid, created_at timestamptz,
  player_account text, partner_account text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.owns_tournament(p_tournament) then
    raise exception 'Not authorised.';
  end if;
  return query
  select w.id, w.name, w.phone, w.email, w.level, w.needs_partner,
         w.partner_name, w.partner_phone, w.partner_level,
         w.amount_due, w.instapay_sender, w.proof_path,
         w.status, w.entry_id, w.created_at,
         public._account_name_by_phone(w.phone),
         public._account_name_by_phone(w.partner_phone)
    from public.web_registrations w
   where w.tournament_id = p_tournament
   order by (w.entry_id is not null), w.needs_partner, w.created_at;
end $$;
revoke all on function public.admin_web_registrations(uuid) from public;
grant execute on function public.admin_web_registrations(uuid) to authenticated;

-- 4. Move one registration (or two paired solos) into the draw -----------------
-- Returns NULL on success, else a sentence for the console — same contract as
-- organizer_add_entry.
create or replace function public.admin_web_to_draw(p_reg uuid, p_pair_with uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  w        public.web_registrations%rowtype;
  o        public.web_registrations%rowtype;
  v_pid    uuid;  v_pname   text;
  v_partid uuid;  v_partname text;
  v_tmp    uuid;  v_tmpn    text;
  v_entry  uuid;
  v_other  uuid;   -- the second solo, when two are paired
  v_tname  text;
begin
  select * into w from public.web_registrations where id = p_reg for update;
  if not found then return 'Registration not found.'; end if;
  if not public.owns_tournament(w.tournament_id) then return 'Not authorised.'; end if;
  if w.entry_id is not null then return 'Already in the draw.'; end if;
  if w.status not in ('pending', 'confirmed') then
    return 'This registration is ' || w.status || '.';
  end if;

  if w.needs_partner then
    if p_pair_with is null then
      return 'This player has no partner yet — pick another solo player to pair them with.';
    end if;
    select * into o from public.web_registrations where id = p_pair_with for update;
    if not found or o.id = w.id or o.tournament_id <> w.tournament_id
       or not o.needs_partner or o.entry_id is not null
       or o.status not in ('pending', 'confirmed') then
      return 'That player can''t be paired — pick another solo player in this tournament.';
    end if;
    v_other := o.id;
    v_partid := public._profile_by_phone(o.phone);
    v_partname := o.name;
  else
    if p_pair_with is not null then return 'Only solo players are paired.'; end if;
    v_partid := public._profile_by_phone(w.partner_phone);
    v_partname := w.partner_name;
  end if;

  v_pid := public._profile_by_phone(w.phone);
  v_pname := w.name;
  if v_partid = v_pid then v_partid := null; end if;   -- one number for both: link one
  -- A guest + an app player: put the app player first, as the registrant.
  if v_pid is null and v_partid is not null then
    v_tmp := v_pid; v_pid := v_partid; v_partid := v_tmp;
    v_tmpn := v_pname; v_pname := v_partname; v_partname := v_tmpn;
  end if;

  if v_pid is not null then
    select coalesce(nullif(btrim(name), ''), v_pname) into v_pname from public.profiles where id = v_pid;
  end if;
  if v_partid is not null then
    select coalesce(nullif(btrim(name), ''), v_partname) into v_partname from public.profiles where id = v_partid;
  end if;

  if exists (select 1 from public.tournament_entries e
              where e.tournament_id = w.tournament_id and e.status <> 'withdrawn'
                and (e.player_id in (v_pid, v_partid) or e.partner_id in (v_pid, v_partid))) then
    return 'One of these players is already in this tournament.';
  end if;

  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status)
  values (w.tournament_id, v_pid, v_pname, v_partid, v_partname, 'registered')
  returning id into v_entry;

  update public.web_registrations
     set entry_id = v_entry, status = 'confirmed', updated_at = now()
   where id = w.id or id = v_other;

  -- Tell any linked account their results now count.
  select name into v_tname from public.tournaments where id = w.tournament_id;
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'tournament', 'You''re in the draw',
         'You''re entered in ' || coalesce(v_tname, 'the tournament')
           || '. Your results will count toward your level.',
         jsonb_build_object('tournament_id', w.tournament_id)
    from unnest(array[v_pid, v_partid]) uid
   where uid is not null;

  return null;
end $$;
revoke all on function public.admin_web_to_draw(uuid, uuid) from public;
grant execute on function public.admin_web_to_draw(uuid, uuid) to authenticated;

-- ── verify ──────────────────────────────────────────────────────────────────
-- select * from public.admin_web_registrations('<tournament id>');  -- as an admin
-- select name, phone, entry_id, status from public.web_registrations
--  order by created_at desc limit 10;
