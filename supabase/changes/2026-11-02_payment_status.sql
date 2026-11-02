-- Payment status: a player always knows whether they are under review, confirmed or
-- need to act. NOT APPLIED. Tested on a stub only until live_schema.sql arrives.
--
-- Run AFTER: nothing here depends on the other 2 Nov deltas, and they don't touch these
-- functions. Run BEFORE shipping a build containing the new screens. Old builds keep
-- working: they read a 'rejected' entry as registered, and their one-tap reject still
-- writes status = 'withdrawn' directly.
--
-- Safe to re-run. ROLLBACK: supabase/rollbacks/2026-11-02_payment_status_rollback.sql

alter table public.tournament_entries drop constraint if exists tournament_entries_status_chk;
alter table public.tournament_entries add constraint tournament_entries_status_chk
  check (status in ('registered','withdrawn','confirmed','pending','paid','cancelled','rejected'));

-- ── Payment status (changes/2026-11-02_payment_status.sql) ─────────────────
-- 'rejected' is a real status: action needed, spot still held. Everything that counts
-- spots or asks "are they registered?" already means status <> 'withdrawn', so a held
-- pair keeps its spot and stays visible, and both draws whitelist their statuses, so it
-- stays out of the draw. Without a hold, or when the hold lapses, it becomes 'withdrawn'.
alter table public.tournament_entries add column if not exists hold_until timestamptz;
alter table public.tournament_entries add column if not exists proof_resubmitted_at timestamptz;

-- The reason lives here, not on tournament_entries: that table's read policy is
-- using (true), granted to anon too, so a note written for one pair would be public.
create table if not exists public.tournament_entry_rejections (
  entry_id uuid primary key references public.tournament_entries(id) on delete cascade,
  reason text not null,
  note text,
  money_received boolean not null default false,
  rejected_by uuid,
  rejected_at timestamptz not null default now()
);
alter table public.tournament_entry_rejections enable row level security;
revoke all on public.tournament_entry_rejections from public, anon, authenticated;
grant select on public.tournament_entry_rejections to authenticated;
drop policy if exists "rejections: own pair or organiser" on public.tournament_entry_rejections;
create policy "rejections: own pair or organiser" on public.tournament_entry_rejections
  for select to authenticated using (exists (
    select 1 from public.tournament_entries e
     where e.id = entry_id
       and (e.player_id = auth.uid() or e.partner_id = auth.uid()
            or public.owns_tournament(e.tournament_id))));

-- "Tue 3 Nov, 5:00 PM", in Cairo time.
create or replace function public._cairo_label(p_at timestamptz)
returns text language sql stable set search_path = public as $$
  select to_char(p_at at time zone 'Africa/Cairo', 'Dy FMDD Mon, FMHH12:MI AM');
$$;
revoke all on function public._cairo_label(timestamptz) from public, anon, authenticated;

-- Any move out of 'rejected' ends the hold. Being confirmed, or registering again after
-- being released, also clears the history. A resubmission keeps it, so the organiser
-- can still see what was wrong and whether money arrived.
create or replace function public._entry_reject_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from 'rejected' then new.hold_until := null; end if;
  if new.status in ('paid', 'confirmed', 'registered')
     or (old.status = 'withdrawn' and new.status <> 'withdrawn') then
    delete from public.tournament_entry_rejections where entry_id = new.id;
    new.proof_resubmitted_at := null;
  end if;
  return new;
end $$;
revoke all on function public._entry_reject_cleanup() from public, anon, authenticated;
drop trigger if exists trg_entry_reject_cleanup on public.tournament_entries;
create trigger trg_entry_reject_cleanup
  before update of status on public.tournament_entries
  for each row execute function public._entry_reject_cleanup();

