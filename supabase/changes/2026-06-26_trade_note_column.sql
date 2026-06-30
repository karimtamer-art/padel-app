-- Fix trade-in submit (2026-06-26)
-- The live trade_requests table (migration 0003) has a `notes` column but the
-- app writes `note`, so every trade-in submission failed with
-- "column note of relation trade_requests does not exist". Add it. Idempotent.

alter table public.trade_requests add column if not exists note text;
