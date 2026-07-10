-- ============================================================================
-- Community — Phase 3 of Roles/Organizer/Community.
-- Run once in the Supabase SQL editor (after the RBAC + organizer deltas).
-- Idempotent & re-runnable.
--
-- An organizer runs ONE community. Players join, RSVP to announcements, and
-- message the organizer. Because organizers are console-only (no player app),
-- member↔organizer chat lives in `community_messages` (read/replied in the
-- console inbox), NOT the player DM system. Events shown in the hub are the
-- organizer's own tournaments (read via existing RLS).
--
-- v1 scope (per plan): announcements + RSVP real; likes/comments deferred.
-- ============================================================================

create table if not exists public.communities (
  id           uuid primary key default gen_random_uuid(),
  organizer_id uuid not null unique references public.profiles(id) on delete cascade,
  name         text not null,
  handle       text,
  city         text,
  about        text,
  verified     boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists communities_handle_key
  on public.communities (lower(handle)) where handle is not null;

create table if not exists public.community_members (
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  joined_at    timestamptz not null default now(),
  primary key (community_id, player_id)
);
create index if not exists idx_community_members_player
  on public.community_members (player_id);

create table if not exists public.community_announcements (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  title        text not null,
  body         text,
  pinned       boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_ann_community
  on public.community_announcements (community_id, created_at desc);

create table if not exists public.announcement_rsvps (
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  primary key (announcement_id, player_id)
);

create table if not exists public.community_messages (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  member_id    uuid not null references public.profiles(id) on delete cascade, -- whose thread
  sender_role  text not null check (sender_role in ('member','organizer')),
  body         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_messages_thread
  on public.community_messages (community_id, member_id, created_at);

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table public.communities            enable row level security;
alter table public.community_members      enable row level security;
alter table public.community_announcements enable row level security;
alter table public.announcement_rsvps     enable row level security;
alter table public.community_messages     enable row level security;

-- communities: public read; organizer owns write.
do $$ begin
  create policy "communities: read all" on public.communities for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "communities: organizer write own" on public.communities for all
    using (organizer_id = auth.uid() or public._is_admin())
    with check (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

-- members: public read (avatars/counts); a player manages own membership.
do $$ begin
  create policy "members: read all" on public.community_members for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "members: join self" on public.community_members for insert
    with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "members: leave self" on public.community_members for delete
    using (player_id = auth.uid());
exception when duplicate_object then null; end $$;

-- announcements: public read; the community's organizer writes.
do $$ begin
  create policy "announcements: read all" on public.community_announcements for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "announcements: organizer write" on public.community_announcements for all
    using (exists (select 1 from public.communities c
                    where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())))
    with check (exists (select 1 from public.communities c
                    where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;

-- rsvps: public read (going counts); a player toggles own.
do $$ begin
  create policy "rsvps: read all" on public.announcement_rsvps for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "rsvps: own write" on public.announcement_rsvps for all
    using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;

-- messages: the member sees own thread; the organizer sees their community's.
do $$ begin
  create policy "messages: member or organizer read" on public.community_messages for select
    using (member_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;
-- inserts go through the RPCs (security definer) — no direct insert policy.

-- ── Organizer: create / update my community ─────────────────────────────────
create or replace function public.upsert_my_community(
  p_name text, p_handle text default null, p_city text default null, p_about text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_name, '')) = '' then return 'Name required.'; end if;
  insert into public.communities (organizer_id, name, handle, city, about, updated_at)
  values (v_uid, p_name, nullif(btrim(coalesce(p_handle,'')),''),
          nullif(btrim(coalesce(p_city,'')),''), nullif(btrim(coalesce(p_about,'')),''), now())
  on conflict (organizer_id) do update set
    name = excluded.name, handle = excluded.handle,
    city = excluded.city, about = excluded.about, updated_at = now();
  return null;
end $$;
grant execute on function public.upsert_my_community(text, text, text, text) to authenticated;

-- ── Player: join / leave ────────────────────────────────────────────────────
create or replace function public.join_community(p_community_id uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  insert into public.community_members (community_id, player_id)
  values (p_community_id, auth.uid())
  on conflict do nothing;
  return null;
end $$;
grant execute on function public.join_community(uuid) to authenticated;

create or replace function public.leave_community(p_community_id uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  delete from public.community_members
   where community_id = p_community_id and player_id = auth.uid();
  return null;
end $$;
grant execute on function public.leave_community(uuid) to authenticated;

-- ── Player: RSVP toggle → returns the new going state ───────────────────────
create or replace function public.toggle_rsvp(p_announcement_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_exists boolean;
begin
  select exists (select 1 from public.announcement_rsvps
                  where announcement_id = p_announcement_id and player_id = auth.uid())
    into v_exists;
  if v_exists then
    delete from public.announcement_rsvps
     where announcement_id = p_announcement_id and player_id = auth.uid();
    return false;
  else
    insert into public.announcement_rsvps (announcement_id, player_id)
    values (p_announcement_id, auth.uid()) on conflict do nothing;
    return true;
  end if;
end $$;
grant execute on function public.toggle_rsvp(uuid) to authenticated;

-- ── Organizer: post an announcement (notifies members) ──────────────────────
create or replace function public.post_announcement(
  p_title text, p_body text default null, p_pinned boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return 'Create your community first.'; end if;
  insert into public.community_announcements (community_id, title, body, pinned)
  values (v_cid, p_title, nullif(btrim(coalesce(p_body,'')),''), coalesce(p_pinned, false));
  -- notify members (push + in-app) via the notifications fan-out
  insert into public.notifications (user_id, type, title, body, data)
  select cm.player_id, 'community', p_title, nullif(btrim(coalesce(p_body,'')),''),
         jsonb_build_object('community_id', v_cid)
    from public.community_members cm where cm.community_id = v_cid;
  return null;
end $$;
grant execute on function public.post_announcement(text, text, boolean) to authenticated;

-- ── Messaging: member → organizer, and organizer → member ───────────────────
create or replace function public.send_community_message(p_community_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if btrim(coalesce(p_body, '')) = '' then return 'Message required.'; end if;
  if not exists (select 1 from public.community_members
                  where community_id = p_community_id and player_id = auth.uid()) then
    return 'Join the community first.';
  end if;
  insert into public.community_messages (community_id, member_id, sender_role, body)
  values (p_community_id, auth.uid(), 'member', btrim(p_body));
  -- ping the organizer's console bell
  insert into public.notifications (user_id, type, title, body, data)
  select c.organizer_id, 'admin_community', 'New community message', left(btrim(p_body), 80),
         jsonb_build_object('community_id', p_community_id, 'member_id', auth.uid())
    from public.communities c where c.id = p_community_id;
  return null;
end $$;
grant execute on function public.send_community_message(uuid, text) to authenticated;

create or replace function public.reply_community_message(p_member_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_body, '')) = '' then return 'Message required.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return 'No community.'; end if;
  insert into public.community_messages (community_id, member_id, sender_role, body)
  values (v_cid, p_member_id, 'organizer', btrim(p_body));
  -- notify the member (push + in-app)
  insert into public.notifications (user_id, type, title, body, data)
  values (p_member_id, 'community', 'Reply from your organizer', left(btrim(p_body), 80),
          jsonb_build_object('community_id', v_cid));
  return null;
end $$;
grant execute on function public.reply_community_message(uuid, text) to authenticated;

-- ── Feed: announcements with going counts + whether I'm going ───────────────
create or replace function public.community_feed(p_community_id uuid)
returns table (id uuid, title text, body text, pinned boolean,
               created_at timestamptz, going int, i_going boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.pinned, a.created_at,
         (select count(*)::int from public.announcement_rsvps r where r.announcement_id = a.id) as going,
         exists (select 1 from public.announcement_rsvps r
                  where r.announcement_id = a.id and r.player_id = auth.uid()) as i_going
    from public.community_announcements a
   where a.community_id = p_community_id
   order by a.pinned desc, a.created_at desc;
$$;
grant execute on function public.community_feed(uuid) to authenticated;

-- ── Organizer inbox: one row per member thread, newest first ────────────────
create or replace function public.community_inbox()
returns table (member_id uuid, member_name text, avatar_url text,
               last_body text, last_at timestamptz, last_role text, unanswered boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then return; end if;
  select id into v_cid from public.communities where organizer_id = auth.uid();
  if v_cid is null then return; end if;
  return query
    select m.member_id, p.name, p.avatar_url, last.body, last.created_at, last.sender_role,
           (last.sender_role = 'member')
      from (select distinct member_id from public.community_messages where community_id = v_cid) m
      join public.profiles p on p.id = m.member_id
      join lateral (
        select body, created_at, sender_role from public.community_messages cm
         where cm.community_id = v_cid and cm.member_id = m.member_id
         order by cm.created_at desc limit 1
      ) last on true
     order by last.created_at desc;
end $$;
grant execute on function public.community_inbox() to authenticated;

notify pgrst, 'reload schema';
