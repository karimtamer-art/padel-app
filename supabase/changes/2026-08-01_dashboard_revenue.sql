-- ============================================================================
-- DASHBOARD REVENUE  (2026-08-01)
--
-- The dashboard's Revenue card was a placeholder waiting on Paymob, but the
-- store has always taken real money (cash on delivery and InstaPay transfers)
-- and every order is already in the ledger. This adds the figures so the card
-- can show what was actually taken.
--
--   revenue           — every live order (cancelled/refunded excluded)
--   revenue_delivered — the subset that reached the customer, i.e. money banked
--   revenue_month     — last 30 days, for the trend line
--   orders            — live order count
--
-- Safe to re-run.
-- ============================================================================

create or replace function public.admin_dashboard_counts()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then
    return json_build_object('error', 'admins_only');
  end if;
  return json_build_object(
    'players',     (select count(*) from public.profiles where coalesce(is_admin, false) = false),
    'matches',     (select count(*) from public.matches),
    'courts',      (select count(*) from public.courts),
    'tournaments', (select count(*) from public.tournaments),
    'divisions',   (select coalesce(json_object_agg(tier, c), '{}'::json) from (
                      select coalesce(tier, 'bronze') as tier, count(*) as c
                        from public.profiles
                       where coalesce(is_admin, false) = false
                       group by 1) t),
    'revenue',           (select coalesce(sum(o.total), 0)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')),
    'revenue_delivered', (select coalesce(sum(o.total), 0)::int from public.orders o
                           where o.status = 'delivered'),
    'revenue_month',     (select coalesce(sum(o.total), 0)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
                             and o.created_at >= now() - interval '30 days'),
    'orders',            (select count(*)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded'))
  );
end $$;

notify pgrst, 'reload schema';
