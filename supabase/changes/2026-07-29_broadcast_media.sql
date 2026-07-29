-- ============================================================================
-- 2026-07-29 — Organizer broadcasts become social posts (media + likes/comments)
--
-- Organizers post from the Broadcasts composer. Previously that was a one-way
-- text push. Now a broadcast ALSO carries an optional image and is mirrored into
-- the organizer's community feed as a likeable/commentable post — so one compose
-- action = push blast + Instagram-style social post.
--
-- Depends on 2026-07-29_community_post_media.sql (community_announcements.image_url
-- + community-media bucket). Run that first (or together).
--
-- Safe to re-run. After running: notify pgrst, 'reload schema';
-- ============================================================================

-- Broadcast log carries the image + a link to the mirrored feed post.
alter table public.organizer_broadcasts add column if not exists image_url text;
alter table public.organizer_broadcasts add column if not exists announcement_id uuid;

-- A broadcast is BOTH a push blast (entrants ∪ community members) AND, when the
-- organizer has a community, a community feed post with an optional image.
drop function if exists public.organizer_broadcast(text, text, uuid);
create or replace function public.organizer_broadcast(
  p_title text, p_body text, p_tournament_id uuid default null, p_image_url text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ids uuid[]; v_n int; v_cid uuid; v_aid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  if p_tournament_id is not null and not public.owns_tournament(p_tournament_id) then
    return 'Not your tournament.';
  end if;
  select array_agg(distinct pid) into v_ids from (
    select te.player_id pid
      from public.tournament_entries te
     where te.status not in ('withdrawn','cancelled')
       and te.tournament_id in (
         select id from public.tournaments
          where organizer_id = v_uid
            and (p_tournament_id is null or id = p_tournament_id))
    union
    select cm.player_id
      from public.community_members cm
     where p_tournament_id is null
       and cm.community_id in (select id from public.communities where organizer_id = v_uid)
  ) u where pid is not null;
  v_n := coalesce(array_length(v_ids, 1), 0);

  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is not null then
    insert into public.community_announcements (community_id, title, body, image_url)
    values (v_cid, p_title, nullif(btrim(coalesce(p_body,'')),''),
            nullif(btrim(coalesce(p_image_url,'')),''))
    returning id into v_aid;
  end if;

  if v_n = 0 and v_aid is null then
    return 'No one to reach yet — get community members or event entrants first.';
  end if;

  if v_n > 0 then
    insert into public.notifications (user_id, type, title, body, data)
    select uid, 'broadcast', p_title, nullif(btrim(p_body), ''),
           jsonb_build_object('from', 'organizer', 'community_id', v_cid,
                              'announcement_id', v_aid)
      from unnest(v_ids) as uid;
  end if;
  insert into public.organizer_broadcasts
    (organizer_id, tournament_id, title, body, recipients, image_url, announcement_id)
  values (v_uid, p_tournament_id, p_title, nullif(btrim(p_body), ''), v_n,
          nullif(btrim(coalesce(p_image_url,'')),''), v_aid);
  return null;
end $$;
grant execute on function public.organizer_broadcast(text, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';
