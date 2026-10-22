-- ============================================================
-- 2026-10-22 · One level setting: website categories come from the rating
-- ============================================================
-- Until now a tournament had TWO level settings that could disagree: the
-- app's min_rating / max_rating (0-7) and the website's hand-set
-- min_category / max_category (D Low … A Upper). The website now DERIVES its
-- categories from min_rating / max_rating, and the category columns go.
--
--   Level      Category        Level      Category
--   1.0-1.5    D Low           4.0-4.5    B Low
--   1.5-2.0    D Mid           4.5-5.0    B Mid
--   2.0-2.5    D Upper         5.0-5.5    B Upper
--   2.5-3.0    C Low           5.5-6.0    A Low
--   3.0-3.5    C Mid           6.0-6.5    A Mid
--   3.5-4.0    C Upper         6.5-7.0    A Upper
--
-- e.g. a tournament set to 2.50-4.50 in the console shows "C Low to B Low".
-- The RPCs keep their min_category / max_category OUTPUT names, so the
-- website code needs no change and web_register keeps checking against them.
--
-- Run AFTER 2026-10-20_web_registrations.sql and
-- 2026-10-22_web_upcoming_tournaments.sql. Safe to re-run. Any values typed
-- into min_category / max_category are discarded — set levels in the console.
-- ============================================================

-- Category bands from the 0-7 level range. Band i (1..12) covers
-- [0.5 + 0.5*i, 1.0 + 0.5*i). Min level → the band it falls in (2.5 → C Low);
-- max level → the band that ENDS at it (4.5 → B Low, 4.7 → B Mid), so the
-- website never offers a category wholly above the app's limit.
-- No limit (min <= 1.0, max null or >= 7.0) → NULL, which reads as "any".
create or replace function public._web_level_from_min(p numeric)
returns text language sql immutable as $$
  select case when p is null or p <= 1.0 then null
              else (public.web_levels())[least(12, greatest(1, floor((p - 1.0) / 0.5)::int + 1))]
         end;
$$;
create or replace function public._web_level_from_max(p numeric)
returns text language sql immutable as $$
  select case when p is null or p >= 7.0 then null
              else (public.web_levels())[least(12, greatest(1, ceil((p - 1.0) / 0.5)::int))]
         end;
$$;


create or replace function public.web_open_tournaments()
returns table (
  id uuid, name text, venue_name text, start_date date, start_time text,
  entry_fee numeric, category text, min_category text, max_category text,
  spots_left int)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select t.id, t.name, t.venue_name, t.start_date, t.start_time,
         coalesce(t.entry_fee, 0)::numeric, coalesce(t.category, 'open'),
         public._web_level_from_min(t.min_rating), public._web_level_from_max(t.max_rating),
         case when coalesce(t.capacity, 0) <= 0 then null
              else greatest(0, t.capacity
                - (select count(*) from public.tournament_entries e
                    where e.tournament_id = t.id and e.status not in ('withdrawn', 'cancelled'))
                -- a pair takes a slot; two solo players make one pair
                - (select count(*) filter (where not w.needs_partner)
                          + ceil(count(*) filter (where w.needs_partner) / 2.0)
                     from public.web_registrations w
                    where w.tournament_id = t.id and w.status in ('pending', 'confirmed'))
                )::int
         end
    from public.tournaments t
   where coalesce(t.status, 'auto') not in ('cancelled', 'completed', 'in_progress')
     and coalesce(t.region_id, 'EG') = 'EG'
     and (t.registration_opens is null or current_date >= t.registration_opens)
     and not coalesce(t.registration_closed, false)
     and t.start_date >= current_date
     and (public.tournament_reg_deadline(t.start_date, t.start_time) is null
          or now() < public.tournament_reg_deadline(t.start_date, t.start_time))
   order by t.start_date, t.start_time nulls last;
end $$;
revoke all on function public.web_open_tournaments() from public;
grant execute on function public.web_open_tournaments() to anon, authenticated;

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
         public._web_level_from_min(t.min_rating), public._web_level_from_max(t.max_rating),
         t.registration_opens
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

-- The hand-set category columns (2026-10-20) were a second level setting that
-- could disagree with the app's. Dropped; their CHECK goes with them.
alter table public.tournaments drop column if exists min_category;
alter table public.tournaments drop column if exists max_category;

-- ── verify ──────────────────────────────────────────────────────────────────
-- select name, min_rating, max_rating,
--        public._web_level_from_min(min_rating) as web_from,
--        public._web_level_from_max(max_rating) as web_to
--   from public.tournaments order by start_date desc limit 10;
-- select * from public.web_open_tournaments();
-- select * from public.web_upcoming_tournaments();
-- -- expect 0 rows (columns gone):
-- select column_name from information_schema.columns
--  where table_name = 'tournaments' and column_name like '%_category';
