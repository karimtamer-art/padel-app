-- ROLLBACK for 2026-11-02_match_info_fields.sql. Only run this to undo it.
-- Removes the RPC and clears 'live' but KEEPS the columns: dropping them would lose
-- courts, draw times and addresses typed in, and the app hides empty fields anyway.
-- Only if you really want the columns gone too, run the commented lines.

drop function if exists public.admin_set_match_info(uuid, text, boolean);
update public.tournament_matches set result_status = 'open' where result_status = 'live';

-- alter table public.tournament_matches drop column if exists court;
-- alter table public.tournaments drop column if exists draw_at;
-- alter table public.tournaments drop column if exists venue_address;

-- VERIFY: must return true.
select to_regproc('public.admin_set_match_info') is null
       and not exists (select 1 from public.tournament_matches where result_status = 'live')
       as match_info_rolled_back;
