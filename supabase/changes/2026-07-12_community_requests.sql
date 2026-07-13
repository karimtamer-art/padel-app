-- ============================================================================
-- Community requests: typed inbox (messages + join requests + match requests).
-- 2026-07-12. Run once. Idempotent.
--
-- • Communities can require approval to join (approval_required). join_community
--   then files a pending join request instead of joining outright.
-- • Members can post a "looking for a match" request to the organizer.
-- • The organizer's inbox becomes typed: message / join / match, with Approve
--   for the actionable kinds. Approvals notify the member.
-- ============================================================================

alter table public.communities add column if not exists approval_required boolean not null default false;

create table if not exists public.community_join_requests (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at   timestamptz not null default now(),
  unique (community_id, player_id)
);
create table if not exists public.community_match_requests (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  note         text,
  status       text not null default 'open' check (status in ('open','resolved')),
  created_at   timestamptz not null default now()
);
create index if not exists idx_join_req_comm on public.community_join_requests (community_id, status);
create index if not exists idx_match_req_comm on public.community_match_requests (community_id, status);

alter table public.community_join_requests  enable row level security;
alter table public.community_match_requests enable row level security;
-- Read: the requester, or the owning organizer. Writes go through RPCs.
do $$ begin
  create policy "join_req: member or organizer read" on public.community_join_requests for select
    using (player_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "match_req: member or organizer read" on public.community_match_requests for select
    using (player_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;

-- join_community now honours approval_required.
create or replace function public.join_community(p_community_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_needs boolean;
begin
  if exists (select 1 from public.community_members
              where community_id = p_community_id and player_id = v_uid) then
    return null; -- already a member
  end if;
  select approval_required into v_needs from public.communities where id = p_community_id;
  if coalesce(v_needs, false) then
    insert into public.community_join_requests (community_id, player_id, status)
    values (p_community_id, v_uid, 'pending')
    on conflict (community_id, player_id) do update set status = 'pending';
    insert into public.notifications (user_id, type, title, body, data)
    select c.organizer_id, 'admin_community', 'New join request', null,
           jsonb_build_object('community_id', p_community_id, 'member_id', v_uid)
      from public.communities c where c.id = p_community_id;
    return 'requested';
  end if;
  insert into public.community_members (community_id, player_id)
  values (p_community_id, v_uid) on conflict do nothing;
  return null;
end $$;
grant execute on function public.join_community(uuid) to authenticated;

create or replace function public.approve_join_request(p_id uuid, p_approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select jr.*, c.organizer_id into r
    from public.community_join_requests jr
    join public.communities c on c.id = jr.community_id
   where jr.id = p_id;
  if not found then return 'Request not found.'; end if;
  if r.organizer_id <> auth.uid() and not public._is_admin() then return 'Not authorised.'; end if;
  if p_approve then
    insert into public.community_members (community_id, player_id)
    values (r.community_id, r.player_id) on conflict do nothing;
    update public.community_join_requests set status = 'approved' where id = p_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (r.player_id, 'community', 'You''re in!', 'Your join request was approved.',
            jsonb_build_object('community_id', r.community_id));
  else
    update public.community_join_requests set status = 'declined' where id = p_id;
  end if;
  return null;
end $$;
grant execute on function public.approve_join_request(uuid, boolean) to authenticated;

-- Member posts a match request; organizer resolves it.
create or replace function public.create_match_request(p_community_id uuid, p_note text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.community_members
                  where community_id = p_community_id and player_id = auth.uid()) then
    return 'Join the community first.';
  end if;
  insert into public.community_match_requests (community_id, player_id, note)
  values (p_community_id, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''));
  insert into public.notifications (user_id, type, title, body, data)
  select c.organizer_id, 'admin_community', 'New match request', left(btrim(coalesce(p_note, '')), 80),
         jsonb_build_object('community_id', p_community_id, 'member_id', auth.uid())
    from public.communities c where c.id = p_community_id;
  return null;
end $$;
grant execute on function public.create_match_request(uuid, text) to authenticated;

create or replace function public.resolve_match_request(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select mr.*, c.organizer_id into r
    from public.community_match_requests mr
    join public.communities c on c.id = mr.community_id
   where mr.id = p_id;
  if not found then return 'Request not found.'; end if;
  if r.organizer_id <> auth.uid() and not public._is_admin() then return 'Not authorised.'; end if;
  update public.community_match_requests set status = 'resolved' where id = p_id;
  insert into public.notifications (user_id, type, title, body, data)
  values (r.player_id, 'community', 'Your organizer is on it',
          'Your match request is being sorted.', jsonb_build_object('community_id', r.community_id));
  return null;
end $$;
grant execute on function public.resolve_match_request(uuid) to authenticated;

create or replace function public.set_community_approval(p_on boolean)
returns text language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  update public.communities set approval_required = coalesce(p_on, false)
   where organizer_id = auth.uid();
  return null;
end $$;
grant execute on function public.set_community_approval(boolean) to authenticated;

-- Typed inbox for the organizer console: match + join + message, newest first.
create or replace function public.community_inbox_typed()
returns table (kind text, id uuid, member_id uuid, member_name text, avatar_url text,
               preview text, created_at timestamptz, actionable boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then return; end if;
  select id into v_cid from public.communities where organizer_id = auth.uid();
  if v_cid is null then return; end if;
  return query
    select 'match'::text, mr.id, mr.player_id, p.name, p.avatar_url,
           coalesce(mr.note, 'Looking for a match'), mr.created_at, true
      from public.community_match_requests mr join public.profiles p on p.id = mr.player_id
     where mr.community_id = v_cid and mr.status = 'open'
    union all
    select 'join'::text, jr.id, jr.player_id, p.name, p.avatar_url,
           'Wants to join the community', jr.created_at, true
      from public.community_join_requests jr join public.profiles p on p.id = jr.player_id
     where jr.community_id = v_cid and jr.status = 'pending'
    union all
    select 'message'::text, null::uuid, m.member_id, p.name, p.avatar_url,
           last.body, last.created_at, false
      from (select distinct member_id from public.community_messages where community_id = v_cid) m
      join public.profiles p on p.id = m.member_id
      join lateral (
        select body, created_at, sender_role from public.community_messages cm
         where cm.community_id = v_cid and cm.member_id = m.member_id
         order by cm.created_at desc limit 1
      ) last on true
    order by created_at desc;
end $$;
grant execute on function public.community_inbox_typed() to authenticated;

notify pgrst, 'reload schema';
