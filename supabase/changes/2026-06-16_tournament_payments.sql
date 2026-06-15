-- ============================================================
-- Incremental change · 2026-06-16
-- Tournament entry payments (InstaPay) + refunds on withdrawal
-- ------------------------------------------------------------
-- Paid tournaments now collect an InstaPay transfer at registration (sender +
-- proof, admin-verified — same model as the store, NO card gateway). A paid
-- pair that withdraws BEFORE the start date is refund-eligible; withdrawing on
-- the start day or later forfeits the fee (enforced server-side). Free
-- tournaments (entry_fee 0) register straight through as before.
-- Also folded into the canonical migration. Idempotent.
-- ============================================================

-- 1) Per-entry payment + refund columns.
alter table public.tournament_entries add column if not exists paid_amount int;
alter table public.tournament_entries add column if not exists payment_method text;
alter table public.tournament_entries add column if not exists instapay_sender text;
alter table public.tournament_entries add column if not exists instapay_proof_url text;
alter table public.tournament_entries add column if not exists refund_status text not null default 'none';
alter table public.tournament_entries drop constraint if exists tournament_entries_refund_chk;
alter table public.tournament_entries add constraint tournament_entries_refund_chk
  check (refund_status in ('none', 'due', 'refunded'));

-- 2) Admins manage any entry (verify payment / process refund).
do $$ begin
  create policy "entries: admin write" on public.tournament_entries for update
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;

-- 3) Registration RPC: take InstaPay details and set the entry's status from
--    the fee (paid -> 'pending' holds the spot until an admin verifies; free ->
--    'registered'). Drop the old 3-arg overload so there's no ambiguity.
drop function if exists public.register_for_tournament(uuid, uuid, text);

create or replace function public.register_for_tournament(
  p_tournament_id      uuid,
  p_partner_id         uuid default null,
  p_partner_name       text default null,
  p_instapay_sender    text default null,
  p_instapay_proof_url text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid      uuid := auth.uid();
  v_status   text;
  v_start    date;
  v_cap      int;
  v_min      int;
  v_max      int;
  v_fee      int;
  v_count    int;
  v_my_elo   int;
  v_my_name  text;
  v_new      text;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, start_date, capacity, min_elo, max_elo, entry_fee
    into v_status, v_start, v_cap, v_min, v_max, v_fee
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
  where tournament_id = p_tournament_id
    and status <> 'withdrawn'
    and player_id <> v_uid;
  if v_cap > 0 and v_count >= v_cap then
    return 'This tournament is full.';
  end if;

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
  v_new := case when coalesce(v_fee, 0) > 0 then 'pending' else 'registered' end;

  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status,
     paid_amount, payment_method, instapay_sender, instapay_proof_url, refund_status)
  values (p_tournament_id, v_uid, v_my_name, p_partner_id, p_partner_name, v_new,
     case when coalesce(v_fee, 0) > 0 then v_fee else null end,
     case when coalesce(v_fee, 0) > 0 then 'instapay' else null end,
     p_instapay_sender, p_instapay_proof_url, 'none')
  on conflict (tournament_id, player_id) do update
    set player_name        = excluded.player_name,
        partner_id         = excluded.partner_id,
        partner_name       = excluded.partner_name,
        status             = excluded.status,
        paid_amount        = excluded.paid_amount,
        payment_method     = excluded.payment_method,
        instapay_sender    = excluded.instapay_sender,
        instapay_proof_url = excluded.instapay_proof_url,
        refund_status      = 'none';
  return null;
exception when others then
  return sqlerrm;
end $$;

grant execute on function
  public.register_for_tournament(uuid, uuid, text, text, text) to authenticated;

-- 4) Withdrawal RPC: enforce the refund rule server-side. Refund is due only if
--    money was put down (paid_amount > 0) AND withdrawing strictly before the
--    start date. Same-day or later forfeits.
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

-- 5) Notify the registrant when an admin confirms payment or processes a refund.
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

drop trigger if exists trg_notify_tournament_entry_update on public.tournament_entries;
create trigger trg_notify_tournament_entry_update
  after update on public.tournament_entries
  for each row execute function public.notify_tournament_entry_update();

notify pgrst, 'reload schema';
