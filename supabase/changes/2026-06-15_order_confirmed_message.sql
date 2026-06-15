-- ============================================================
-- Incremental change · 2026-06-15
-- Make the "order confirmed" notification method-agnostic
-- ------------------------------------------------------------
-- COD orders also reach status 'paid' when the admin accepts them, so the
-- buyer message must not say "payment confirmed" (they pay on delivery).
-- Replaces the trigger function body only. Also folded into the canonical
-- supabase/migration_player_app.sql. Idempotent (create or replace).
-- ============================================================

create or replace function public.notify_order_status()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_title text;
  v_body  text;
  v_ref   text := public._order_ref(new.id);
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
      v_body  := v_ref || ' was cancelled. Contact support if this is unexpected.';
    when 'refunded' then
      v_title := 'Refund issued';
      v_body  := v_ref || ' has been refunded.';
    else
      return new; -- no message for this transition
  end case;

  insert into public.notifications (user_id, type, title, body, data)
  values (new.player_id, 'order', v_title, v_body,
          jsonb_build_object('order_id', new.id, 'status', new.status));
  return new;
end $$;
