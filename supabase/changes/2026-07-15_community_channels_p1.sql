-- 2026-07-15 · Community channels Phase 1 — multiple community channels
--
-- Turns the single community chat into named channels (#general,
-- #looking-for-4th, #off-topic, + future custom ones). community_chat gains a
-- channel_id; each community auto-seeds the 3 default channels (trigger +
-- backfill). Event channels + lifecycle + per-channel post permissions come in
-- later phases — every channel here is post='all'.
--
-- Idempotent. Also folded into migration_player_app.sql.

create table if not exists public.community_channels (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  name         text not null,                 -- slug (lower-kebab), e.g. 'general'
  post         text not null default 'all' check (post in ('all','registered','org')),
  is_custom    boolean not null default false,
  sort         int not null default 0,
  created_at   timestamptz not null default now(),
  unique (community_id, name)
);
create index if not exists idx_community_channels
  on public.community_channels (community_id, sort, created_at);
alter table public.community_channels enable row level security;

do $$ begin
  create policy "community_channels: member read" on public.community_channels for select
    using (
      exists (select 1 from public.community_members m
               where m.community_id = community_channels.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_channels.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    );
exception when duplicate_object then null; end $$;
grant select on public.community_channels to authenticated;

-- Seed the 3 default channels for a community (idempotent).
create or replace function public.seed_default_channels(p_community_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.community_channels (community_id, name, post, sort) values
    (p_community_id, 'general',         'all', 0),
    (p_community_id, 'looking-for-4th', 'all', 1),
    (p_community_id, 'off-topic',       'all', 2)
  on conflict (community_id, name) do nothing;
end $$;

create or replace function public.tg_seed_channels()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_default_channels(new.id);
  return new;
end $$;
drop trigger if exists trg_seed_channels on public.communities;
create trigger trg_seed_channels after insert on public.communities
  for each row execute function public.tg_seed_channels();

-- Backfill existing communities.
do $$ declare r record; begin
  for r in select id from public.communities loop
    perform public.seed_default_channels(r.id);
  end loop;
end $$;

-- Messages now belong to a channel.
alter table public.community_chat
  add column if not exists channel_id uuid references public.community_channels(id) on delete cascade;
create index if not exists idx_community_chat_channel
  on public.community_chat (channel_id, created_at);

-- Backfill any existing messages into #general.
update public.community_chat cc
   set channel_id = ch.id
  from public.community_channels ch
 where ch.community_id = cc.community_id and ch.name = 'general' and cc.channel_id is null;

-- Channel list with last-message preview (invoker rights → respects RLS).
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, preview text, last_at timestamptz
)
language sql stable set search_path = public as $$
  select ch.id, ch.name, ch.post, ch.is_custom, lm.body, lm.created_at
    from public.community_channels ch
    left join lateral (
      select body, created_at from public.community_chat cc
       where cc.channel_id = ch.id order by cc.created_at desc limit 1
    ) lm on true
   where ch.community_id = p_community_id
   order by ch.sort, ch.created_at;
$$;
grant execute on function public.community_channel_list(uuid) to authenticated;

notify pgrst, 'reload schema';
