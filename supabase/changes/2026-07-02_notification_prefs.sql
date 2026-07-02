-- 2026-07-02 — Notification push preferences + inbox retention.
--
-- 1. Per-user push toggles on profiles (all default ON so existing users keep
--    getting push). Honoured by the push-notify Edge Function, which skips the
--    FCM send when the recipient has the relevant toggle off. In-app inbox rows
--    are still inserted regardless — the toggles gate the *push alert* only.
-- 2. A delete policy on notifications so the client can prune its own rows past
--    the 30-day retention window (NotificationService.pruneOld()).
--
-- Safe to re-run.

-- 1. Push preference columns ------------------------------------------------
alter table public.profiles
  add column if not exists notify_push       boolean not null default true,
  add column if not exists notify_match      boolean not null default true,
  add column if not exists notify_tournament boolean not null default true,
  add column if not exists notify_order      boolean not null default true;

-- 2. Let users delete their own notifications (for client-side pruning) ------
do $$ begin
  create policy "notifications: own delete" on public.notifications
    for delete using (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
grant delete on public.notifications to authenticated;
