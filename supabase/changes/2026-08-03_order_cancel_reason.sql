-- 2026-08-03 — Orders: say WHY a rejection happened.
--
-- Rejecting an InstaPay payment just set status='cancelled', and the
-- notify_order_status trigger sent every cancellation the same line:
--   "PD-XXXXXX was cancelled. Contact support if this is unexpected."
-- The player had no idea whether their transfer went astray, the item sold
-- out, or something else — and no word about money they had already sent.
--
-- Now the admin picks a reason (optionally with a note) and the player is
-- told, including a refund line when we are holding their money.
--
-- Safe to re-run.

alter table public.orders add column if not exists cancel_reason text;
alter table public.orders add column if not exists cancel_note   text;

-- The player-facing sentence for each reason code.
--
-- MIRRORS lib/backend/models/order_cancel_reason.dart (CancelReason.all) —
-- a trigger cannot call into Dart, so the copy lives in both places. Change
-- the wording in one, change it in the other.
create or replace function public._order_cancel_text(p_code text)
returns text language sql immutable as $$
  select case p_code
    when 'payment_not_received'  then 'We could not find your transfer in our account.'
    when 'payment_wrong_amount'  then 'The amount transferred did not match this order''s total.'
    when 'payment_unverifiable'  then 'The screenshot did not show a completed transfer we could match to this order.'
    when 'out_of_stock'          then 'An item in this order sold out before we could confirm it.'
    when 'address_issue'         then 'We could not deliver to the address on this order.'
    when 'duplicate'             then 'This looked like a duplicate of another order you placed.'
    when 'customer_request'      then 'Cancelled at your request.'
    else null
  end;
$$;

-- Reasons where we are holding money that has to go back. Only meaningful
-- for InstaPay orders — nothing is collected up front on cash-on-delivery.
create or replace function public._order_cancel_refunds(p_code text)
returns boolean language sql immutable as $$
  select p_code in ('payment_wrong_amount', 'out_of_stock',
                    'address_issue', 'duplicate', 'customer_request');
$$;

-- Recomposed cancellation/refund message. Every other status is unchanged.
create or replace function public.notify_order_status()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_title text;
  v_body  text;
  v_ref   text := public._order_ref(new.id);
  v_why   text;
begin
  case new.status
    when 'paid', 'confirmed' then
      v_title := 'Order confirmed';
      v_body  := v_ref || ' confirmed — we are preparing your order.';
    when 'shipped' then
      v_title := 'Out for delivery';
      v_body  := v_ref || ' is on its way to you.';
    when 'delivered' then
      v_title := 'Delivered';
      v_body  := v_ref || ' was delivered. Enjoy your gear!';
    when 'cancelled' then
      v_title := 'Order cancelled';
      -- Reason, then the admin's note, then the refund line where we owe.
      v_why := public._order_cancel_text(new.cancel_reason);
      if new.cancel_note is not null and btrim(new.cancel_note) <> '' then
        v_why := btrim(concat_ws(' ', v_why, btrim(new.cancel_note)));
      end if;
      if public._order_cancel_refunds(new.cancel_reason)
         and new.payment_method = 'instapay' then
        v_why := btrim(concat_ws(' ', v_why,
          'We will transfer your payment back to the InstaPay account you sent it from.'));
      end if;
      -- Falls back to the old wording for rows cancelled without a reason.
      v_body := v_ref || ' was cancelled. ' ||
                coalesce(nullif(v_why, ''), 'Contact support if this is unexpected.');
    when 'refunded' then
      v_title := 'Refund issued';
      v_why   := public._order_cancel_text(new.cancel_reason);
      if new.cancel_note is not null and btrim(new.cancel_note) <> '' then
        v_why := btrim(concat_ws(' ', v_why, btrim(new.cancel_note)));
      end if;
      v_body := v_ref || ' has been refunded.' ||
                coalesce(' ' || nullif(v_why, ''), '');
    else
      return new; -- no message for this transition
  end case;

  insert into public.notifications (user_id, type, title, body, data)
  values (new.player_id, 'order', v_title, v_body,
          jsonb_build_object('order_id', new.id, 'status', new.status));
  return new;
end $$;

drop trigger if exists trg_notify_order_status on public.orders;
create trigger trg_notify_order_status
  after update on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.notify_order_status();
