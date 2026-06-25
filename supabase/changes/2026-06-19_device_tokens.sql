-- FCM device tokens for push. A pre-migration drift `device_tokens` table may
-- exist, so columns are added idempotently. Safe to re-run.

create table if not exists public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete cascade,
  token      text not null,
  platform   text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.device_tokens add column if not exists user_id    uuid references public.profiles(id) on delete cascade;
alter table public.device_tokens add column if not exists token      text;
alter table public.device_tokens add column if not exists platform   text not null default 'android';
alter table public.device_tokens add column if not exists created_at timestamptz not null default now();
alter table public.device_tokens add column if not exists updated_at timestamptz not null default now();

create unique index if not exists device_tokens_token_key on public.device_tokens (token);
create index if not exists idx_device_tokens_user on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;
drop policy if exists "device_tokens: own" on public.device_tokens;
create policy "device_tokens: own" on public.device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update, delete on public.device_tokens to authenticated;

drop trigger if exists trg_device_tokens_touch on public.device_tokens;
create trigger trg_device_tokens_touch before update on public.device_tokens
  for each row execute function public.touch_updated_at();
