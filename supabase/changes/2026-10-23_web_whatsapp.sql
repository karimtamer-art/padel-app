-- ============================================================
-- 2026-10-23 · WhatsApp confirmation for website registrations
-- ============================================================
-- When staff press "Add to draw", the console calls the `whatsapp-confirm`
-- Edge Function, which sends an approved WhatsApp template to the player (and
-- their partner) and records the outcome here. Written by the function with
-- the service role only — no client grant, so the console can't fake "sent".
--
-- wa_status: NULL = never tried · 'sent' · 'failed' (wa_error says why)
-- Safe to re-run. Needs 2026-10-20_web_registrations.sql.
-- ============================================================

alter table public.web_registrations add column if not exists wa_status  text;
alter table public.web_registrations add column if not exists wa_error   text;
alter table public.web_registrations add column if not exists wa_sent_at timestamptz;

do $$ begin
  alter table public.web_registrations drop constraint if exists web_registrations_wa_chk;
  alter table public.web_registrations add constraint web_registrations_wa_chk
    check (wa_status is null or wa_status in ('sent', 'failed'));
exception when others then null; end $$;

-- ── verify ──────────────────────────────────────────────────────────────────
-- select name, phone, wa_status, wa_error, wa_sent_at
--   from public.web_registrations order by created_at desc limit 10;
