-- ============================================================================
-- 2026-07-30 — Notify entrants on postpone / cancel
--
-- When an organizer marks a tournament Postponed or Cancelled, every registered
-- player (registrant + partner) gets a notification: postponed → "postponed to
-- <new date>", cancelled → "cancelled" (+ optional reason). Fires only on the
-- status transition, so editing/re-saving a cancelled event doesn't re-notify.
--
-- Safe to re-run. After: notify pgrst, 'reload schema';
-- ============================================================================

alter table public.tournaments add column if not exists cancel_reason text;

create or replace function public.notify_tournament_status_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_title text; v_body text; v_notify boolean := false;
begin
  -- Cancelled: on the transition into cancelled. Postponed: on entering postponed
  -- OR while already postponed if the start date moves again (re-postpone).
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    v_notify := true;
  elsif new.status = 'postponed'
        and (old.status is distinct from 'postponed'
             or new.start_date is distinct from old.start_date) then
    v_notify := true;
  end if;
  if not v_notify then return new; end if;

  select array_agg(distinct uid) into v_ids from (
    select player_id  uid from public.tournament_entries
      where tournament_id = new.id and status <> 'withdrawn' and player_id  is not null
    union
    select partner_id     from public.tournament_entries
      where tournament_id = new.id and status <> 'withdrawn' and partner_id is not null
  ) u;
  if v_ids is null or array_length(v_ids, 1) is null then return new; end if;

  if new.status = 'cancelled' then
    v_title := 'Tournament cancelled';
    v_body  := coalesce(new.name, 'A tournament') || ' has been cancelled.'
             || case when nullif(btrim(coalesce(new.cancel_reason, '')), '') is not null
                     then ' Reason: ' || btrim(new.cancel_reason) else '' end;
  else
    v_title := 'Tournament postponed';
    v_body  := coalesce(new.name, 'A tournament') || ' has been postponed'
             || case when new.start_date is not null
                     then ' to ' || to_char(new.start_date, 'Mon DD') else '' end || '.';
  end if;

  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'tournament', v_title, v_body,
         jsonb_build_object('tournament_id', new.id)
    from unnest(v_ids) as uid;
  return new;
end $$;

drop trigger if exists trg_notify_tournament_status_change on public.tournaments;
create trigger trg_notify_tournament_status_change
  after update on public.tournaments
  for each row execute function public.notify_tournament_status_change();

notify pgrst, 'reload schema';
