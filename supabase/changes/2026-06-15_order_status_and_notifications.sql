-- ============================================================
-- Incremental change · 2026-06-15
-- Orders status constraint fix + per-user notifications (orders pass)
-- ------------------------------------------------------------
-- This is the DELTA only. It is also folded into the canonical
-- supabase/migration_player_app.sql (the cumulative source of truth).
-- Safe to re-run (idempotent). Run this file to apply just this part.
-- ============================================================

-- 1) The live orders table's old status CHECK predated the checkout flow and
--    rejected the new states admin writes ('paid', 'refunded'), so "Verify
--    payment" failed. Drop and re-add covering every status the app uses.
alter table public.orders drop constraint if exists orders_status_chk;
do $$ begin
  alter table public.orders add constraint orders_status_chk check (
    status in ('pending','confirmed','paid','shipped','delivered','cancelled','refunded')
  );
exception when duplicate_object then null; end $$;

-- 2) Per-user notification inbox. Rows are produced ONLY by the orders trigger
--    below (security definer); no client insert path → no insert policy.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'order',   -- order | match | tournament | ...
  title text not null,
  body text,
  data jsonb,                            -- {order_id, status, ...} for tap-through
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_user
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;
do $$ begin
  create policy "notifications: own read" on public.notifications
    for select using (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "notifications: own update" on public.notifications
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
grant select, update on public.notifications to authenticated;

-- Order ref shown to the buyer (matches Dart OrderUi.ref(): PD-<first 6 hex>).
create or replace function public._order_ref(p_id uuid)
returns text language sql immutable as $$
  select 'PD-' || upper(substr(replace(p_id::text, '-', ''), 1, 6));
$$;

-- Notify the buyer whenever an order's status changes. Security definer so the
-- admin updating the order can insert a row owned by the buyer (RLS would
-- otherwise block the cross-user insert).
create or replace function public.notify_order_status()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_title text;
  v_body  text;
  v_ref   text := public._order_ref(new.id);
begin
  case new.status
    when 'paid', 'confirmed' then
      v_title := 'Order confirmed';
      v_body  := v_ref || ' — payment confirmed, we are preparing your order.';
    when 'shipped' then
      v_title := 'Out for delivery';
      v_body  := v_ref || ' is on its way to you.';
    when 'delivered' then
      v_title := 'Delivered';
      v_body  := v_ref || ' was delivered. Enjoy your gear!';
    when 'cancelled' then
      v_title := 'Order cancelled';
      v_body  := v_ref || ' was cancelled. Contact support if this is unexpected.';
    when 'refunded' then
      v_title := 'Refund issued';
      v_body  := v_ref || ' has been refunded.';
    else
      return new; -- no message for this transition
  end case;

  insert into public.notifications (user_id, type, title, body, data)
  values (new.player_id, 'order', v_title, v_body,
          jsonb_build_object('order_id', new.id, 'status', new.status));
  return new;
end $$;

drop trigger if exists trg_notify_order_status on public.orders;
create trigger trg_notify_order_status
  after update on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.notify_order_status();

-- Reload PostgREST schema cache so the new table is visible immediately.
notify pgrst, 'reload schema';
