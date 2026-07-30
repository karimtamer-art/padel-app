-- 2026-07-30 — Messages inbox + community channel unread badges
-- Run this whole file on the live DB (idempotent; safe to re-run).
--
-- 1) dm_inbox(): every DM conversation the caller is in that has at least one
--    message — with the other player, the last message, and an unread count
--    (derived from the existing type='message' notifications).
-- 2) community_reads + mark_community_read()/community_unread_count(): a per
--    (player, community) last-read cursor so the Home community card can show a
--    red badge when the community channels have new messages.

-- ── 1. Direct-message inbox ──────────────────────────────────────────────
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
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- ── 2. Community channel read cursor + unread count ──────────────────────
create table if not exists public.community_reads (
  player_id    uuid not null references public.profiles(id)    on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (player_id, community_id)
);
alter table public.community_reads enable row level security;
do $$ begin
  create policy "community_reads: self" on public.community_reads
    for all using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select, insert, update on public.community_reads to authenticated;

-- Mark a community's channels read up to now (called when the Chat tab opens).
create or replace function public.mark_community_read(p_community_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.community_reads (player_id, community_id, last_read_at)
  values (auth.uid(), p_community_id, now())
  on conflict (player_id, community_id)
  do update set last_read_at = excluded.last_read_at;
$$;
grant execute on function public.mark_community_read(uuid) to authenticated;

-- Count channel messages newer than the caller's last-read cursor (or, if they
-- never opened it, newer than when they joined) — excluding their own posts.
create or replace function public.community_unread_count(p_community_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int
    from public.community_chat cc
   where cc.community_id = p_community_id
     and cc.sender_id is distinct from auth.uid()
     and cc.created_at > coalesce(
       (select r.last_read_at from public.community_reads r
         where r.player_id = auth.uid() and r.community_id = p_community_id),
       (select m.joined_at from public.community_members m
         where m.player_id = auth.uid() and m.community_id = p_community_id),
       now());
$$;
grant execute on function public.community_unread_count(uuid) to authenticated;

notify pgrst, 'reload schema';
