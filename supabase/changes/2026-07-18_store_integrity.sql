-- 2026-07-18 · Store integrity: stock decrement on order + server-enforced promo.
--
-- Placing an order now decrements product stock (so the catalog can't oversell)
-- and the promo discount is recomputed server-side from the code at insert (a
-- crafted client can't forge the discount). Subtotal/total still trust the
-- client's item prices — acceptable because every order is manually
-- payment-verified by an admin. Idempotent; also folded into the migration.

create or replace function public.decrement_stock_on_order()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
    update public.products
       set stock = greatest(0, coalesce(stock, 0) - coalesce((it->>'qty')::int, 0))
     where id = nullif(it->>'product_id', '')::uuid;
  end loop;
  return new;
end $$;
drop trigger if exists trg_decrement_stock on public.orders;
create trigger trg_decrement_stock after insert on public.orders
  for each row execute function public.decrement_stock_on_order();

create table if not exists public.promo_codes (
  code         text primary key,
  percent      int  not null default 0,
  active       boolean not null default true,
  min_subtotal int  not null default 0,
  created_at   timestamptz not null default now()
);
insert into public.promo_codes (code, percent) values ('PADEL10', 10)
  on conflict (code) do nothing;
alter table public.promo_codes enable row level security;
do $$ begin
  create policy "promo codes readable" on public.promo_codes
    for select to authenticated using (true);
exception when duplicate_object then null; end $$;
grant select on public.promo_codes to authenticated;

create or replace function public.apply_promo(p_code text, p_subtotal int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((
    select floor(p_subtotal * pc.percent / 100.0)::int
      from public.promo_codes pc
     where upper(pc.code) = upper(btrim(p_code))
       and pc.active and p_subtotal >= pc.min_subtotal
  ), 0);
$$;
grant execute on function public.apply_promo(text, int) to authenticated;

create or replace function public.enforce_order_promo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.promo_code is not null and btrim(new.promo_code) <> '' then
    new.discount := public.apply_promo(new.promo_code, coalesce(new.subtotal, 0));
  else
    new.discount := 0;
  end if;
  new.total := greatest(0, coalesce(new.subtotal, 0) + coalesce(new.shipping, 0) - coalesce(new.discount, 0));
  return new;
end $$;
drop trigger if exists trg_enforce_order_promo on public.orders;
create trigger trg_enforce_order_promo before insert on public.orders
  for each row execute function public.enforce_order_promo();

notify pgrst, 'reload schema';
