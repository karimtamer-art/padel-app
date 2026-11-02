-- Copy only: a partner is no longer told their entry is paid while it is still under
-- review. Nothing else in register_for_tournament changes. NOT APPLIED.
-- Superseded by 2026-11-02_payment_status.sql, which keeps the same wording.
-- ROLLBACK: 2026-11-02_partner_notification_copy_rollback.sql

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

-- VERIFY: ok = true
select 'partner is no longer told the entry is paid' as check_name,
       pg_get_functiondef('public.register_for_tournament(uuid, uuid, text, text, text, text)'::regprocedure)
         not like '%your entry is paid%' as ok,
       'register_for_tournament' as detail;
