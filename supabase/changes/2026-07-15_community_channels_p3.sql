-- 2026-07-15 · Community channels Phase 3 — post permissions + organizer console
--
-- Per-channel posting rule enforced server-side:
--   all        → any community member
--   registered → registered players for the event (+ organizer); community
--                channels with 'registered' fall back to all members (no event)
--   org        → organizer/admin only (announcement style)
-- Event channels default to the community's channel_event_post setting.
-- Organizers create custom community channels and tune permissions via RPCs.
--
-- Idempotent. Also folded into migration_player_app.sql.

-- Per-community channel settings.
alter table public.communities
  add column if not exists channel_event_post text not null default 'registered'
    check (channel_event_post in ('all','registered','org'));
alter table public.communities
  add column if not exists channel_casual_auto boolean not null default false;

-- New event channels adopt the community's event-post default.
create or replace function public.tg_event_channel()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cid uuid; v_name text; v_ends timestamptz; v_post text;
begin
  if new.organizer_id is null then return new; end if;
  select id, coalesce(channel_event_post, 'registered') into v_cid, v_post
    from public.communities where organizer_id = new.organizer_id limit 1;
  if v_cid is null then return new; end if;
  v_name := trim(both '-' from lower(regexp_replace(coalesce(new.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then v_name := 'event-' || left(new.id::text, 8); end if;
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    v_name := v_name || '-' || left(new.id::text, 4);
  end if;
  v_ends := (coalesce(new.end_date, new.start_date))::timestamptz + interval '1 day';
  insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
  values (v_cid, v_name, 'tournament', new.id, v_ends, v_post, 100)
  on conflict (community_id, event_id) do nothing;
  return new;
end $$;

-- Who may post in a (channel, user) pair — the single source of truth reused by
-- both the write policy and the can_post flag.
create or replace function public.mm_can_post_channel(p_channel_id uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_uid is null then false
    else exists (
      select 1 from public.community_channels ch
       where ch.id = p_channel_id
         -- not archived
         and not (ch.kind <> 'community' and ch.ends_at is not null
                  and now() >= ch.ends_at + interval '24 hours')
         and (
           -- organizer / admin: always
           exists (select 1 from public.communities c
                    where c.id = ch.community_id and (c.organizer_id = p_uid or public._is_admin()))
           or (
             -- member + channel permission
             exists (select 1 from public.community_members m
                      where m.community_id = ch.community_id and m.player_id = p_uid)
             and (
               ch.post = 'all'
               or (ch.post = 'registered' and (
                     ch.event_id is null
                     or exists (select 1 from public.tournament_entries te
                                 where te.tournament_id = ch.event_id and te.player_id = p_uid
                                   and te.status <> 'withdrawn'))
               )
             )
           )
         )
    )
  end;
$$;
grant execute on function public.mm_can_post_channel(uuid, uuid) to authenticated;

-- Enforce it on insert.
drop policy if exists "community_chat: member write" on public.community_chat;
create policy "community_chat: member write" on public.community_chat for insert
  with check (
    sender_id = auth.uid()
    and public.mm_can_post_channel(channel_id, auth.uid())
  );

-- can_post added to the channel list (return type changed → drop first).
drop function if exists public.community_channel_list(uuid);
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, kind text, state text,
  event_id uuid, going int, can_post boolean, preview text, last_at timestamptz
)
language sql stable set search_path = public as $$
  select ch.id, ch.name, ch.post, ch.is_custom, ch.kind,
         case when ch.kind = 'community' or ch.ends_at is null then 'active'
              when now() < ch.ends_at then 'active'
              when now() < ch.ends_at + interval '24 hours' then 'grace'
              else 'archived' end as state,
         ch.event_id,
         coalesce((select count(*)::int from public.tournament_entries te
                    where te.tournament_id = ch.event_id and te.status <> 'withdrawn'), 0) as going,
         public.mm_can_post_channel(ch.id, auth.uid()) as can_post,
         lm.body, lm.created_at
    from public.community_channels ch
    left join lateral (
      select body, created_at from public.community_chat cc
       where cc.channel_id = ch.id order by cc.created_at desc limit 1
    ) lm on true
   where ch.community_id = p_community_id
   order by
     case ch.kind when 'community' then 0 else 1 end,
     case when ch.kind = 'community' or ch.ends_at is null then 0
          when now() < ch.ends_at + interval '24 hours' then 0 else 1 end,
     ch.sort, ch.created_at;
$$;
grant execute on function public.community_channel_list(uuid) to authenticated;

-- ── Organizer channel management ────────────────────────────────
create or replace function public.create_community_channel(p_name text, p_post text default 'all')
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid; v_name text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid limit 1;
  if v_cid is null then return 'You do not run a community.'; end if;
  v_name := trim(both '-' from lower(regexp_replace(coalesce(p_name, ''), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then return 'Enter a channel name.'; end if;
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    return 'A channel with that name already exists.';
  end if;
  insert into public.community_channels (community_id, name, post, is_custom, sort)
  values (v_cid, v_name, p_post, true, 50);
  return null;
end $$;

create or replace function public.set_channel_post(p_channel_id uuid, p_post text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if p_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  update public.community_channels ch set post = p_post
   where ch.id = p_channel_id
     and exists (select 1 from public.communities c
                  where c.id = ch.community_id and c.organizer_id = v_uid);
  if not found then return 'Not allowed.'; end if;
  return null;
end $$;

create or replace function public.delete_community_channel(p_channel_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  delete from public.community_channels ch
   where ch.id = p_channel_id and ch.is_custom = true and ch.kind = 'community'
     and exists (select 1 from public.communities c
                  where c.id = ch.community_id and c.organizer_id = v_uid);
  if not found then return 'Only your custom channels can be deleted.'; end if;
  return null;
end $$;

create or replace function public.set_channel_settings(p_event_post text, p_casual_auto boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if p_event_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  update public.communities
     set channel_event_post = p_event_post,
         channel_casual_auto = coalesce(p_casual_auto, false)
   where organizer_id = v_uid;
  if not found then return 'You do not run a community.'; end if;
  return null;
end $$;

grant execute on function public.create_community_channel(text, text) to authenticated;
grant execute on function public.set_channel_post(uuid, text) to authenticated;
grant execute on function public.delete_community_channel(uuid) to authenticated;
grant execute on function public.set_channel_settings(text, boolean) to authenticated;

notify pgrst, 'reload schema';
