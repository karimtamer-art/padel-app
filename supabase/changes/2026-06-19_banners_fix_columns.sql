-- Fix: a pre-migration drift `banners` table already existed, so the earlier
-- `create table if not exists` was a no-op and the new columns were never added
-- (PostgrestException 42703 "column discount_pct does not exist" on save).
-- Add every column idempotently. Safe to re-run.

alter table public.banners add column if not exists title        text;
alter table public.banners add column if not exists subtitle     text;
alter table public.banners add column if not exists image_url    text;
alter table public.banners add column if not exists bg_color     text;
alter table public.banners add column if not exists discount_pct int;
alter table public.banners add column if not exists is_active    boolean not null default true;
alter table public.banners add column if not exists sort_order   int not null default 0;
alter table public.banners add column if not exists created_at   timestamptz not null default now();
alter table public.banners add column if not exists updated_at   timestamptz not null default now();

-- ensure membership column + RLS/grants exist too (in case the drift table
-- predated them)
alter table public.products add column if not exists banner_id uuid references public.banners(id) on delete set null;
create index if not exists idx_products_banner on public.products (banner_id);

alter table public.banners enable row level security;
drop policy if exists "banners: read active" on public.banners;
create policy "banners: read active" on public.banners
  for select using (is_active = true or public._is_admin());
drop policy if exists "banners: admin write" on public.banners;
create policy "banners: admin write" on public.banners
  for all using (public._is_admin()) with check (public._is_admin());
grant select on public.banners to anon, authenticated;
grant select, insert, update, delete on public.banners to authenticated;
