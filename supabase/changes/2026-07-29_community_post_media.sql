-- ============================================================================
-- 2026-07-29 — Community posts get media (Instagram/Twitter-style feed)
--
-- The community announcement feed already has likes + comments + RSVP end-to-end
-- (announcement_likes / announcement_comments + toggle_announcement_like /
-- add_announcement_comment / announcement_comments RPCs, surfaced in the player
-- community hub). The only missing piece for a social feed was MEDIA — this adds
-- an optional image to each post.
--
-- - community_announcements.image_url  (new column)
-- - community-media storage bucket (public read, owner writes own <uid>/ folder)
-- - post_announcement gains p_image_url
-- - community_feed returns image_url
--
-- Safe to re-run. After running: notify pgrst, 'reload schema';
-- ============================================================================

alter table public.community_announcements add column if not exists image_url text;

-- Public bucket for post images; each user writes only inside their own folder.
insert into storage.buckets (id, name, public)
  values ('community-media', 'community-media', true)
  on conflict (id) do update set public = true;
drop policy if exists "community-media owner write" on storage.objects;
create policy "community-media owner write" on storage.objects
  for all to authenticated
  using (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- post_announcement now accepts an optional image URL (dropped the 3-arg form
-- so the signature is unambiguous; the 4th arg defaults null for old callers).
drop function if exists public.post_announcement(text, text, boolean);
create or replace function public.post_announcement(
  p_title text, p_body text default null, p_pinned boolean default false,
  p_image_url text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return 'Create your community first.'; end if;
  insert into public.community_announcements (community_id, title, body, pinned, image_url)
  values (v_cid, p_title, nullif(btrim(coalesce(p_body,'')),''), coalesce(p_pinned, false),
          nullif(btrim(coalesce(p_image_url,'')),''));
  insert into public.notifications (user_id, type, title, body, data)
  select cm.player_id, 'community', p_title, nullif(btrim(coalesce(p_body,'')),''),
         jsonb_build_object('community_id', v_cid)
    from public.community_members cm where cm.community_id = v_cid;
  return null;
end $$;
grant execute on function public.post_announcement(text, text, boolean, text) to authenticated;

-- community_feed now returns image_url alongside the like/comment/RSVP counts.
drop function if exists public.community_feed(uuid);
create or replace function public.community_feed(p_community_id uuid)
returns table (id uuid, title text, body text, image_url text, pinned boolean, created_at timestamptz,
               going int, i_going boolean, likes int, i_liked boolean, comments int)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.image_url, a.pinned, a.created_at,
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
