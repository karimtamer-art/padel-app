-- Banners: optional image — add a custom background color fallback.
-- Run after 2026-06-19_banners.sql. Safe to re-run.

alter table public.banners add column if not exists bg_color text;

-- admin_save_banner gains p_bg_color (signature changed → drop the old one first)
drop function if exists public.admin_save_banner(uuid,text,text,text,boolean,int,int,jsonb);
create or replace function public.admin_save_banner(
  p_id           uuid,
  p_title        text,
  p_subtitle     text,
  p_image_url    text,
  p_bg_color     text,
  p_is_active    boolean,
  p_sort_order   int,
  p_discount_pct int,
  p_items        jsonb default '[]'::jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public._is_admin() then
    raise exception 'admin only';
  end if;

  if p_id is null then
    insert into public.banners
      (title, subtitle, image_url, bg_color, discount_pct, is_active, sort_order)
      values (p_title, p_subtitle, p_image_url, p_bg_color, p_discount_pct,
              coalesce(p_is_active, true), coalesce(p_sort_order, 0))
      returning id into v_id;
  else
    update public.banners set
      title = p_title, subtitle = p_subtitle, image_url = p_image_url,
      bg_color = p_bg_color,
      discount_pct = p_discount_pct, is_active = coalesce(p_is_active, true),
      sort_order = coalesce(p_sort_order, 0)
      where id = p_id
      returning id into v_id;
    if v_id is null then raise exception 'banner not found'; end if;
  end if;

  update public.products p
     set banner_id = null, on_sale = false, sale_price = null
   where p.banner_id = v_id
     and p.id not in (
       select (it->>'product_id')::uuid from jsonb_array_elements(p_items) it
     );

  update public.products p set
    banner_id  = v_id,
    on_sale    = coalesce(p_is_active, true),
    sale_price = coalesce(
      nullif(i.sale_price, '')::numeric,
      case when p_discount_pct is not null
           then round(p.price * (100 - p_discount_pct) / 100.0, 2)
           else p.sale_price end
    )
  from (
    select (it->>'product_id')::uuid as product_id, it->>'sale_price' as sale_price
    from jsonb_array_elements(p_items) it
  ) i
  where p.id = i.product_id;

  return v_id;
end;
$$;
