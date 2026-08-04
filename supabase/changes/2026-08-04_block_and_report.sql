-- 2026-08-04 — Blocking and reporting.
--
-- App Store Guideline 1.2 requires any app with user-generated content to let
-- people report objectionable content AND block abusive users. We ship DMs,
-- community chat, announcement comments and match tickets, and had neither.
--
-- Two independent mechanisms:
--
--  * BLOCK is the user's own decision and takes effect immediately with no
--    admin involved. It is deliberately SYMMETRIC — once either side blocks,
--    neither sees the other. One-way blocking leaks the block back to the
--    abuser ("why can't they see my messages") and lets them keep watching.
--
--  * REPORT tells the operators. It lands in a queue in the admin console and
--    is acted on there. Apple expects action within ~24h.
--
-- Blocking hides messages; it does not delete them, and it does not remove
-- anyone from a match. A blocked player in your match ticket still appears in
-- the roster (you are physically playing with them) but their messages are
-- hidden — see _blocked_with() usage below.
--
-- Safe to re-run.

-- ── tables ────────────────────────────────────────────────────────────────

create table if not exists public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocked_users_not_self check (blocker_id <> blocked_id)
);
create index if not exists idx_blocked_by
  on public.blocked_users (blocked_id);

create table if not exists public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references public.profiles(id) on delete cascade,
  -- What was reported. target_id is the row id in the matching table; it is
  -- intentionally NOT a foreign key so a report survives the content being
  -- deleted (otherwise acting on a report would erase the evidence).
  target_type    text not null,
  target_id      uuid,
  -- Who is being complained about. Kept even if the content goes, so repeat
  -- offenders are visible.
  target_user_id uuid references public.profiles(id) on delete set null,
  reason         text not null,
  note           text,
  -- Snapshot of the content as it was when reported, so the queue still shows
  -- what happened after the author edits or deletes it.
  content_excerpt text,
  status         text not null default 'open',
  created_at     timestamptz not null default now(),
  handled_by     uuid references public.profiles(id) on delete set null,
  handled_at     timestamptz,
  handled_note   text
);
create index if not exists idx_reports_open
  on public.reports (status, created_at desc);
create index if not exists idx_reports_target_user
  on public.reports (target_user_id);

alter table public.reports drop constraint if exists reports_target_type_chk;
alter table public.reports add constraint reports_target_type_chk
  check (target_type in ('dm_message','ticket_message','community_message',
                         'announcement_comment','user'));
alter table public.reports drop constraint if exists reports_status_chk;
alter table public.reports add constraint reports_status_chk
  check (status in ('open','actioned','dismissed'));

-- ── the block predicate ───────────────────────────────────────────────────

-- Symmetric: true if EITHER party blocked the other. SECURITY DEFINER because
-- it is used inside RLS policies, where the caller cannot read the other
-- side's block rows.
create or replace function public._blocked_with(p_other uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1 from public.blocked_users b
     where (b.blocker_id = auth.uid() and b.blocked_id = p_other)
        or (b.blocker_id = p_other and b.blocked_id = auth.uid()));
$$;
grant execute on function public._blocked_with(uuid) to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.blocked_users enable row level security;
-- You manage your own block list and can only ever see your own.
drop policy if exists "blocks: own" on public.blocked_users;
create policy "blocks: own" on public.blocked_users
  for all using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());
grant select, insert, delete on public.blocked_users to authenticated;

alter table public.reports enable row level security;
drop policy if exists "reports: file own" on public.reports;
create policy "reports: file own" on public.reports
  for insert with check (reporter_id = auth.uid());
-- Reporters see their own; moderation staff see everything.
drop policy if exists "reports: read own or staff" on public.reports;
create policy "reports: read own or staff" on public.reports
  for select using (reporter_id = auth.uid() or public._has_access('requests'));
drop policy if exists "reports: staff update" on public.reports;
create policy "reports: staff update" on public.reports
  for update using (public._can_edit('requests'))
  with check (public._can_edit('requests'));
grant select, insert on public.reports to authenticated;
grant update on public.reports to authenticated;

-- ── blocking actually hides things ────────────────────────────────────────

