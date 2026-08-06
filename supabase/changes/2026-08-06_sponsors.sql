-- ============================================================================
-- SPONSORS / PARTNERS  (2026-08-06)
--
-- The brands and clubs backing the platform, shown to players on a "Our
-- Partners" page (Home → Our Partners) and managed from a new admin console
-- section.
--
-- One flat table — no logic, no money. Sponsorship money that actually changes
-- hands is still recorded in the `income` ledger (category 'sponsorship'); this
-- table is the public shop window, deliberately kept separate so nobody is
-- tempted to hand-record a payment twice. See 2026-08-06_manual_income.sql.
--
-- Adds a grantable console section id 'sponsors', so `_role_default` and
-- kSections in lib/admin/data/roles_model.dart move together.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.sponsors (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  tagline     text,                 -- one line under the name, on the card
  blurb       text,                 -- longer copy, shown in the detail sheet
  logo_url    text,
  website_url text,
  tier        text not null default 'partner',
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Drift guards: if an earlier draft created the table, `create table if not
-- exists` above was a no-op and none of these columns would exist.
alter table public.sponsors add column if not exists name        text;
alter table public.sponsors add column if not exists tagline     text;
alter table public.sponsors add column if not exists blurb       text;
alter table public.sponsors add column if not exists logo_url    text;
alter table public.sponsors add column if not exists website_url text;
alter table public.sponsors add column if not exists tier        text not null default 'partner';
alter table public.sponsors add column if not exists is_active   boolean not null default true;
alter table public.sponsors add column if not exists sort_order  int not null default 0;
alter table public.sponsors add column if not exists created_at  timestamptz not null default now();
alter table public.sponsors add column if not exists updated_at  timestamptz not null default now();

-- Mirrors SponsorTier in lib/backend/services/sponsor_service.dart — change both.
alter table public.sponsors drop constraint if exists sponsors_tier_chk;
alter table public.sponsors add constraint sponsors_tier_chk check (
  tier in ('title', 'gold', 'silver', 'partner'));

create index if not exists sponsors_active_idx on public.sponsors (is_active, sort_order);

comment on table public.sponsors is
  'Brands and clubs shown on the player "Our Partners" page. Public shop '
  'window only — sponsorship money lives in the income ledger.';

alter table public.sponsors enable row level security;

-- Players read the active ones; the console reads everything it can edit.
drop policy if exists "sponsors: read active" on public.sponsors;
create policy "sponsors: read active" on public.sponsors for select
  using (is_active = true or public._has_access('sponsors'));

drop policy if exists "sponsors: admin write" on public.sponsors;
create policy "sponsors: admin write" on public.sponsors for all
  using (public._can_edit('sponsors')) with check (public._can_edit('sponsors'));

drop trigger if exists trg_sponsors_touch on public.sponsors;
create trigger trg_sponsors_touch before update on public.sponsors
  for each row execute function public.touch_updated_at();

grant select on public.sponsors to anon, authenticated;
grant select, insert, update, delete on public.sponsors to authenticated;

-- Public bucket for sponsor logos (public read; console writes).
insert into storage.buckets (id, name, public)
  values ('sponsor-logos', 'sponsor-logos', true)
  on conflict (id) do update set public = true;
drop policy if exists "sponsor-logos admin write" on storage.objects;
create policy "sponsor-logos admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'sponsor-logos' and public._can_edit('sponsors'))
  with check (bucket_id = 'sponsor-logos' and public._can_edit('sponsors'));

-- ── The new console section ────────────────────────────────────
-- Super Admin only by default; grantable to anyone from Team & Roles (that
-- writes profiles.admin_access, which _access_ids() reads back).
-- MUST stay in lockstep with kRoles in lib/admin/data/roles_model.dart.
create or replace function public._role_default(p_role text)
returns text[] language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin' then array['dashboard','reports','players','matches',
                                  'tournaments','formats','courts','store',
                                  'promotions','sponsors','payments','requests',
                                  'broadcasts','team']
    when 'organizer'   then array['tournaments','formats','courts','broadcasts']
    when 'support'     then array['players','matches','requests']
    when 'analyst'     then array['dashboard','reports']
    else '{}'::text[] end;
$$;
grant execute on function public._role_default(text) to authenticated;

notify pgrst, 'reload schema';
