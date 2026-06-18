-- ============================================================
-- SKETCH (do not run as-is) · Phone ping to the admin on new order
-- Telegram via pg_net — NO Edge Function, NO app push needed.
-- ------------------------------------------------------------
-- This is the lowest-effort "buzz my phone" for a single admin: a Postgres
-- trigger that POSTs to the Telegram Bot API whenever an order is placed.
-- Works regardless of iOS signing/TrollStore because the alert lands in
-- Telegram, an app you already trust. Invisible to regular users.
--
-- One-time setup:
--   1. In Telegram, message @BotFather -> /newbot -> copy the BOT TOKEN.
--   2. Send any message to your new bot, then open
--      https://api.telegram.org/bot<TOKEN>/getUpdates and copy your CHAT ID
--      (result[].message.chat.id).
--   3. Replace <BOT_TOKEN> and <CHAT_ID> below. For production, store them in
--      Supabase Vault and read via vault.decrypted_secrets instead of inlining.
-- ============================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.ping_admin_telegram()
returns trigger language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_ref  text := public._order_ref(new.id);
  v_text text;
begin
  v_text := '🟢 New order ' || v_ref || E'\n'
         || 'Method: ' || coalesce(new.payment_method, 'cod') || E'\n'
         || 'Total: EGP ' || coalesce(new.total, 0)::text || E'\n'
         || 'Status: ' || coalesce(new.status, 'pending') || ' — needs confirmation';

  perform net.http_post(
    url     := 'https://api.telegram.org/bot<BOT_TOKEN>/sendMessage',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object('chat_id', '<CHAT_ID>', 'text', v_text)
  );
  return new;
end $$;

drop trigger if exists trg_ping_admin_telegram on public.orders;
create trigger trg_ping_admin_telegram
  after insert on public.orders
  for each row execute function public.ping_admin_telegram();

-- Notes:
--  • pg_net fires the HTTP call asynchronously, so a Telegram outage never
--    blocks/checks the order insert.
--  • To ping on status changes too, add an AFTER UPDATE trigger guarded by
--    (old.status is distinct from new.status), like notify_order_status.
--  • Multiple admins: loop chat_ids, or just use a Telegram group chat id.
