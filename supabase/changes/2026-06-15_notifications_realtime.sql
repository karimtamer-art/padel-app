-- ============================================================
-- Incremental change · 2026-06-15
-- Enable Supabase Realtime for the notifications table
-- ------------------------------------------------------------
-- Lets the app's Home bell update live when a notification row is inserted
-- (RLS still applies to realtime, so each user only receives their own rows).
-- Also folded into the canonical supabase/migration_player_app.sql.
-- Idempotent — safe to re-run.
-- ============================================================

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
