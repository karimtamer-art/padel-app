-- ============================================================================
-- Self-service account deletion RPC (2026-07-13)
-- ----------------------------------------------------------------------------
-- Backs the in-app "Delete Account" button and the Google Play data-deletion
-- requirement. A signed-in user permanently deletes their own account + data.
--
-- SECURITY DEFINER so it can delete the auth.users row (which cascades profiles
-- and everything that cascades from profiles). The live schema has several
-- NOT NULL foreign keys straight to auth.users (matches.created_by,
-- match_players.player_id, orders.player_id, tournament_entries.player_id) that
-- would otherwise block the delete, so they are cleared first in dependency
-- order. Tournaments / courts the user owns are ON DELETE SET NULL (kept,
-- de-identified). Idempotent — safe to re-run. Also folded into
-- migration_player_app.sql.
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

  begin
    update public.ranking_history set match_id = null
     where match_id in (select id from public.matches where created_by = uid);
  exception when undefined_table or undefined_column then null; end;
  begin
    delete from public.matches where created_by = uid;
  exception when undefined_table or undefined_column then null; end;

  begin delete from public.match_players where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

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

  begin delete from public.orders where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

  begin
    delete from auth.users where id = uid;
  exception when foreign_key_violation then
    raise exception 'Account still has linked records that block deletion: %', sqlerrm;
  end;
end
$$;
grant execute on function public.delete_account_self() to authenticated;

notify pgrst, 'reload schema';
