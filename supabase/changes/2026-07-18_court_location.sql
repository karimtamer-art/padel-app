-- 2026-07-18 · Court location (lat/lng/address) for map Directions.
--
-- Adds lat/lng/address to courts (the live DB already has these) and extends
-- organizer_save_court to write them. Players open Directions to the coords via
-- the maps app (url_launcher) — no embedded map / API key. Signature changed →
-- drop the old 7-arg version first. Idempotent; folded into the migration.

alter table public.courts add column if not exists lat double precision;
alter table public.courts add column if not exists lng double precision;
alter table public.courts add column if not exists address text;

drop function if exists public.organizer_save_court(uuid, text, text, text, text, numeric, boolean);
create or replace function public.organizer_save_court(
  p_id uuid, p_venue text, p_name text, p_area text, p_city text,
  p_price numeric, p_indoor boolean,
  p_lat numeric default null, p_lng numeric default null, p_address text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  if p_id is null then
    insert into public.courts (venue_name, name, area, city,
                               price_per_hour, indoor, lat, lng, address,
                               is_active, in_maintenance, owner_id, is_public)
    values (p_venue, coalesce(nullif(btrim(p_name), ''), 'Court'), p_area,
            nullif(btrim(coalesce(p_city, '')), ''),
            p_price, coalesce(p_indoor, false), p_lat, p_lng,
            nullif(btrim(coalesce(p_address, '')), ''),
            true, false, v_uid, false)
    returning id into v_id;
    return v_id;
  else
    update public.courts set
      venue_name = p_venue,
      name = coalesce(nullif(btrim(p_name), ''), 'Court'),
      area = p_area,
      city = nullif(btrim(coalesce(p_city, '')), ''),
      price_per_hour = p_price, indoor = coalesce(p_indoor, false),
      lat = p_lat, lng = p_lng, address = nullif(btrim(coalesce(p_address, '')), '')
    where id = p_id and (owner_id = v_uid or public._is_admin());
    return p_id;
  end if;
end $$;
grant execute on function public.organizer_save_court(uuid, text, text, text, text, numeric, boolean, numeric, numeric, text) to authenticated;

notify pgrst, 'reload schema';
