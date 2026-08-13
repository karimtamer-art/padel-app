-- ===========================================================================
-- payout_accounts — move payout handles off `profiles` (2026-08-14)
--
-- WHY. `profiles` had grown into a catch-all: identity, preferences, ranking
-- state, RBAC and payout details all in one row. `instapay_handle` /
-- `instapay_link` are the clearest case of something that does not describe a
-- person — they describe where an ORGANIZER gets paid, they apply to at most a
-- few percent of rows, and they are the sort of field that multiplies (Fawry,
-- Paymob, a bank account) the moment a second payment rail is added.
--
-- SCOPE. Only the two profile columns move. The other `instapay_*` columns in
-- the schema stay exactly where they are, because they are a different thing:
--
--   tournament_entries.instapay_sender / instapay_proof_url
--   orders.instapay_sender / instapay_proof_url
--
-- Those are EVIDENCE OF ONE PAYMENT — who sent it and the screenshot — and
-- belong on the transaction they prove, not in a directory of accounts.
--
-- SHAPE. Keyed on (player_id, provider) rather than player_id alone. Today
-- there is exactly one provider and the extra column looks like ceremony; the
-- alternative is that adding Fawry means either a second table or a second
-- pair of columns, which is the mistake being undone here. `provider` has no
-- CHECK constraint on purpose — a new rail should be a row, not a migration.
--
-- Idempotent, and the old columns are NOT dropped in this file. See section 5.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The table.
-- ---------------------------------------------------------------------------
create table if not exists public.payout_accounts (
  player_id  uuid        not null references public.profiles(id) on delete cascade,
  provider   text        not null default 'instapay',
  -- The payout address itself, e.g. 'karim@instapay'. NOT normalised here:
  -- InstaPay addresses can be issued against a bank ('name@cib'), so forcing
  -- an @instapay suffix in the database would break those transfers. The
  -- client owns that rule (AdminService.normalizeInstapay).
  handle     text,
  -- Optional deep link the payer can open instead of copying the handle.
  link       text,
  updated_at timestamptz not null default now(),
  primary key (player_id, provider)
);

comment on table public.payout_accounts is
  'Where an organizer gets paid. One row per (player, provider). Payment '
  'EVIDENCE lives on the transaction (tournament_entries / orders), not here.';

-- ---------------------------------------------------------------------------
-- 2. Backfill from the columns being retired. Only rows that actually carry
--    something — a NULL handle and a NULL link is not an account.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles'
                and column_name = 'instapay_handle') then
    insert into public.payout_accounts (player_id, provider, handle, link)
    select p.id, 'instapay',
           nullif(btrim(p.instapay_handle), ''),
           nullif(btrim(p.instapay_link), '')
      from public.profiles p
     where nullif(btrim(p.instapay_handle), '') is not null
        or nullif(btrim(p.instapay_link), '')   is not null
    on conflict (player_id, provider) do nothing;
    raise notice 'payout_accounts: backfilled % row(s)',
      (select count(*) from public.payout_accounts);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. RLS. A payout handle is not secret — a player about to transfer money
--    has to see it — but only its owner may WRITE it, and reads go through
--    tournament_pay_info (SECURITY DEFINER) so nobody can enumerate the table
--    to build a list of organizers' payment addresses.
-- ---------------------------------------------------------------------------
alter table public.payout_accounts enable row level security;

do $$ begin
  create policy "payout: read own" on public.payout_accounts
    for select using (player_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "payout: write own" on public.payout_accounts
    for all using (player_id = auth.uid() or public._is_admin())
    with check (player_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

grant select, insert, update, delete on public.payout_accounts to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The two functions that touched the old columns.
-- ---------------------------------------------------------------------------

-- Organizer (or admin) sets their own payout username + link; applies to every
-- event they own. Returns null on success, or an error string.
create or replace function public.set_my_instapay(p_handle text, p_link text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_handle text; v_link text;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  v_handle := nullif(btrim(p_handle), '');
  v_link   := nullif(btrim(p_link), '');

  if v_handle is null and v_link is null then
    -- clearing both is how an organizer removes their payout details
    delete from public.payout_accounts
     where player_id = auth.uid() and provider = 'instapay';
    return null;
  end if;

  insert into public.payout_accounts (player_id, provider, handle, link)
  values (auth.uid(), 'instapay', v_handle, v_link)
  on conflict (player_id, provider) do update
    set handle = excluded.handle,
        link   = excluded.link,
        updated_at = now();
  return null;
end $$;
grant execute on function public.set_my_instapay(text, text) to authenticated;

-- The InstaPay details a player transfers to for a given tournament: the
-- owning organizer's handle/link if set, else the platform-wide app_settings
-- handle, else a hard default. SECURITY DEFINER so it reads across tables.
create or replace function public.tournament_pay_info(p_tournament_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'handle', coalesce(
      nullif(btrim(pa.handle), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_handle')), ''),
      'padelpro@instapay'),
    -- The link resolves the same way as the handle: organizer, then platform.
    'link', coalesce(
      nullif(btrim(pa.link), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_link')), '')))
    from public.tournaments t
    left join public.payout_accounts pa
      on pa.player_id = t.organizer_id and pa.provider = 'instapay'
   where t.id = p_tournament_id;
$$;
grant execute on function public.tournament_pay_info(uuid) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 5. Retiring the old columns — DELIBERATELY NOT IN THIS FILE.
--
--    Dropping them in the same delta that starts reading the new table means
--    an app build still running the old client loses payout details the moment
--    this runs. The columns are harmless once nothing reads them, so they come
--    out in a follow-up once the new client is live:
--
--      alter table public.profiles drop column if exists instapay_handle;
--      alter table public.profiles drop column if exists instapay_link;
--
--    Until then they sit there stale. Nothing writes them any more, so do not
--    trust them — payout_accounts is the source of truth from this point.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_proc
              where pronamespace = 'public'::regnamespace
                and proname in ('set_my_instapay','tournament_pay_info')
                and prosrc like '%instapay_handle%'
                and prosrc not like '%app_settings%') then
    raise exception 'a payout function still reads profiles.instapay_handle';
  end if;
  raise notice 'payout_accounts is live; profiles.instapay_* is now stale.';
end $$;

notify pgrst, 'reload schema';
