-- Promotional banners (Store top) + product sales. Safe to re-run.
-- A banner owns a set of products on sale; products.banner_id tracks
-- membership, while products.on_sale / sale_price hold the result.

create table if not exists public.banners (
  id           uuid primary key default gen_random_uuid(),
  title        text,
  subtitle     text,
  image_url    text,
  discount_pct int,                 -- null = per-item custom prices
  is_active    boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.banners enable row level security;
drop policy if exists "banners: read active" on public.banners;
create policy "banners: read active" on public.banners
  for select using (is_active = true or public._is_admin());
drop policy if exists "banners: admin write" on public.banners;
create policy "banners: admin write" on public.banners
  for all using (public._is_admin()) with check (public._is_admin());
drop trigger if exists trg_banners_touch on public.banners;
create trigger trg_banners_touch before update on public.banners
  for each row execute function public.touch_updated_at();
grant select on public.banners to anon, authenticated;
grant select, insert, update, delete on public.banners to authenticated;

alter table public.products add column if not exists banner_id uuid references public.banners(id) on delete set null;
create index if not exists idx_products_banner on public.products (banner_id);

insert into storage.buckets (id, name, public)
  values ('banner-images', 'banner-images', true)
  on conflict (id) do update set public = true;
drop policy if exists "banner-images admin write" on storage.objects;
create policy "banner-images admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'banner-images' and public._is_admin())
  with check (bucket_id = 'banner-images' and public._is_admin());

-- Save a banner + its sale items atomically (admin only). p_items is
-- [{product_id, sale_price}]; sale_price null/'' → derive from p_discount_pct.
create or replace function public.admin_save_banner(
  p_id           uuid,
  p_title        text,
  p_subtitle     text,
  p_image_url    text,
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
      (title, subtitle, image_url, discount_pct, is_active, sort_order)
      values (p_title, p_subtitle, p_image_url, p_discount_pct,
              coalesce(p_is_active, true), coalesce(p_sort_order, 0))
      returning id into v_id;
  else
    update public.banners set
      title = p_title, subtitle = p_subtitle, image_url = p_image_url,
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

create or replace function public.admin_delete_banner(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then raise exception 'admin only'; end if;
  update public.products set banner_id = null, on_sale = false, sale_price = null
    where banner_id = p_id;
  delete from public.banners where id = p_id;
end;
$$;
