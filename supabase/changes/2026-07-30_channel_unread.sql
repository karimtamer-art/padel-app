-- 2026-07-30 — Per-CHANNEL unread tracking (supersedes the community-level
-- cursor for badge math). Run on the live DB (idempotent; safe to re-run).
--
-- Adds a per (player, channel) read cursor so each channel row in the hub Chat
-- tab shows its own unread badge, and the Home community card badge becomes the
-- SUM of unread across that community's channels. Opening a channel marks just
-- that channel read.
--
-- Note: community_reads / mark_community_read from the prior delta are now
-- vestigial (kept, harmless) — community_unread_count is redefined below to
-- aggregate the per-channel cursors instead.

create table if not exists public.channel_reads (
  player_id    uuid not null references public.profiles(id)          on delete cascade,
  channel_id   uuid not null references public.community_channels(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (player_id, channel_id)
);
alter table public.channel_reads enable row level security;
do $$ begin
  create policy "channel_reads: self" on public.channel_reads
    for all using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select, insert, update on public.channel_reads to authenticated;

-- Mark one channel read up to now (called when a channel is opened).
create or replace function public.mark_channel_read(p_channel_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.channel_reads (player_id, channel_id, last_read_at)
  values (auth.uid(), p_channel_id, now())
  on conflict (player_id, channel_id)
  do update set last_read_at = excluded.last_read_at;
$$;
grant execute on function public.mark_channel_read(uuid) to authenticated;

-- Per-channel unread counts for a community: { channel_id, unread }. Floor is
-- the channel's read cursor, else when the caller joined the community, else now
-- (so non-members / history before joining don't light up). Excludes own posts.
create or replace function public.community_channel_unreads(p_community_id uuid)
returns table (channel_id uuid, unread int)
language sql stable security definer set search_path = public as $$
  select ch.id,
         (select count(*)::int
            from public.community_chat cc
           where cc.channel_id = ch.id
             and cc.sender_id is distinct from auth.uid()
             and cc.created_at > coalesce(
               (select r.last_read_at from public.channel_reads r
                 where r.player_id = auth.uid() and r.channel_id = ch.id),
               (select m.joined_at from public.community_members m
                 where m.player_id = auth.uid() and m.community_id = p_community_id),
               now()))
    from public.community_channels ch
   where ch.community_id = p_community_id;
$$;
grant execute on function public.community_channel_unreads(uuid) to authenticated;

-- Home community card badge = total unread across the community's channels.
create or replace function public.community_unread_count(p_community_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(u.unread), 0)::int
    from public.community_channel_unreads(p_community_id) u;
$$;
grant execute on function public.community_unread_count(uuid) to authenticated;

notify pgrst, 'reload schema';