-- Lapsed holds become 'withdrawn', with a refund flagged if money was logged. Called by
-- register_for_tournament and resubmit_payment_proof, and by pg_cron where available.
create or replace function public._release_expired_holds(p_tournament uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_name text;
begin
  for r in
    select e.id, e.tournament_id, e.player_id, e.partner_id,
           coalesce(x.money_received, false) as money
      from public.tournament_entries e
      left join public.tournament_entry_rejections x on x.entry_id = e.id
     where e.status = 'rejected' and e.hold_until is not null and e.hold_until <= now()
       and (p_tournament is null or e.tournament_id = p_tournament)
     for update of e skip locked
  loop
    update public.tournament_entries
       set status = 'withdrawn',
           refund_status = case when r.money then 'due' else 'none' end
     where id = r.id;
    select name into v_name from public.tournaments where id = r.tournament_id;
    insert into public.notifications (user_id, type, title, body, data)
    select who, 'tournament', 'Your spot was released',
           'We couldn''t verify your payment for ' || coalesce(v_name, 'the tournament') ||
             ' in time. You can register again if spots are left.',
           jsonb_build_object('tournament_id', r.tournament_id, 'entry_id', r.id)
      from (select r.player_id as who union select r.partner_id) w
     where who is not null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public._release_expired_holds(uuid) from public, anon, authenticated;

create or replace function public.reject_tournament_entry(
  p_entry_id uuid, p_reason text, p_note text,
  p_money_received boolean, p_hold_hours int)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_e public.tournament_entries%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_hold int := coalesce(p_hold_hours, 0);
  v_until timestamptz;
  v_tname text;
  v_body text;
begin
  select * into v_e from public.tournament_entries where id = p_entry_id for update;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_e.tournament_id) then return 'Not your tournament.'; end if;
  if v_e.status not in ('pending', 'rejected') then
    return 'Only a payment under review can be rejected.';
  end if;
  -- Mirrors kRejectReasons in lib/backend/models/tournament_payment.dart.
  if p_reason is null or p_reason not in
     ('Amount doesn''t match', 'Transfer not received', 'Screenshot unclear', 'Other') then
    return 'Pick a reason.';
  end if;
  if p_reason = 'Other' and v_note is null then
    return 'Add a note so the players know what to fix.';
  end if;
  if v_hold < 0 or v_hold > 168 then return 'A hold can be up to 7 days.'; end if;
  if v_hold > 0 then v_until := now() + v_hold * interval '1 hour'; end if;

  insert into public.tournament_entry_rejections
    (entry_id, reason, note, money_received, rejected_by, rejected_at)
  values (p_entry_id, p_reason, v_note, coalesce(p_money_received, false), auth.uid(), now())
  on conflict (entry_id) do update
    set reason = excluded.reason, note = excluded.note,
        money_received = excluded.money_received,
        rejected_by = excluded.rejected_by, rejected_at = excluded.rejected_at;

  if v_hold > 0 then
    -- The refund flag waits: they may yet fix it.
    update public.tournament_entries
       set status = 'rejected', hold_until = v_until where id = p_entry_id;
  else
    update public.tournament_entries
       set status = 'withdrawn',
           refund_status = case when coalesce(p_money_received, false) then 'due' else 'none' end
     where id = p_entry_id;
  end if;

  select name into v_tname from public.tournaments where id = v_e.tournament_id;
  v_body := coalesce(v_tname, 'Your tournament') || ': ' ||
    rtrim(case when p_reason = 'Other' then v_note
               else p_reason || coalesce('. ' || v_note, '') end, '. ') ||
    case when v_hold > 0
         then '. Your spot is held until ' || public._cairo_label(v_until) || ', send new proof to keep it.'
         else '. Your spot was released, you can register again if spots are left.' end;
  insert into public.notifications (user_id, type, title, body, data)
  select who, 'tournament', 'We couldn''t verify your payment', v_body,
         jsonb_build_object('tournament_id', v_e.tournament_id, 'entry_id', p_entry_id,
                            'action', 'fix_payment')
    from (select v_e.player_id as who union select v_e.partner_id) w
   where who is not null;
  return null;
end $$;
revoke all on function public.reject_tournament_entry(uuid, text, text, boolean, int) from public, anon;
grant execute on function public.reject_tournament_entry(uuid, text, text, boolean, int) to authenticated;