-- Direct messages: a blocked person's messages disappear from the thread.
drop policy if exists "dm: participant read" on public.direct_messages;
create policy "dm: participant read" on public.direct_messages
  for select using (
    exists (select 1 from public.conversations c
             where c.id = conversation_id
               and auth.uid() in (c.player_a, c.player_b))
    and not public._blocked_with(sender_id));

-- ...and they cannot send you new ones.
drop policy if exists "dm: participant send" on public.direct_messages;
create policy "dm: participant send" on public.direct_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (select 1 from public.conversations c
                 where c.id = conversation_id
                   and auth.uid() in (c.player_a, c.player_b)
                   and not public._blocked_with(
                     case when c.player_a = auth.uid() then c.player_b
                          else c.player_a end)));

-- Community chat: hide a blocked member's posts from you only. Everyone else
-- still sees them - blocking is personal, not a community-wide takedown.
-- Keeps the original organizer/admin read path intact - only the block
-- filter is new.
drop policy if exists "community_chat: member read" on public.community_chat;
create policy "community_chat: member read" on public.community_chat
  for select using (
    (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id
                 and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    )
    and not public._blocked_with(sender_id));

-- Announcement comments.
drop policy if exists "ann_comments: read all" on public.announcement_comments;
create policy "ann_comments: read all" on public.announcement_comments
  for select using (not public._blocked_with(player_id));

-- Match tickets: messages hidden, but the roster is untouched - you are still
-- playing this match with them and still need the court and the time.
drop policy if exists "ticket msg: member read" on public.ticket_messages;
create policy "ticket msg: member read" on public.ticket_messages
  for select using (
    public._ticket_member(ticket_id) and not public._blocked_with(sender_id));

-- ── inbox has to agree with the policies ──────────────────────────────────

-- dm_inbox is SECURITY DEFINER, so it bypasses the RLS above and would keep
-- listing blocked conversations. Filter explicitly.
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
     and not public._blocked_with(other.id)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- Opening a chat with someone you have blocked (or who blocked you) must fail
