-- ============================================================================
-- Organizer broadcasts: reach the whole community + own history (2026-07-13).
-- Run once. Idempotent.
--
-- Fixes: (1) the overview "New broadcast" was gated on tournament participants
-- only, so an organizer with community members but no entrants couldn't send;
-- (2) organizers seeing the platform-wide Broadcasts list. Now an organizer
-- broadcast reaches their community members AND event participants, is logged to
-- organizer_broadcasts (their own history), and reach counts both.
-- ============================================================================

create table if not exists public.organizer_broadcasts (
  id            uuid primary key default gen_random_uuid(),
  organizer_id  uuid not null references public.profiles(id) on delete cascade,
  tournament_id uuid references public.tournaments(id) on delete set null,
  title         text not null,
  body          text,
  recipients    int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists idx_org_broadcasts_owner on public.organizer_broadcasts (organizer_id, created_at desc);
alter table public.organizer_broadcasts enable row level security;
do $$ begin
  create policy "org_broadcasts: owner read" on public.organizer_broadcasts for select
    using (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

-- Recipients = the organizer's community members + non-withdrawn entrants across
-- their events (or a single event when p_tournament_id is given). Logs + sends.
create or replace function public.organizer_broadcast(
  p_title text, p_body text, p_tournament_id uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ids uuid[]; v_n int;
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
    -- whole-community broadcast (only when not scoped to one tournament)
    select cm.player_id
      from public.community_members cm
     where p_tournament_id is null
       and cm.community_id in (select id from public.communities where organizer_id = v_uid)
  ) u where pid is not null;

  v_n := coalesce(array_length(v_ids, 1), 0);
  if v_n = 0 then return 'No one to reach yet — get community members or event entrants first.'; end if;

  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'broadcast', p_title, nullif(btrim(p_body), ''),
         jsonb_build_object('from', 'organizer')
    from unnest(v_ids) as uid;

  insert into public.organizer_broadcasts (organizer_id, tournament_id, title, body, recipients)
  values (v_uid, p_tournament_id, p_title, nullif(btrim(p_body), ''), v_n);
  return null;
end $$;
grant execute on function public.organizer_broadcast(text, text, uuid) to authenticated;

-- reach now also counts community members (not just event entrants).
create or replace function public.organizer_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return json_build_object('error', 'not_organizer');
  end if;
  return json_build_object(
    'tournaments', (select count(*) from tournaments where organizer_id = v_uid),
    'accepting',   (select count(*) from tournaments
                     where organizer_id = v_uid and status in ('open','upcoming')),
    'entrants',    (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'reach',       (select count(distinct pid) from (
                       select te.player_id pid from tournament_entries te
                        where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                          and te.status not in ('withdrawn','cancelled')
                       union
                       select cm.player_id from community_members cm
                        where cm.community_id in (select id from communities where organizer_id = v_uid)) u),
    'fees',        (select coalesce(sum(coalesce(paid_amount,0)),0) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'paid'),
    'to_verify',   (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'pending'),
    'largest_event', (select coalesce(max(cnt), 0) from (
                       select te.tournament_id, count(*) cnt from tournament_entries te
                        where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                          and te.status not in ('withdrawn','cancelled')
                        group by te.tournament_id) x),
    'open_rate',   (select case when count(*) = 0 then 0
                       else round(100.0 * count(*) filter (where n.read) / count(*)) end
                     from notifications n
                    where n.type = 'community'
                      and n.data->>'community_id' in
                          (select id::text from communities where organizer_id = v_uid))
  );
end $$;
grant execute on function public.organizer_overview() to authenticated;

notify pgrst, 'reload schema';
