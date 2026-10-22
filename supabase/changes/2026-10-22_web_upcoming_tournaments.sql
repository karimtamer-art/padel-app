-- ============================================================
-- 2026-10-22 · Website: "Coming soon" tournaments
-- ⚠️ Run 2026-10-22_one_level_setting.sql after this one; it redefines this
-- function to read levels from min_rating/max_rating.
-- ============================================================
-- web_open_tournaments() hides an event until its registration_opens day, so
-- an announced tournament was invisible on padel-rivals.com — it read as "the
-- site isn't connected to the app". This lists those events, read-only, so the
-- page can show "Registration opens 25 Oct" with no form.
--
-- A SEPARATE function on purpose: web_register() checks eligibility by
-- selecting from web_open_tournaments(), so widening that one would let the
-- website take entries before registration opens.
--
-- Same gates as web_open_tournaments() otherwise (not cancelled/finished,
-- Egypt, not closed early, not started). Anon gets EXECUTE, no table grant.
-- Safe to re-run. Needs 2026-10-20_web_registrations.sql first.
-- ============================================================

create or replace function public.web_upcoming_tournaments()
returns table (
  id uuid, name text, venue_name text, start_date date, start_time text,
  entry_fee numeric, category text, min_category text, max_category text,
  registration_opens date)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select t.id, t.name, t.venue_name, t.start_date, t.start_time,
         coalesce(t.entry_fee, 0)::numeric, coalesce(t.category, 'open'),
         t.min_category, t.max_category, t.registration_opens
    from public.tournaments t
   where coalesce(t.status, 'auto') not in ('cancelled', 'completed', 'in_progress')
     and coalesce(t.region_id, 'EG') = 'EG'
     and t.registration_opens is not null
     and t.registration_opens > current_date
     and not coalesce(t.registration_closed, false)
     and t.start_date >= current_date
   order by t.registration_opens, t.start_date;
end $$;
revoke all on function public.web_upcoming_tournaments() from public;
grant execute on function public.web_upcoming_tournaments() to anon, authenticated;

-- ── verify ──────────────────────────────────────────────────────────────────
-- select * from public.web_upcoming_tournaments();   -- events not open yet
