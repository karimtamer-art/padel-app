-- 2026-08-02 — Courts: drop the hourly price.
-- The app never handles court booking or payment (players book the club
-- themselves), so price_per_hour was collected in the admin form and never
-- used anywhere else. Removed from the form, the card, and the DB.
--
-- Safe to re-run.

-- 1) The RPC organizers use to save their own courts loses p_price.
--    Signature changed → drop the 10-arg version (and the older ones) first.
drop function if exists public.organizer_save_court(uuid, text, text, text, text, numeric, boolean, numeric, numeric, text);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, numeric, boolean);

-- 2) Drop the column itself.
alter table public.courts drop column if exists price_per_hour;

-- 3) Re-create the RPC without the price.
create or replace function public.organizer_save_court(
  p_id uuid, p_venue text, p_name text, p_area text, p_city text,
  p_indoor boolean,
  p_lat numeric default null, p_lng numeric default null, p_address text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  if p_id is null then
    insert into public.courts (venue_name, name, area, city,
                               indoor, lat, lng, address,
                               is_active, in_maintenance, owner_id, is_public)
    values (p_venue, coalesce(nullif(btrim(p_name), ''), 'Court'), p_area,
            nullif(btrim(coalesce(p_city, '')), ''),
            coalesce(p_indoor, false), p_lat, p_lng,
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
      indoor = coalesce(p_indoor, false),
      lat = p_lat, lng = p_lng, address = nullif(btrim(coalesce(p_address, '')), '')
    where id = p_id and (owner_id = v_uid or public._is_admin());
    return p_id;
  end if;
end $$;
grant execute on function public.organizer_save_court(uuid, text, text, text, text, boolean, numeric, numeric, text) to authenticated;

-- 4) organizer_courts() returns `setof public.courts` (select *) — it picks the
--    new column list up automatically, but re-create it so no stale plan lingers.
create or replace function public.organizer_courts()
returns setof public.courts
language sql stable security definer set search_path = public as $$
  select * from public.courts
   where owner_id = auth.uid()
   order by created_at desc;
$$;
grant execute on function public.organizer_courts() to authenticated;
