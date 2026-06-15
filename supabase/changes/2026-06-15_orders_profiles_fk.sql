-- ============================================================
-- Incremental change · 2026-06-15
-- Named FK orders.player_id -> profiles.id (for the admin name join)
-- ------------------------------------------------------------
-- PostgREST embeds the customer name via the hint
-- `profiles!orders_player_id_fkey`. The live (drifted) orders table never got
-- this named constraint, so the join errored (PGRST200) and admin fell back to
-- 'Unknown'. Add it, then reload the schema cache. Also in the canonical
-- supabase/migration_player_app.sql. Idempotent.
--
-- If this errors with a foreign-key violation, an order row has a player_id
-- with no matching profile — find it with:
--   select * from public.orders o
--   where not exists (select 1 from public.profiles p where p.id = o.player_id);
-- ============================================================

do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'orders_player_id_fkey'
  ) then
    alter table public.orders
      add constraint orders_player_id_fkey
      foreign key (player_id) references public.profiles(id);
  end if;
end $$;

notify pgrst, 'reload schema';
