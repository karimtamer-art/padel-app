-- ============================================================================
-- PRIVACY / RETENTION  (2026-08-01)
--
-- Backs the published Privacy Policy. Two things it promises that the database
-- did not yet do:
--
-- 1. Deleting an account DELETED the customer's orders outright. That erased
--    the sale itself — the sales history and the revenue dashboard silently
--    changed, and the accounting record required for tax went with it. Orders
--    are now ANONYMISED instead: items, totals, status and date survive; the
--    customer link, delivery address, InstaPay sender and receipt image do not.
--    Account deletion also now removes the user's avatar and receipt images
--    from storage, which the policy states.
--
-- 2. Payment receipt images are kept for 12 months after an order completes,
--    then deleted — after that the order row is the financial evidence and
--    there is no reason to hold an image of someone's bank screen.
--
-- Safe to re-run.
-- ============================================================================

-- ── orders survive their customer ───────────────────────────────────────────
alter table public.orders alter column player_id drop not null;

-- Re-point the FK so a deleted profile leaves the order standing, unlinked.
do $$
declare v_con text;
begin
  select con.conname into v_con
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
   where ns.nspname = 'public' and rel.relname = 'orders'
     and con.contype = 'f'
     and pg_get_constraintdef(con.oid) like '%player_id%REFERENCES%profiles%'
   limit 1;
  if v_con is not null then
    execute format('alter table public.orders drop constraint %I', v_con);
  end if;
end $$;

do $$ begin
  alter table public.orders
    add constraint orders_player_id_fkey
    foreign key (player_id) references public.profiles(id) on delete set null;
exception when duplicate_object then null; end $$;

-- Marks an order whose customer deleted their account, so the console can say
-- so instead of showing a blank name.
alter table public.orders add column if not exists customer_deleted boolean not null default false;

-- ============================================================================
-- delete_account_self — unchanged except for orders (now anonymised, not
-- deleted) and the storage cleanup at the end.
-- ============================================================================
create or replace function public.delete_account_self()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in.';
  end if;

  -- 1. Matches the user created: drop the ranking-history link, then delete the
  --    matches (their match_players rows cascade on matches.id). Clears the
  --    NOT NULL matches.created_by -> auth.users blocker.
  begin
    update public.ranking_history set match_id = null
     where match_id in (select id from public.matches where created_by = uid);
  exception when undefined_table or undefined_column then null; end;
  begin
    delete from public.matches where created_by = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 2. The user's own participation rows (reference auth.users, no cascade).
  begin delete from public.match_players where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 3. Tournament entries — first detach any bracket slots that point at them.
  begin
    update public.tournament_matches m set
      entry1 = case when m.entry1 in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.entry1 end,
      entry2 = case when m.entry2 in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.entry2 end,
      winner_entry = case when m.winner_entry in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.winner_entry end
     where m.entry1 in (select id from public.tournament_entries where player_id = uid or partner_id = uid)
        or m.entry2 in (select id from public.tournament_entries where player_id = uid or partner_id = uid)
        or m.winner_entry in (select id from public.tournament_entries where player_id = uid or partner_id = uid);
  exception when undefined_table or undefined_column then null; end;
  begin delete from public.tournament_entries where player_id = uid or partner_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 4. Store orders — ANONYMISE, do not delete. The sale is our accounting
  --    record and must survive for the tax retention period; everything that
  --    identifies the customer is stripped from it here.
  begin
    delete from storage.objects
     where bucket_id = 'payment-proofs'
       and name in (select o.instapay_proof_url from public.orders o
                     where o.player_id = uid and o.instapay_proof_url is not null);
  exception when others then null; end;
  begin
    update public.orders set
      player_id          = null,
      address            = null,
      instapay_sender    = null,
      instapay_proof_url = null,
      customer_deleted   = true
    where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 5. Uploaded images that belong to the person, not to a record.
  begin
    delete from storage.objects
     where bucket_id = 'avatars' and name like uid::text || '/%';
  exception when others then null; end;
  begin
    delete from storage.objects
     where bucket_id = 'payment-proofs' and name like 'proofs/' || uid::text || '/%';
  exception when others then null; end;

  -- 6. Remove the auth user; profiles + all profile-cascade data go with it.
  begin
    delete from auth.users where id = uid;
  exception when others then
    delete from public.profiles where id = uid;
  end;
end $$;
grant execute on function public.delete_account_self() to authenticated;

-- ============================================================================
-- Receipt images are evidence of payment, not a permanent record. Twelve months
-- after an order reaches a final state the image goes; the order row remains.
-- ============================================================================
create or replace function public.prune_payment_proofs()
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int := 0;
begin
  delete from storage.objects
   where bucket_id = 'payment-proofs'
     and name in (
       select o.instapay_proof_url from public.orders o
        where o.instapay_proof_url is not null
          and o.status in ('delivered', 'cancelled', 'refunded')
          and o.created_at < now() - interval '12 months');
  update public.orders set instapay_proof_url = null
   where instapay_proof_url is not null
     and status in ('delivered', 'cancelled', 'refunded')
     and created_at < now() - interval '12 months';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.prune_payment_proofs() to authenticated;

do $$ begin
  perform cron.schedule('padel-prune-payment-proofs', '0 4 * * 0',
    'select public.prune_payment_proofs()');
exception when others then
  raise notice 'pg_cron not available — run prune_payment_proofs() manually.';
end $$;

notify pgrst, 'reload schema';