-- rather than silently create a thread nobody can post in.
-- Unchanged from the original except for the block guard. Returns NULL rather
-- than raising, exactly as before: DMChatScreen already renders a graceful
-- "couldn't open this chat" on null, and a raise would surface a Postgres
-- error string to the player instead.
create or replace function public.get_or_create_conversation(
  p_other uuid, p_match_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_a uuid; v_b uuid; v_id uuid;
begin
  if v_uid is null or p_other is null or p_other = v_uid then return null; end if;
  if public._blocked_with(p_other) then return null; end if;
  v_a := least(v_uid, p_other);
  v_b := greatest(v_uid, p_other);
  insert into public.conversations (player_a, player_b, match_id)
  values (v_a, v_b, p_match_id)
  on conflict (player_a, player_b) do nothing;
  select id into v_id from public.conversations
    where player_a = v_a and player_b = v_b;
  return v_id;
end $$;
grant execute on function public.get_or_create_conversation(uuid, uuid) to authenticated;

-- ── player-facing RPCs ────────────────────────────────────────────────────

create or replace function public.block_user(p_user uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if p_user = auth.uid() then
    raise exception 'Cannot block yourself';
  end if;
  insert into public.blocked_users (blocker_id, blocked_id)
  values (auth.uid(), p_user)
  on conflict do nothing;
end $$;
grant execute on function public.block_user(uuid) to authenticated;

create or replace function public.unblock_user(p_user uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  delete from public.blocked_users
   where blocker_id = auth.uid() and blocked_id = p_user;
end $$;
grant execute on function public.unblock_user(uuid) to authenticated;

create or replace function public.my_blocked_users()
returns table (player_id uuid, name text, username text, avatar_url text,
               blocked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.username, p.avatar_url, b.created_at
    from public.blocked_users b
    join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$$;
grant execute on function public.my_blocked_users() to authenticated;

-- Files a report. Resolves who is being complained about and snapshots the
-- content, so the queue is still useful after the message is gone.
create or replace function public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_reason      text,
  p_note        text default null,
  p_target_user uuid default null)
returns uuid language plpgsql security definer
set search_path = public as $$
declare v_user uuid := p_target_user; v_text text; v_id uuid;
begin
  if p_target_type = 'dm_message' then
    select dm.sender_id, dm.text into v_user, v_text
      from public.direct_messages dm where dm.id = p_target_id;
  elsif p_target_type = 'ticket_message' then
    select tm.sender_id, tm.text into v_user, v_text
      from public.ticket_messages tm where tm.id = p_target_id;
  elsif p_target_type = 'community_message' then
    select cc.sender_id, cc.body into v_user, v_text
      from public.community_chat cc where cc.id = p_target_id;
  elsif p_target_type = 'announcement_comment' then
    select ac.player_id, ac.body into v_user, v_text
      from public.announcement_comments ac where ac.id = p_target_id;
  end if;

  insert into public.reports (reporter_id, target_type, target_id,
                              target_user_id, reason, note, content_excerpt)
  values (auth.uid(), p_target_type, p_target_id,
          coalesce(v_user, p_target_user), p_reason, nullif(btrim(coalesce(p_note,'')), ''),
          left(v_text, 500))
  returning id into v_id;

  -- Tell every moderator there is something waiting. Rides the existing
  -- admin_% alert plumbing, so the console bell picks it up for free.
  insert into public.notifications (user_id, type, title, body, data)
  select pr.id, 'admin_report', 'Content reported',
         'A player reported ' ||
           case p_target_type when 'user' then 'another player'
                              else 'a message' end || '.',
         jsonb_build_object('report_id', v_id, 'admin', true)
    from public.profiles pr
   where pr.is_admin = true;

  return v_id;
end $$;
grant execute on function public.report_content(text, uuid, text, text, uuid) to authenticated;

-- ── admin moderation queue ────────────────────────────────────────────────

create or replace function public.admin_reports(p_status text default null)
returns table (
  id uuid, target_type text, target_id uuid, reason text, note text,
  content_excerpt text, status text, created_at timestamptz,
  reporter_id uuid, reporter_name text,
  target_user_id uuid, target_user_name text,
  target_user_status text, prior_reports int
)
language sql stable security definer set search_path = public as $$
  select r.id, r.target_type, r.target_id, r.reason, r.note,
         r.content_excerpt, r.status, r.created_at,
         r.reporter_id, rp.name,
         r.target_user_id, tp.name, tp.status,
         (select count(*)::int from public.reports x
           where x.target_user_id = r.target_user_id and x.id <> r.id)
    from public.reports r
    left join public.profiles rp on rp.id = r.reporter_id
    left join public.profiles tp on tp.id = r.target_user_id
   where public._has_access('requests')
     and (p_status is null or r.status = p_status)
   order by (r.status = 'open') desc, r.created_at desc;
$$;
grant execute on function public.admin_reports(text) to authenticated;

-- Resolve a report. p_delete removes the offending message outright, which is
-- what Apple means by acting on a report.
create or replace function public.admin_resolve_report(
  p_id uuid, p_status text, p_note text default null, p_delete boolean default false)
returns void language plpgsql security definer
set search_path = public as $$
declare r public.reports;
begin
  if not public._can_edit('requests') then
    raise exception 'Not authorised';
  end if;
  select * into r from public.reports where id = p_id;
  if r.id is null then
    raise exception 'Report not found';
  end if;

  if p_delete and r.target_id is not null then
    if    r.target_type = 'dm_message' then
      delete from public.direct_messages where id = r.target_id;
    elsif r.target_type = 'ticket_message' then
      delete from public.ticket_messages where id = r.target_id;
    elsif r.target_type = 'community_message' then
      delete from public.community_chat where id = r.target_id;
    elsif r.target_type = 'announcement_comment' then
      delete from public.announcement_comments where id = r.target_id;
    end if;
  end if;

  update public.reports
     set status = p_status,
         handled_by = auth.uid(),
         handled_at = now(),
         handled_note = nullif(btrim(coalesce(p_note,'')), '')
   where id = p_id;
end $$;
grant execute on function public.admin_resolve_report(uuid, text, text, boolean) to authenticated;

-- The console bell already fans out anything typed admin_%; make sure the new
-- alert maps to the Requests section so tapping it lands somewhere useful.
-- (sectionForAlertType is client-side; nothing to do server-side.)
