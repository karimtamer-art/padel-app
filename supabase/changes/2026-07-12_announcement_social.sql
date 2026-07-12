-- ============================================================================
-- Community feed: likes + comments on announcements (2026-07-12).
-- Run once in the Supabase SQL editor. Idempotent & re-runnable.
--
-- Completes the v9 community feed (previously RSVP-only): members can like and
-- comment on organizer announcements. community_feed() now also returns
-- likes / i_liked / comments counts.
-- ============================================================================

create table if not exists public.announcement_likes (
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (announcement_id, player_id)
);

create table if not exists public.announcement_comments (
  id              uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  body            text not null,
  created_at      timestamptz not null default now()
);
create index if not exists idx_ann_comments on public.announcement_comments (announcement_id, created_at);

alter table public.announcement_likes    enable row level security;
alter table public.announcement_comments enable row level security;

do $$ begin
  create policy "ann_likes: read all" on public.announcement_likes for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_likes: own write" on public.announcement_likes for all
    using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_comments: read all" on public.announcement_comments for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_comments: own insert" on public.announcement_comments for insert
    with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;

create or replace function public.toggle_announcement_like(p_announcement_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_exists boolean;
begin
  select exists (select 1 from public.announcement_likes
                  where announcement_id = p_announcement_id and player_id = auth.uid())
    into v_exists;
  if v_exists then
    delete from public.announcement_likes
     where announcement_id = p_announcement_id and player_id = auth.uid();
    return false;
  else
    insert into public.announcement_likes (announcement_id, player_id)
    values (p_announcement_id, auth.uid()) on conflict do nothing;
    return true;
  end if;
end $$;
grant execute on function public.toggle_announcement_like(uuid) to authenticated;

create or replace function public.add_announcement_comment(p_announcement_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if btrim(coalesce(p_body, '')) = '' then return 'Comment required.'; end if;
  insert into public.announcement_comments (announcement_id, player_id, body)
  values (p_announcement_id, auth.uid(), btrim(p_body));
  return null;
end $$;
grant execute on function public.add_announcement_comment(uuid, text) to authenticated;

create or replace function public.announcement_comments(p_announcement_id uuid)
returns table (id uuid, player_id uuid, name text, avatar_url text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.player_id, p.name, p.avatar_url, c.body, c.created_at
    from public.announcement_comments c
    join public.profiles p on p.id = c.player_id
   where c.announcement_id = p_announcement_id
   order by c.created_at;
$$;
grant execute on function public.announcement_comments(uuid) to authenticated;

-- Feed now carries likes / i_liked / comments as well as RSVP.
drop function if exists public.community_feed(uuid);
create or replace function public.community_feed(p_community_id uuid)
returns table (id uuid, title text, body text, pinned boolean, created_at timestamptz,
               going int, i_going boolean, likes int, i_liked boolean, comments int)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.pinned, a.created_at,
         (select count(*)::int from public.announcement_rsvps r where r.announcement_id = a.id) as going,
         exists (select 1 from public.announcement_rsvps r
                  where r.announcement_id = a.id and r.player_id = auth.uid()) as i_going,
         (select count(*)::int from public.announcement_likes l where l.announcement_id = a.id) as likes,
         exists (select 1 from public.announcement_likes l
                  where l.announcement_id = a.id and l.player_id = auth.uid()) as i_liked,
         (select count(*)::int from public.announcement_comments c where c.announcement_id = a.id) as comments
    from public.community_announcements a
   where a.community_id = p_community_id
   order by a.pinned desc, a.created_at desc;
$$;
grant execute on function public.community_feed(uuid) to authenticated;

notify pgrst, 'reload schema';
