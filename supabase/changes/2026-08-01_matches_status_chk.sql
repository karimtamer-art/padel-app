-- ============================================================================
-- 2026-08-01 — matches.status check constraint accepts 'pending_confirm'
--
-- Symptom: submitting a score on a ranked/competitive match failed with
--     new row for relation "matches" violates check constraint "matches_status_chk"
--
-- Cause: the live constraint comes from migration 0003 and only allows
--     ('open','full','in_progress','completed','cancelled','disputed')
-- but the status machine added 'pending_confirm' afterwards, and
-- submit_match_result writes it for every ranked match:
--     status = case when v_type = 'ranked' then 'pending_confirm' else 'completed' end
-- Casual matches go straight to 'completed', which is why only ranked
-- submissions failed.
--
-- No data migration needed: every value the old constraint allowed is still
-- allowed, so existing rows pass. Safe to re-run. Also folded into
-- migration_player_app.sql.
-- ============================================================================

alter table public.matches drop constraint if exists matches_status_chk;
alter table public.matches add constraint matches_status_chk
  check (status in ('open','full','in_progress','pending_confirm',
                    'completed','cancelled','disputed'));

-- Sanity check — should return no rows.
-- select id, status from public.matches
--  where status not in ('open','full','in_progress','pending_confirm',
--                       'completed','cancelled','disputed');
