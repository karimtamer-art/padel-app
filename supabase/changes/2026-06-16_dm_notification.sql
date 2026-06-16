-- ============================================================
-- Incremental change · 2026-06-16
-- Notify the recipient of a new direct message (bell badge)
-- ------------------------------------------------------------
-- On each message, notify the OTHER participant (type 'message'). To avoid
-- flooding the inbox, an existing UNREAD 'message' notification for the same
-- conversation is bumped (body + time updated) instead of inserting a new row —
-- so it behaves like a WhatsApp-style "one row per chat, latest preview".
-- The chat screen marks these read on open. Also in the canonical migration.
-- ============================================================

create or replace function public.notify_new_dm()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_recipient uuid;
  v_sender    text;
begin
  select case when c.player_a = new.sender_id then c.player_b else c.player_a end
    into v_recipient
  from public.conversations c where c.id = new.conversation_id;
  if v_recipient is null or v_recipient = new.sender_id then return new; end if;

  select name into v_sender from public.profiles where id = new.sender_id;

  if exists (
    select 1 from public.notifications n
    where n.user_id = v_recipient and n.type = 'message' and n.read = false
      and n.data->>'conversation_id' = new.conversation_id::text
  ) then
    update public.notifications
      set title = coalesce(v_sender, 'New message'),
          body = left(new.text, 80),
          created_at = now()
    where user_id = v_recipient and type = 'message' and read = false
      and data->>'conversation_id' = new.conversation_id::text;
  else
    insert into public.notifications (user_id, type, title, body, data)
    values (v_recipient, 'message',
            coalesce(v_sender, 'New message'),
            left(new.text, 80),
            jsonb_build_object('conversation_id', new.conversation_id,
                               'sender_id', new.sender_id));
  end if;
  return new;
end $$;

drop trigger if exists trg_notify_new_dm on public.direct_messages;
create trigger trg_notify_new_dm
  after insert on public.direct_messages
  for each row execute function public.notify_new_dm();

notify pgrst, 'reload schema';
