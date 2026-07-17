-- 2026-07-17 · Live updates for community channel chat.
--
-- Adds public.community_chat to the supabase_realtime publication so open
-- clients receive new posts the instant they're inserted (the channel screen
-- subscribes via CommunityService.channelStream). RLS still scopes delivery to
-- community members. No schema change, no push — realtime fan-out only.
--
-- Idempotent; also folded into migration_player_app.sql.

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'community_chat'
  ) then
    alter publication supabase_realtime add table public.community_chat;
  end if;
end $$;
