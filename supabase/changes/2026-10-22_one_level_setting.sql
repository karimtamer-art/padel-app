-- ============================================================
-- 2026-10-22 · One level setting: website categories come from the rating
-- ============================================================
-- Until now a tournament had TWO level settings that could disagree: the
-- app's min_rating / max_rating (0-7) and the website's hand-set
-- min_category / max_category (D Low … A Upper). The website now DERIVES its
-- categories from min_rating / max_rating, and the category columns go.
--
--   Division   Level      Low / Mid / Upper
--   D          0.0-1.9    0.0-0.6 / 0.7-1.2 / 1.3-1.9
--   C          2.0-3.4    2.0-2.4 / 2.5-2.9 / 3.0-3.4
--   B          3.5-4.9    3.5-3.9 / 4.0-4.4 / 4.5-4.9
--   A          5.0-7.0    5.0-5.6 / 5.7-6.3 / 6.4-7.0
--
-- These are the APP's division bands (RankingScale), so a player is the same
-- category on the website and in the app ("B Mid"). e.g. a tournament set to
-- 2.50-4.50 in the console shows "C Mid to B Upper".
-- The RPCs keep their min_category / max_category OUTPUT names, so the
-- website code needs no change and web_register keeps checking against them.
--
-- Run AFTER 2026-10-20_web_registrations.sql and
-- 2026-10-22_web_upcoming_tournaments.sql. Safe to re-run. Any values typed
-- into min_category / max_category are discarded — set levels in the console.
-- ============================================================

-- A level's category, on the APP's division bands so a player is the same
-- letter on the website and in the app: D 0.0-1.9, C 2.0-3.4, B 3.5-4.9,
-- A 5.0-7.0, each split into Low / Mid / Upper thirds. Exact mirror of
-- RankingScale.divisionFor + tierFor (lib/backend/models/ranking_scale.dart)
-- — change both. A level in a gap (1.95) belongs to the division above, at Low.
create or replace function public._web_level_of(p numeric)
returns text language sql immutable as $$
  with d as (
    select case when p <= 1.9 then 0 when p <= 3.4 then 1 when p <= 4.9 then 2 else 3 end as i
  ), b as (
    select i, (array[0.0, 2.0, 3.5, 5.0])[i + 1] as lo, (array[1.9, 3.4, 4.9, 7.0])[i + 1] as hi from d
  ), f as (
    select i, least(1.0, greatest(0.0, (p - lo) / (hi - lo))) as f from b
  )
  select (public.web_levels())[i * 3 + case when f < 1.0 / 3 then 1 when f < 2.0 / 3 then 2 else 3 end]
    from f;
$$;
-- A tournament's range → the categories the website offers. No limit
-- (min <= 0, max null or >= 7.0) → NULL, which reads as "any".
-- e.g. 2.50-4.50 → C Mid to B Upper.
create or replace function public._web_level_from_min(p numeric)
returns text language sql immutable as $$
  select case when p is null or p <= 0 then null else public._web_level_of(p) end;
$$;
create or replace function public._web_level_from_max(p numeric)
returns text language sql immutable as $$
  select case when p is null or p >= 7.0 then null else public._web_level_of(p) end;
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
