-- ============================================================================
-- 2026-07-29 — Per-player (split) tournament entry payment
--
-- Entry fee is now PER PLAYER. A pair pays 2× the fee. When registering for a
-- paid event, the registrant chooses:
--   • 'both'  — pay the whole pair (2× fee); partner is notified they're in.
--   • 'split' — pay only their own share (1× fee); partner is notified to pay
--               theirs. The spot is reserved (pending) on the first payment;
--               the entry becomes 'paid' only once BOTH shares are verified.
--
-- Per-share tracking lives on the single pair entry row:
--   fee_mode, payer_paid, partner_paid, partner_instapay_sender/proof.
--
-- Safe to re-run. After: notify pgrst, 'reload schema';
-- ============================================================================

alter table public.tournament_entries add column if not exists fee_mode text;               -- 'both' | 'split'
alter table public.tournament_entries add column if not exists payer_paid   boolean not null default false;
alter table public.tournament_entries add column if not exists partner_paid boolean not null default false;
alter table public.tournament_entries add column if not exists partner_instapay_sender    text;
alter table public.tournament_entries add column if not exists partner_instapay_proof_url text;

-- The generic "Added to a tournament" partner notification is for FREE events
-- only now; paid events get a tailored pay/you're-in message from the register
-- RPC below.
create or replace function public.notify_tournament_partner()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text; v_fee int;
begin
  if new.partner_id is null or new.partner_id = new.player_id then
    return new;
  end if;
  select name, coalesce(entry_fee, 0) into v_name, v_fee
    from public.tournaments where id = new.tournament_id;
  if coalesce(v_fee, 0) > 0 then
    return new; -- paid event: register_for_tournament sends the tailored message
  end if;
  insert into public.notifications (user_id, type, title, body, data)
  values (new.partner_id, 'tournament', 'Added to a tournament',
          'You''re entered in ' || coalesce(v_name, 'a tournament') || ' as a partner.',
          jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
  return new;
end $$;

-- Registration now records the fee mode + notifies the partner accordingly.
drop function if exists public.register_for_tournament(uuid, uuid, text, text, text);
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
  v_status text; v_start date; v_cap int; v_min int; v_max int; v_fee int;
  v_count  int; v_my_elo int; v_my_name text; v_new text;
  v_mode   text; v_pay int; v_tname text; v_eid uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, start_date, capacity, min_elo, max_elo, entry_fee, name
    into v_status, v_start, v_cap, v_min, v_max, v_fee, v_tname
  from public.tournaments where id = p_tournament_id;
  if not found then return 'Tournament not found.'; end if;
  if v_status = 'cancelled' then
    return 'Registration is closed — this tournament has been cancelled.';
  end if;
  if v_start is not null and v_start <= current_date then
    return 'Registration is closed — this tournament has already started.';
  end if;

  select count(*) into v_count
  from public.tournament_entries
  where tournament_id = p_tournament_id and status <> 'withdrawn' and player_id <> v_uid;
  if v_cap > 0 and v_count >= v_cap then return 'This tournament is full.'; end if;

  if v_min > 0 or (v_max is not null and v_max > 0) then
    select coalesce(elo, 1000) into v_my_elo from public.profiles where id = v_uid;
    if v_min > 0 and v_my_elo < v_min then
      return 'This event has a minimum level you haven''t reached yet.';
    end if;
    if v_max is not null and v_max > 0 and v_my_elo > v_max then
      return 'Your level is above the maximum for this event.';
    end if;
  end if;

  select name into v_my_name from public.profiles where id = v_uid;

  -- No partner to collect from → the registrant must cover the whole entry.
  v_mode := case when p_partner_id is null then 'both'
                 else coalesce(nullif(p_fee_mode, ''), 'both') end;
  if v_mode not in ('both', 'split') then v_mode := 'both'; end if;

  v_new := case when coalesce(v_fee, 0) > 0 then 'pending' else 'registered' end;
  -- What the registrant is paying right now.
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

-- The PARTNER submits their own share (split mode).
create or replace function public.pay_partner_share(
  p_entry_id uuid, p_instapay_sender text, p_instapay_proof_url text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_tid uuid; v_player uuid; v_partner uuid; v_mode text; v_status text;
  v_fee int; v_tname text; v_pname text; v_org uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select e.tournament_id, e.player_id, e.partner_id, e.fee_mode, e.status,
         coalesce(t.entry_fee, 0), t.name, t.organizer_id
    into v_tid, v_player, v_partner, v_mode, v_status, v_fee, v_tname, v_org
    from public.tournament_entries e
    join public.tournaments t on t.id = e.tournament_id
   where e.id = p_entry_id;
  if not found then return 'Registration not found.'; end if;
  if v_partner is null or v_partner <> v_uid then
    return 'This isn''t your registration to pay for.';
  end if;
  if v_status in ('withdrawn', 'cancelled') then
    return 'This registration is no longer active.';
  end if;
  if v_fee <= 0 then return 'This is a free event.'; end if;
  if coalesce(v_mode, 'both') <> 'split' then
    return 'Your partner already covered the full entry — nothing to pay.';
  end if;

  update public.tournament_entries
     set partner_instapay_sender    = p_instapay_sender,
         partner_instapay_proof_url = p_instapay_proof_url,
         status = case when status = 'withdrawn' then status else 'pending' end
   where id = p_entry_id;

  select name into v_pname from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_player, 'tournament', 'Your partner paid their share',
          coalesce(v_pname, 'Your partner') || ' paid their share for ' ||
            coalesce(v_tname, 'the tournament') || '. Waiting on the organizer to confirm.',
          jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id));

  -- Tell the organizer (+ admins) a partner share landed and needs verifying.
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'admin_tournament', 'Partner share paid — verify',
         coalesce(v_pname, 'A partner') || ' paid their EGP ' || v_fee ||
           ' share for ' || coalesce(v_tname, 'a tournament') || '.',
         jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id, 'admin', true)
  from (select v_org as uid where v_org is not null
        union select p.id from public.profiles p where p.is_admin = true) r
  where uid is not null;
  return null;
