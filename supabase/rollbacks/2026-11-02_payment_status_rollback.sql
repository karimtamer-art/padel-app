-- ROLLBACK of 2026-11-02_payment_status.sql. Anyone in the 'rejected' state becomes
-- withdrawn (with a refund flagged if money was logged), and every reason is deleted, so
-- read the list first:
--   select e.id, e.player_name, x.reason, x.note, x.money_received
--     from public.tournament_entries e
--     left join public.tournament_entry_rejections x on x.entry_id = e.id
--    where e.status = 'rejected';

do $$ begin perform cron.unschedule('padel-release-holds');
exception when others then null; end $$;

drop trigger if exists trg_entry_reject_cleanup on public.tournament_entries;
update public.tournament_entries e
   set status = 'withdrawn',
       refund_status = case when coalesce((select x.money_received
         from public.tournament_entry_rejections x where x.entry_id = e.id), false)
         then 'due' else 'none' end
 where e.status = 'rejected';

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
      values (p_partner_id, 'tournament', 'You''re in — your entry is paid',
              coalesce(v_my_name, 'Your partner') || ' paid your entry for ' ||
                coalesce(v_tname, 'a tournament') || '. You''re registered together!',
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
begin
  select tournament_id, fee_mode, partner_id, payer_paid, partner_paid
    into v_tid, v_mode, v_partner, v_payer, v_partnerpaid
    from public.tournament_entries where id = p_entry_id;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_tid) then return 'Not your tournament.'; end if;

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
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select start_date into v_start from public.tournaments where id = p_tournament_id;
  select * into v_entry from public.tournament_entries
    where tournament_id = p_tournament_id and player_id = v_uid;
  if not found then return 'You are not registered for this tournament.'; end if;
  if v_entry.status = 'withdrawn' then return null; end if;

  if coalesce(v_entry.paid_amount, 0) > 0
     and (v_start is null or current_date < v_start) then
    v_refund := 'due';
  end if;

  update public.tournament_entries
    set status = 'withdrawn', refund_status = v_refund
    where id = v_entry.id;
  return null;
exception when others then
  return sqlerrm;
end $$;
grant execute on function public.withdraw_from_tournament(uuid) to authenticated;

create or replace function public.notify_tournament_entry_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    select name into v_name from public.tournaments where id = new.tournament_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (new.player_id, 'tournament', 'Tournament payment confirmed',
            'You''re confirmed in ' || coalesce(v_name, 'the tournament') || '.',
            jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
    if new.partner_id is not null and new.partner_id <> new.player_id then
      insert into public.notifications (user_id, type, title, body, data)
      values (new.partner_id, 'tournament', 'Tournament payment confirmed',
              'You''re confirmed in ' || coalesce(v_name, 'the tournament') || '.',
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

drop function if exists public.reject_tournament_entry(uuid, text, text, boolean, int);
drop function if exists public.resubmit_payment_proof(uuid, text, text);
drop function if exists public._release_expired_holds(uuid);
drop function if exists public._entry_reject_cleanup();
drop function if exists public._cairo_label(timestamptz);
drop table if exists public.tournament_entry_rejections;
alter table public.tournament_entries drop column if exists hold_until;
alter table public.tournament_entries drop column if exists proof_resubmitted_at;
alter table public.tournament_entries drop constraint if exists tournament_entries_status_chk;
alter table public.tournament_entries add constraint tournament_entries_status_chk
  check (status in ('registered','withdrawn','confirmed','pending','paid','cancelled'));