-- A player replaces their proof on the same entry, without withdrawing.
create or replace function public.resubmit_payment_proof(
  p_entry_id uuid, p_screenshot_path text, p_instapay_username text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_e public.tournament_entries%rowtype;
  v_split boolean;
  v_sender text := nullif(btrim(coalesce(p_instapay_username, '')), '');
  v_tname text; v_me text; v_org uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select * into v_e from public.tournament_entries where id = p_entry_id;
  if not found then return 'Registration not found.'; end if;
  if v_uid is distinct from v_e.player_id and v_uid is distinct from v_e.partner_id then
    return 'This isn''t your registration.';
  end if;
  perform public._release_expired_holds(v_e.tournament_id);
  select * into v_e from public.tournament_entries where id = p_entry_id for update;
  if v_e.status not in ('pending', 'rejected') then
    return case when v_e.status = 'withdrawn'
                then 'Your hold ended, so the spot was released. You can register again.'
                else 'This payment has already been decided.' end;
  end if;
  if v_sender is null then return 'Enter your InstaPay username.'; end if;
  -- Uploads go to proofs/<uid>/..., so this also stops pointing at someone else's file.
  if p_screenshot_path is null or p_screenshot_path not like 'proofs/' || v_uid::text || '/%' then
    return 'Attach your transfer screenshot.';
  end if;

  v_split := coalesce(v_e.fee_mode, 'both') = 'split';
  if v_split and v_uid = v_e.partner_id then
    if coalesce(v_e.partner_paid, false) then return 'Your share is already verified.'; end if;
    update public.tournament_entries
       set partner_instapay_sender = v_sender, partner_instapay_proof_url = p_screenshot_path,
           status = 'pending', proof_resubmitted_at = now()
     where id = p_entry_id;
  else
    if v_split and coalesce(v_e.payer_paid, false) then return 'Your share is already verified.'; end if;
    update public.tournament_entries
       set instapay_sender = v_sender, instapay_proof_url = p_screenshot_path,
           status = 'pending', proof_resubmitted_at = now()
     where id = p_entry_id;
  end if;

  select t.name, t.organizer_id into v_tname, v_org
    from public.tournaments t where t.id = v_e.tournament_id;
  select name into v_me from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  select who, 'admin_tournament', 'New payment proof, verify',
         coalesce(v_me, 'A player') || ' sent new proof for ' || coalesce(v_tname, 'a tournament') || '.',
         jsonb_build_object('tournament_id', v_e.tournament_id, 'entry_id', p_entry_id, 'admin', true)
    from (select v_org as who where v_org is not null
          union select p.id from public.profiles p where p.is_admin = true) r
   where who is not null;
  return null;
end $$;
revoke all on function public.resubmit_payment_proof(uuid, text, text) from public, anon;
grant execute on function public.resubmit_payment_proof(uuid, text, text) to authenticated;

do $$ begin
  perform cron.schedule('padel-release-holds', '*/10 * * * *',
    'select public._release_expired_holds()');
exception when others then
  raise notice 'pg_cron not available: holds are released when someone registers or resubmits.';
end $$;

-- ── Existing functions, edited ─────────────────────────────────────────────

create or replace function public.register_for_tournament(
  p_tournament_id      uuid,
  p_partner_id         uuid default null,
  p_partner_name       text default null,
  p_instapay_sender    text default null,
  p_instapay_proof_url text default null,
  p_fee_mode           text default 'both')
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_status text; v_start date; v_cap int; v_fee int;
  v_min numeric; v_max numeric; v_my_rating numeric;
  v_count  int; v_my_name text; v_new text;
  v_mode   text; v_pay int; v_tname text; v_eid uuid; v_reg_opens date;
  v_category text; v_my_gender text; v_partner_gender text;
  v_start_time text; v_reg_closed boolean; v_deadline timestamptz;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, start_date, capacity, min_rating, max_rating, entry_fee, name, registration_opens, category,
         start_time, coalesce(registration_closed, false)
    into v_status, v_start, v_cap, v_min, v_max, v_fee, v_tname, v_reg_opens, v_category,
         v_start_time, v_reg_closed
  from public.tournaments where id = p_tournament_id;
  if not found then return 'Tournament not found.'; end if;
  if v_status = 'cancelled' then
    return 'Registration is closed — this tournament has been cancelled.';
  end if;
  if v_reg_opens is not null and current_date < v_reg_opens then
    return 'Registration hasn''t opened for this tournament yet.';
  end if;
  if v_reg_closed then
    return 'Registration for this tournament has been closed by the organizer.';
  end if;
  -- Sign-ups run until 1 hour before the start time — NOT until midnight of the
  -- start day, which used to lock out same-day events before anyone woke up.
  v_deadline := public.tournament_reg_deadline(v_start, v_start_time);
  if v_deadline is not null and now() >= v_deadline then
    return 'Registration is closed — it stops 1 hour before the tournament starts.';
  end if;

  -- A hold that has lapsed gives its spot back before we count (no pg_cron needed).
  perform public._release_expired_holds(p_tournament_id);

  -- capacity (ignore withdrawn; an existing row for this user is a re-register)
  select count(*) into v_count
  from public.tournament_entries
  where tournament_id = p_tournament_id and status <> 'withdrawn' and player_id <> v_uid;
  if v_cap > 0 and v_count >= v_cap then return 'This tournament is full.'; end if;

  -- eligibility
  if v_min > 0 or (v_max is not null and v_max > 0) then
    -- An unrated player is judged at the engine's own prior, not at zero:
    -- profiles.rating is NULL until placement completes, and treating that as
    -- 0.0 would silently bar every new player from every levelled event.
    select coalesce(rating, public.rating_prior()) into v_my_rating
      from public.player_ratings where player_id = v_uid;
    if v_min > 0 and v_my_rating < v_min then
      return 'This event has a minimum level you haven''t reached yet.';
    end if;
    if v_max is not null and v_max > 0 and v_my_rating > v_max then
      return 'Your level is above the maximum for this event.';
    end if;
  end if;

  -- Gender category. Partner gender is only known for a real app user (guest
  -- partners added by the organizer skip this — the organizer vouches for them).
  if coalesce(v_category, 'open') <> 'open' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    if p_partner_id is not null then
      select gender into v_partner_gender from public.profiles where id = p_partner_id;
    end if;
    if v_category = 'mens' then
      if v_my_gender is distinct from 'male'
         or (p_partner_id is not null and v_partner_gender is distinct from 'male') then
        return 'This is a men''s-only event — both players must be men.';
      end if;
    elsif v_category = 'womens' then
      if v_my_gender is distinct from 'female'
         or (p_partner_id is not null and v_partner_gender is distinct from 'female') then
        return 'This is a women''s-only event — both players must be women.';
      end if;
    elsif v_category = 'mixed' then
      if v_my_gender = 'male' and p_partner_id is not null and v_partner_gender = 'male' then
        return 'Mixed event — a team can''t be two men.';
      end if;
    end if;
  end if;

  select name into v_my_name from public.profiles where id = v_uid;

  -- No partner to collect from → registrant covers the whole entry.
  v_mode := case when p_partner_id is null then 'both'
                 else coalesce(nullif(p_fee_mode, ''), 'both') end;
  if v_mode not in ('both', 'split') then v_mode := 'both'; end if;

  v_new := case when coalesce(v_fee, 0) > 0 then 'pending' else 'registered' end;
  v_pay := case when coalesce(v_fee, 0) <= 0 then null
                when v_mode = 'split' then v_fee
                else v_fee * 2 end;

  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status,
     paid_amount, payment_method, instapay_sender, instapay_proof_url, refund_status,
     fee_mode, payer_paid, partner_paid, partner_instapay_sender, partner_instapay_proof_url)
  values (p_tournament_id, v_uid, v_my_name, p_partner_id, p_partner_name, v_new,
     v_pay, case when coalesce(v_fee, 0) > 0 then 'instapay' else null end,
     p_instapay_sender, p_instapay_proof_url, 'none',
     case when coalesce(v_fee, 0) > 0 then v_mode else null end,
     false, false, null, null)
  on conflict (tournament_id, player_id) do update
    set player_name        = excluded.player_name,
        partner_id         = excluded.partner_id,
        partner_name       = excluded.partner_name,
        status             = excluded.status,
        paid_amount        = excluded.paid_amount,
        payment_method     = excluded.payment_method,
        instapay_sender    = excluded.instapay_sender,
        instapay_proof_url = excluded.instapay_proof_url,
        refund_status      = 'none',
        fee_mode           = excluded.fee_mode,
        payer_paid         = false,
        partner_paid       = false,
        partner_instapay_sender    = null,
        partner_instapay_proof_url = null
  returning id into v_eid;

  -- Tailored partner notification for PAID events.
  if coalesce(v_fee, 0) > 0 and p_partner_id is not null and p_partner_id <> v_uid then
    if v_mode = 'split' then
      insert into public.notifications (user_id, type, title, body, data)
      values (p_partner_id, 'tournament', 'Pay your share to lock your spot',
              coalesce(v_my_name, 'Your partner') || ' registered you for ' ||
                coalesce(v_tname, 'a tournament') || '. Pay your EGP ' || v_fee ||
                ' share to confirm your spot.',
              jsonb_build_object('tournament_id', p_tournament_id, 'entry_id', v_eid,
                                 'action', 'pay_share'));
    else
      insert into public.notifications (user_id, type, title, body, data)
      values (p_partner_id, 'tournament',
              coalesce(split_part(v_my_name, ' ', 1), 'Your partner') ||
                ' registered you, payment under review',
              'You''ll be confirmed for ' || coalesce(v_tname, 'the tournament') ||
                ' once an organiser verifies the transfer.',
              jsonb_build_object('tournament_id', p_tournament_id, 'entry_id', v_eid));
    end if;
  end if;

  return null;
