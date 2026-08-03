-- 2026-08-03 — Trade-ins: photos of the racket.
-- Admins had to price a trade-in from a text description alone ("Adidas
-- Adipower Ctrl 3.2", condition "Good") with nothing to look at, so the
-- inspection step was doing all the work. Players now attach 1–4 photos and
-- the Requests console shows them.
--
-- Storage paths (not URLs) are stored, same as payment-proofs: the bucket is
-- private and the console signs each path to view it.
--
-- Safe to re-run.

-- 1) The column. text[] so the order the player picked is preserved.
alter table public.trade_requests
  add column if not exists photos text[] not null default '{}';

-- 2) Private bucket for the racket shots.
insert into storage.buckets (id, name, public)
  values ('trade-photos', 'trade-photos', false)
  on conflict (id) do update set public = false;

-- Players write only inside their own <uid>/ folder.
drop policy if exists "trade-photos owner write" on storage.objects;
create policy "trade-photos owner write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'trade-photos'
              and (storage.foldername(name))[1] = auth.uid()::text);

-- The owner can see their own; requests staff can see all of them.
drop policy if exists "trade-photos read" on storage.objects;
create policy "trade-photos read" on storage.objects
  for select to authenticated
  using (bucket_id = 'trade-photos'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public._has_access('requests')));

-- 3) Account deletion already wipes payment-proofs; do the same for the
--    player's racket photos so nothing of theirs is left in storage.
--    (delete_account_self is re-created in full by the canonical migration —
--    this delta only needs the storage rows for anyone deleted meanwhile.)
