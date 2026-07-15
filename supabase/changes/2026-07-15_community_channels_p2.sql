-- 2026-07-15 · Community channels Phase 2 — auto event channels + lifecycle
--
-- Tournaments auto-spawn an event channel in their organizer's community. The
-- ticket lifecycle (active → grace → archived) is DERIVED from ends_at, so it
-- needs no cron to display correctly; pg_cron is used only to physically delete
-- channels 30 days after archiving.
--   active   : now < ends_at
--   grace    : ends_at ≤ now < ends_at + 24h   (still read/write)
--   archived : now ≥ ends_at + 24h             (read-only, purged after 30d)
--
-- Phase 2 = tournament channels + lifecycle. Per-channel post permissions and
-- the organizer console (custom channels, casual-match toggle) are Phase 3;
-- every channel is post='all' here.
--
-- Idempotent. Also folded into migration_player_app.sql.

alter table public.community_channels add column if not exists kind    text not null default 'community';
alter table public.community_channels add column if not exists event_id uuid;
alter table public.community_channels add column if not exists ends_at  timestamptz;
create unique index if not exists uq_community_channels_event
  on public.community_channels (community_id, event_id);

-- A tournament creates an event channel in its organizer's community.
create or replace function public.tg_event_channel()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cid uuid; v_name text; v_ends timestamptz;
begin
  if new.organizer_id is null then return new; end if;
  select id into v_cid from public.communities where organizer_id = new.organizer_id limit 1;
  if v_cid is null then return new; end if;

  v_name := trim(both '-' from lower(regexp_replace(coalesce(new.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then v_name := 'event-' || left(new.id::text, 8); end if;
  -- Avoid clashing with an existing channel name in this community.
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    v_name := v_name || '-' || left(new.id::text, 4);
  end if;

  v_ends := (coalesce(new.end_date, new.start_date)::timestamptz) + interval '1 day';

  insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
  values (v_cid, v_name, 'tournament', new.id, v_ends, 'all', 100)
  on conflict (community_id, event_id) do nothing;
  return new;
end $$;
drop trigger if exists trg_event_channel on public.tournaments;
create trigger trg_event_channel after insert on public.tournaments
  for each row execute function public.tg_event_channel();

-- Backfill event channels for existing tournaments.
do $$
declare r record; v_cid uuid; v_name text; v_ends timestamptz;
begin
  for r in select id, organizer_id, name, start_date, end_date
             from public.tournaments where organizer_id is not null loop
    select id into v_cid from public.communities where organizer_id = r.organizer_id limit 1;
    if v_cid is null then continue; end if;
    if exists (select 1 from public.community_channels
                where community_id = v_cid and event_id = r.id) then
      continue;
    end if;
    v_name := trim(both '-' from lower(regexp_replace(coalesce(r.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
    if v_name = '' then v_name := 'event-' || left(r.id::text, 8); end if;
    if exists (select 1 from public.community_channels
                where community_id = v_cid and name = v_name) then
      v_name := v_name || '-' || left(r.id::text, 4);
    end if;
    v_ends := (coalesce(r.end_date, r.start_date))::timestamptz + interval '1 day';
    insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
    values (v_cid, v_name, 'tournament', r.id, v_ends, 'all', 100)
    on conflict (community_id, event_id) do nothing;
  end loop;
end $$;

-- Block posting to an archived event channel (server-side).
drop policy if exists "community_chat: member write" on public.community_chat;
create policy "community_chat: member write" on public.community_chat for insert
  with check (
    sender_id = auth.uid()
    and (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id and c.organizer_id = auth.uid())
    )
    and not exists (
      select 1 from public.community_channels ch
       where ch.id = community_chat.channel_id
         and ch.kind <> 'community'
         and ch.ends_at is not null
         and now() >= ch.ends_at + interval '24 hours'
    )
  );

-- Channel list now returns kind/state/event fields (return type changed → drop first).
drop function if exists public.community_channel_list(uuid);
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, kind text, state text,
  event_id uuid, going int, preview text, last_at timestamptz
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

-- Physical cleanup 30 days after archiving (needs pg_cron; harmless if it never
-- runs — archived channels just linger read-only).
create or replace function public.purge_archived_channels()
returns void language sql security definer set search_path = public as $$
  delete from public.community_channels
   where kind <> 'community' and ends_at is not null
     and now() >= ends_at + interval '24 hours' + interval '30 days';
$$;
do $$ begin
  perform cron.schedule('padel-purge-channels', '0 4 * * *', 'select public.purge_archived_channels()');
exception when others then
  raise notice 'pg_cron not available for channel purge — archived channels linger harmlessly; call purge_archived_channels() manually or via an Edge Function schedule.';
end $$;

notify pgrst, 'reload schema';
