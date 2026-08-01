-- ============================================================================
-- INSTAPAY LINK — PLATFORM FALLBACK  (2026-08-01)
--
-- InstaPay payout is a PAIR: a handle and an optional payment link. The handle
-- already fell back organizer → platform → default, but the link only ever read
-- the organizer's own, so a platform-wide link could never reach a payer.
--
-- Now both halves resolve the same way. Nothing else changes.
--
-- Safe to re-run.
-- ============================================================================

create or replace function public.tournament_pay_info(p_tournament_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'handle', coalesce(
      nullif(btrim(p.instapay_handle), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_handle')), ''),
      'padelpro@instapay'),
    'link', coalesce(
      nullif(btrim(p.instapay_link), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_link')), '')))
    from public.tournaments t
    left join public.profiles p on p.id = t.organizer_id
   where t.id = p_tournament_id;
$$;
grant execute on function public.tournament_pay_info(uuid) to authenticated, anon;

notify pgrst, 'reload schema';
