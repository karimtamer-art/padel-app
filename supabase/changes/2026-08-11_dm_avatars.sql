-- 2026-08-11 — Show the other person's photo in Messages. Safe to re-run.
--
-- dm_inbox returned name + username but no avatar, so every row in the
-- Messages list drew initials even when the player had a photo.
--
-- ADDS A COLUMN, so the drop is mandatory: `create or replace` cannot change a
-- function's return type and would fail with 42P13 (exactly how re-running the
-- migration died on ticket_roster). Because of that drop this file MUST run
-- after 2026-08-11_delete_chat.sql, not before — it carries that delta's
-- conversation_clears filter forward, and running them the other way round
-- would leave the older body in place and un-delete every cleared thread.

drop function if exists public.dm_inbox();
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  other_avatar    text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
         other.avatar_url,
         lm.text,
         lm.sent_at,
         coalesce((
           select count(*)::int from public.notifications n
            where n.user_id = auth.uid()
              and n.type = 'message'
              and n.read = false
              and n.data->>'conversation_id' = c.id::text), 0)
    from public.conversations c
    join public.profiles other
      on other.id = case when c.player_a = auth.uid() then c.player_b else c.player_a end
    left join public.conversation_clears cl
      on cl.conversation_id = c.id and cl.user_id = auth.uid()
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
         and (cl.cleared_at is null or dm.sent_at > cl.cleared_at)
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
     and not public._blocked_with(other.id)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;
