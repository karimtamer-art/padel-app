-- ============================================================================
-- Profile avatars storage bucket (2026-07-13)
-- ----------------------------------------------------------------------------
-- Enables the "Add photo" step in sign-up onboarding. Public read (so the
-- avatar_url renders everywhere); each user may write only inside their own
-- `<uid>/…` folder. Idempotent — safe to re-run. Also folded into
-- migration_player_app.sql (after the product-images bucket).
-- ============================================================================

insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do update set public = true;

drop policy if exists "avatars owner write" on storage.objects;
create policy "avatars owner write" on storage.objects
  for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