exception when others then
  return sqlerrm;
end $$;
grant execute on function
  public.register_for_tournament(uuid, uuid, text, text, text, text) to authenticated;

create or replace function public.verify_entry_share(p_entry_id uuid, p_which text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_tid uuid; v_mode text; v_partner uuid;
  v_payer boolean; v_partnerpaid boolean; v_full boolean;
  v_player uuid; v_pname text; v_partname text; v_was boolean;
  v_done_id uuid; v_wait_id uuid; v_done text; v_wait text;
begin
  select tournament_id, fee_mode, partner_id, payer_paid, partner_paid,
         player_id, player_name, partner_name
    into v_tid, v_mode, v_partner, v_payer, v_partnerpaid,
         v_player, v_pname, v_partname
    from public.tournament_entries where id = p_entry_id;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_tid) then return 'Not your tournament.'; end if;

  v_was := case p_which when 'payer' then coalesce(v_payer, false)
                        else coalesce(v_partnerpaid, false) end;
  if p_which = 'payer' then
    v_payer := true;
    if coalesce(v_mode, 'both') <> 'split' then v_partnerpaid := true; end if;
  elsif p_which = 'partner' then
    v_partnerpaid := true;
  else
    return 'Unknown payment share.';
  end if;

  v_full := v_payer and (v_partnerpaid
                         or coalesce(v_mode, 'both') <> 'split'
                         or v_partner is null);

  update public.tournament_entries
     set payer_paid   = v_payer,
         partner_paid = v_partnerpaid,
         status       = case when v_full then 'paid' else 'pending' end
   where id = p_entry_id;

  -- One share of a split: the status doesn't change, so the confirmation trigger
  -- stays quiet. Both players still need to know where they stand.
  if not v_full and not v_was then
    if p_which = 'payer' then
      v_done_id := v_player;  v_done := v_pname;
      v_wait_id := v_partner; v_wait := v_partname;
    else
      v_done_id := v_partner; v_done := v_partname;
      v_wait_id := v_player;  v_wait := v_pname;
    end if;
    v_done := coalesce(nullif(split_part(coalesce(v_done, ''), ' ', 1), ''), 'Your partner');
    v_wait := coalesce(nullif(split_part(coalesce(v_wait, ''), ' ', 1), ''), 'your partner');
    if v_wait_id is not null then
      insert into public.notifications (user_id, type, title, body, data)
      values (v_wait_id, 'tournament', v_done || '''s share is verified',
              v_done || '''s share is verified, waiting for yours.',
              jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id,
                                 'action', 'share_verified'));
    end if;
    if v_done_id is not null then
      insert into public.notifications (user_id, type, title, body, data)
      values (v_done_id, 'tournament', 'Your share is verified',
              'Your share is verified, waiting for ' || v_wait || '''s.',
              jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id,
                                 'action', 'share_verified'));
    end if;
  end if;
  return null;
end $$;
grant execute on function public.verify_entry_share(uuid, text) to authenticated;

create or replace function public.withdraw_from_tournament(p_tournament_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_start  date;
  v_entry  public.tournament_entries%rowtype;
  v_refund text := 'none';
  v_money  boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select start_date into v_start from public.tournaments where id = p_tournament_id;
  select * into v_entry from public.tournament_entries
    where tournament_id = p_tournament_id and player_id = v_uid;
  if not found then return 'You are not registered for this tournament.'; end if;
  if v_entry.status = 'withdrawn' then return null; end if;

  if v_entry.status = 'rejected' then
    select money_received into v_money
      from public.tournament_entry_rejections where entry_id = v_entry.id;
    if coalesce(v_money, false) then v_refund := 'due'; end if;
  elsif coalesce(v_entry.paid_amount, 0) > 0
     and (v_start is null or current_date < v_start) then
    v_refund := 'due';
  end if;

  update public.tournament_entries
    set status = 'withdrawn', refund_status = v_refund
    where id = v_entry.id;
  -- They chose to leave: no "your payment wasn't verified" banner afterwards.
  delete from public.tournament_entry_rejections where entry_id = v_entry.id;
  return null;
exception when others then
  return sqlerrm;
end $$;
grant execute on function public.withdraw_from_tournament(uuid) to authenticated;

create or replace function public.notify_tournament_entry_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text; v_title text; v_body text; v_start date; v_time text;
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    select name, start_date, start_time into v_name, v_start, v_time
      from public.tournaments where id = new.tournament_id;
    v_title := 'You''re confirmed for ' || coalesce(v_name, 'the tournament');
    v_body := 'Payment verified.' || case when v_start is null then '' else
      ' See you ' || to_char(v_start, 'Dy FMDD Mon') ||
      coalesce(', ' || nullif(btrim(v_time), ''), '') || '.' end;
    insert into public.notifications (user_id, type, title, body, data)
    values (new.player_id, 'tournament', v_title, v_body,
            jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
    if new.partner_id is not null and new.partner_id <> new.player_id then
      insert into public.notifications (user_id, type, title, body, data)
      values (new.partner_id, 'tournament', v_title, v_body,
              jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
    end if;
  end if;
  if new.refund_status = 'refunded' and old.refund_status is distinct from 'refunded' then
    select name into v_name from public.tournaments where id = new.tournament_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (new.player_id, 'tournament', 'Refund processed',
            'Your entry fee for ' || coalesce(v_name, 'the tournament') ||
              ' has been refunded.',
            jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
  end if;
  return new;
end $$;

-- ── VERIFY: every row should say ok = true ──────────────────────────────────
select 'rejected is an allowed status' as check_name,
       pg_get_constraintdef(oid) like '%rejected%' as ok, conname::text as detail
  from pg_constraint where conname = 'tournament_entries_status_chk'
union all
select 'reason table is closed to anon',
       not has_table_privilege('anon', 'public.tournament_entry_rejections', 'select'),
       'anon cannot read a rejection note'
union all
select 'reason table can only be read by signed-in users',
       not has_table_privilege('authenticated', 'public.tournament_entry_rejections', 'insert'),
       'no client can write a rejection directly'
union all
select 'closed: ' || f, not has_function_privilege('anon', f, 'execute')
         and not has_function_privilege('authenticated', f, 'execute'), 'internal'
  from unnest(array['public._release_expired_holds(uuid)', 'public._entry_reject_cleanup()',
                    'public._cairo_label(timestamptz)']) f
union all
select 'signed-in only: ' || f, not has_function_privilege('anon', f, 'execute')
         and has_function_privilege('authenticated', f, 'execute'), 'RPC'
  from unnest(array['public.reject_tournament_entry(uuid, text, text, boolean, int)',
                    'public.resubmit_payment_proof(uuid, text, text)']) f
union all
select 'confirmation copy is live',
       pg_get_functiondef('public.notify_tournament_entry_update()'::regprocedure) like '%Payment verified%',
       'notify_tournament_entry_update'
union all
select 'partner is no longer told the entry is paid',
       pg_get_functiondef('public.register_for_tournament(uuid, uuid, text, text, text, text)'::regprocedure)
         not like '%your entry is paid%',
       'register_for_tournament';
