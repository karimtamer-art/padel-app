-- 2026-08-11 — Delete a DM thread. Safe to re-run.
--
-- Long-pressing a conversation in the Messages inbox offers "Delete chat".
--
-- IT DELETES YOUR COPY, NOT THE MESSAGES. Nothing is removed from
-- direct_messages; a row in conversation_clears records the moment you cleared
-- it, and every surface you see is filtered to messages newer than that. Three
-- reasons it works this way rather than actually deleting rows:
--
--   * The other person's thread is theirs. One side pressing delete must not
--     reach into the other side's inbox.
--   * Reports point AT messages (moderation targets 'dm_message' by id). If a
--     harasser could delete the thread they would be deleting the evidence
--     against them, from both sides, after being reported.
--   * It is what the gesture means everywhere else. WhatsApp, Instagram and
--     iMessage all clear your own copy.
--
-- If they message you again the thread comes back carrying only what was said
-- after the clear, which is the same behaviour.

create table if not exists public.conversation_clears (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  cleared_at      timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table public.conversation_clears enable row level security;

-- Your own row only. Nobody gets to learn that you cleared them.
drop policy if exists "conv clears: own read" on public.conversation_clears;
create policy "conv clears: own read" on public.conversation_clears
  for select using (user_id = auth.uid());

-- SELECT only, deliberately: clear_conversation() below is the sole writer, so
-- the participant check cannot be bypassed by writing the table directly (and
-- nobody can back-date someone else's cleared_at to hide messages from them).
grant select on public.conversation_clears to authenticated;

create or replace function public.clear_conversation(p_conversation uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not signed in.';
  end if;
  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and v_uid in (c.player_a, c.player_b)) then
    raise exception 'That conversation is not yours.';
  end if;

  insert into public.conversation_clears (conversation_id, user_id, cleared_at)
  values (p_conversation, v_uid, now())
  on conflict (conversation_id, user_id)
    do update set cleared_at = excluded.cleared_at;

  -- A thread you deleted must not keep its unread badge alive on Home.
  update public.notifications
     set read = true
   where user_id = v_uid
     and type = 'message'
     and read = false
     and data->>'conversation_id' = p_conversation::text;
end $$;
grant execute on function public.clear_conversation(uuid) to authenticated;

-- ── the inbox has to honour the clear ─────────────────────────────────────
-- Same columns as before (so `create or replace` is enough — no drop needed).
-- The only change is the conversation_clears join and the cleared_at filter
-- inside the lateral: `lm` stays an INNER join, so a conversation with nothing
-- newer than the clear produces no row and drops off the inbox entirely.
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
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
