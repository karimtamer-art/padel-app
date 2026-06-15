-- ============================================================
-- Incremental change · 2026-06-15
-- Notify admins (privately) when a new order is placed
-- ------------------------------------------------------------
-- Inserts an 'admin_order' notification addressed to every is_admin profile
-- whenever an order row is created. Because notifications has own-row RLS,
-- these rows are visible ONLY to admins — regular buyers never see them, even
-- though it is the same table. Buyers still get their own order-status rows
-- from the existing UPDATE trigger. Also folded into the canonical
-- supabase/migration_player_app.sql. Idempotent.
-- ============================================================

create or replace function public.notify_admins_new_order()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_ref    text := public._order_ref(new.id);
  v_method text := case when new.payment_method = 'instapay'
                        then 'InstaPay' else 'Cash on delivery' end;
begin
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_order',
         'New order to confirm',
         v_ref || ' · ' || v_method || ' · EGP ' || coalesce(new.total, 0)::text,
         jsonb_build_object('order_id', new.id, 'status', new.status, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_order on public.orders;
create trigger trg_notify_admins_new_order
  after insert on public.orders
  for each row
  execute function public.notify_admins_new_order();

notify pgrst, 'reload schema';