end $$;
grant execute on function public.pay_partner_share(uuid, text, text) to authenticated;

-- New-entry payment alert now goes to the OWNING ORGANIZER (+ admins) and states
-- which option the registrant chose (own share vs the full pair).
create or replace function public.notify_admins_tournament_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text; v_org uuid; v_body text; v_partner text;
begin
  if new.status <> 'pending' or coalesce(new.payment_method, '') <> 'instapay' then
    return new;
  end if;
  select name, organizer_id into v_name, v_org
    from public.tournaments where id = new.tournament_id;
  v_partner := coalesce(nullif(btrim(new.partner_name), ''), 'their partner');
  if coalesce(new.fee_mode, 'both') = 'split' then
    v_body := coalesce(new.player_name, 'A player') || ' paid their EGP ' ||
              coalesce(new.paid_amount, 0)::text || ' share for ' ||
              coalesce(v_name, 'a tournament') || ' — ' || v_partner ||
              ' still needs to pay theirs.';
  else
    v_body := coalesce(new.player_name, 'A player') || ' paid the full EGP ' ||
              coalesce(new.paid_amount, 0)::text || ' pair entry for ' ||
              coalesce(v_name, 'a tournament') || ' (covering ' || v_partner || ').';
  end if;
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'admin_tournament', 'Tournament payment to verify', v_body,
         jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id, 'admin', true)
  from (select v_org as uid where v_org is not null
        union select p.id from public.profiles p where p.is_admin = true) r
  where uid is not null;
  return new;
end $$;

-- Organizer/admin verifies ONE share of a pair entry. The entry flips to 'paid'
-- only when the pair is fully covered.
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

-- Also notify the PARTNER (not just the registrant) when the pair is confirmed.
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

notify pgrst, 'reload schema';
