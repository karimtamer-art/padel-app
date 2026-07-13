-- ============================================================================
-- Drop the courts.surface column (2026-07-13). Run once. Idempotent.
--
-- Padel courts are all the same surface; the column was NOT NULL + a restrictive
-- enum check (courts_surface_chk) that only got in the way. Remove it and drop
-- surface from organizer_save_court (recreated without the p_surface arg).
-- ============================================================================

alter table public.courts drop constraint if exists courts_surface_chk;
alter table public.courts drop column if exists surface;

drop function if exists public.organizer_save_court(uuid, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, text, numeric, boolean);
create or replace function public.organizer_save_court(
  p_id uuid, p_venue text, p_name text, p_area text, p_city text,
  p_price numeric, p_indoor boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    raise exception 'Organizers only';
  end if;
  if p_id is null then
    insert into public.courts (venue_name, name, area, city,
                               price_per_hour, indoor,
                               is_active, in_maintenance, owner_id, is_public)
    values (p_venue, coalesce(nullif(btrim(p_name), ''), 'Court'), p_area,
            nullif(btrim(coalesce(p_city, '')), ''),
            p_price, coalesce(p_indoor, false), true, false, v_uid, false)
    returning id into v_id;
    return v_id;
  else
    update public.courts set
      venue_name = p_venue,
      name = coalesce(nullif(btrim(p_name), ''), 'Court'),
      area = p_area,
      city = nullif(btrim(coalesce(p_city, '')), ''),
      price_per_hour = p_price, indoor = coalesce(p_indoor, false)
    where id = p_id and (owner_id = v_uid or public._is_admin());
    return p_id;
  end if;
end $$;
grant execute on function public.organizer_save_court(uuid, text, text, text, text, numeric, boolean) to authenticated;

notify pgrst, 'reload schema';
