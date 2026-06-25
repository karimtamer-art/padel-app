-- Trade-In: wire the player flow + admin console to the DB.
--
-- trade_requests already had RLS enabled with only own-read + own-insert
-- policies and NO table GRANT, so:
--   • player submissions were rejected ("permission denied for table
--     trade_requests") — the old stub silently swallowed the error;
--   • admins could neither see other players' requests nor send offers.
--
-- This adds admin read/update policies + the table-level privilege, plus the
-- named FK PostgREST needs for the admin join. Idempotent; safe to re-run.

alter table public.trade_requests enable row level security;

do $$ begin
  create policy "own trades read" on public.trade_requests for select using (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "create own trade" on public.trade_requests for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "trades: admin read" on public.trade_requests for select using (public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "trades: admin update" on public.trade_requests for update
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;

grant select, insert, update on public.trade_requests to authenticated;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'trade_requests_player_id_fkey') then
    alter table public.trade_requests
      add constraint trade_requests_player_id_fkey
      foreign key (player_id) references public.profiles(id);
  end if;
end $$;
