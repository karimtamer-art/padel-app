-- ============================================================
-- Incremental change · 2026-06-16
-- In-app direct messages (player ↔ player DM) — Phase 2 of player contact
-- ------------------------------------------------------------
-- A conversation is one row per unordered player pair (player_a = least(uid),
-- player_b = greatest(uid)) so there's exactly one thread per pair. Only the
-- two participants can read the thread or its messages (RLS). Realtime on
-- direct_messages drives the live chat. Also folded into the canonical
-- migration. Idempotent.
-- ============================================================

create table if not exists public.conversations (
  id         uuid primary key default gen_random_uuid(),
  player_a   uuid not null references public.profiles(id) on delete cascade,
  player_b   uuid not null references public.profiles(id) on delete cascade,
  match_id   uuid references public.matches(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (player_a, player_b)
);

create table if not exists public.direct_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  text            text not null,
  sent_at         timestamptz not null default now()
);
create index if not exists idx_dm_conversation
  on public.direct_messages (conversation_id, sent_at);

-- RLS: only the two participants.
alter table public.conversations enable row level security;
do $$ begin
  create policy "conv: participant read" on public.conversations
    for select using (auth.uid() in (player_a, player_b));
exception when duplicate_object then null; end $$;
grant select on public.conversations to authenticated;

alter table public.direct_messages enable row level security;
do $$ begin
  create policy "dm: participant read" on public.direct_messages
    for select using (exists (
      select 1 from public.conversations c
      where c.id = conversation_id and auth.uid() in (c.player_a, c.player_b)));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "dm: participant send" on public.direct_messages
    for insert with check (sender_id = auth.uid() and exists (
      select 1 from public.conversations c
      where c.id = conversation_id and auth.uid() in (c.player_a, c.player_b)));
exception when duplicate_object then null; end $$;
grant select, insert on public.direct_messages to authenticated;

-- Atomically fetch (or create) the conversation for me + p_other. Security
-- definer so the insert isn't blocked by RLS; result is still RLS-scoped on read.
create or replace function public.get_or_create_conversation(
  p_other uuid, p_match_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_a uuid; v_b uuid; v_id uuid;
begin
  if v_uid is null or p_other is null or p_other = v_uid then return null; end if;
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

-- Realtime so messages appear live.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'direct_messages'
  ) then
    alter publication supabase_realtime add table public.direct_messages;
  end if;
end $$;

notify pgrst, 'reload schema';
