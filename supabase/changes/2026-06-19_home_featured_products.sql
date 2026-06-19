-- Home "featured" products — purely the admin's choice (no sales logic).
-- Safe to re-run.

alter table public.products add column if not exists is_featured boolean not null default false;
alter table public.products add column if not exists featured_rank int;

-- Pick products for the Home store strip — purely the admin's choice:
--   1. admin-featured (is_featured) → ordered by featured_rank, then newest
--   2. else newest visible (so the section is never empty)
drop function if exists public.get_home_products(int);
create or replace function public.get_home_products(p_limit int default 6)
returns table (
  id           uuid,
  name         text,
  brand        text,
  category     text,
  description  text,
  image_url    text,
  price        numeric,
  sale_price   numeric,
  on_sale      boolean,
  stock_status text,
  rating       numeric,
  source       text
)
language sql security definer set search_path = public as $$
  with has_featured as (
    select exists(
      select 1 from public.products where is_visible and is_featured
    ) as f
  )
  select p.id, p.name, p.brand, p.category, p.description, p.image_url, p.price,
         p.sale_price, p.on_sale, p.stock_status, p.rating,
         case when p.is_featured then 'featured' else 'new' end as source
  from public.products p
  where p.is_visible
    and ( ((select f from has_featured) and p.is_featured)
          or (not (select f from has_featured)) )
  order by
    case when p.is_featured then coalesce(p.featured_rank, 999999)
         else 999999 end asc,
    p.created_at desc
  limit greatest(p_limit, 1);
$$;
