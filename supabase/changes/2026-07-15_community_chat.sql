-- 2026-07-15 · Community group chat (the hub "Chat" tab)
--
-- A community-wide chat: any member (or the organizer) can post, and all members
-- + the organizer/admin can read. Distinct from community_messages, which is the
-- private member<->organizer thread behind the "Message" button.
--
-- Idempotent. Also folded into migration_player_app.sql.

create table if not exists public.community_chat (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  sender_id    uuid not null references public.profiles(id) on delete cascade,
  body         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_chat
  on public.community_chat (community_id, created_at);

alter table public.community_chat enable row level security;

-- Read: members of the community, its organizer, or an admin.
do $$ begin
  create policy "community_chat: member read" on public.community_chat for select
    using (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    );
exception when duplicate_object then null; end $$;

-- Write: a member (or the organizer) posting as themselves.
do $$ begin
  create policy "community_chat: member write" on public.community_chat for insert
    with check (
      sender_id = auth.uid()
      and (
        exists (select 1 from public.community_members m
                 where m.community_id = community_chat.community_id and m.player_id = auth.uid())
        or exists (select 1 from public.communities c
                    where c.id = community_chat.community_id and c.organizer_id = auth.uid())
      )
    );
exception when duplicate_object then null; end $$;

grant select, insert on public.community_chat to authenticated;

notify pgrst, 'reload schema';
