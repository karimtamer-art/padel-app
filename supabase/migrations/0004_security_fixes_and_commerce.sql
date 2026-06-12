-- ============================================================================
-- 0004_security_fixes_and_commerce.sql
-- Run in Supabase SQL Editor AFTER 0001, 0002, 0003.
--
-- Part A — SECURITY FIXES (urgent):
--   1. Stop users editing protected profile columns (is_admin, rank, credit…)
--   2. Protect rank columns on match_players
--   3. Close the "confirm tournament entry without paying" hole
--   4. Secure order creation (server computes total & unit_price)
--   5. Move products.cost out of public reach (admin-only product_costs)
--
-- Part B — NEW COMMERCE TABLES:
--   6. addresses (must be before create_order — %ROWTYPE reference)
--   7. payments (unified: store orders AND tournament entries)
--   8. device_tokens (push notifications)
--
-- Principle: the public anon key reaches every table directly. So the only
-- real security is RLS + column privileges. Anything a user must NOT control
-- (rank, credit, admin, payment status, prices) is written ONLY by the
-- service role — i.e. your Edge Functions / the dashboard — never the client.
-- ============================================================================


-- ============================================================================
-- 1. PROFILES — close the privilege-escalation hole
-- ============================================================================

-- Both prior migrations left a permissive "update own" policy under two
-- different names. Drop both and create one clean policy.
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles: update own" ON public.profiles;

CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- The policy controls WHICH ROW. Column grants control WHICH COLUMNS.
-- Revoke blanket UPDATE, then grant back only the user-editable columns.
-- Everything NOT listed here (is_admin, status, verified, store_credit,
-- level, elo, tier, placement_played, last_active) can now be written ONLY
-- by the service role. updated_at is set by the touch trigger, which is not
-- subject to the caller's column grants, so it keeps working.
REVOKE UPDATE ON public.profiles FROM anon, authenticated;
GRANT  UPDATE (name, phone, bio, avatar_url, city,
               gender, date_of_birth, preferred_hand, preferred_court_side,
               dob, hand, court_side)
  ON public.profiles TO authenticated;

-- NOTE: promoting an admin is now a service-role action. Do it in the SQL
-- editor / dashboard, and log it to audit_log:
--   UPDATE public.profiles SET is_admin = true WHERE id = '<uuid>';


-- ============================================================================
-- 2. MATCH_PLAYERS — protect rank fields
-- ============================================================================
-- A player may add themselves to a team and confirm a result, but the ELO
-- snapshots are written only by the confirm_match Edge Function (service role).

REVOKE INSERT ON public.match_players FROM anon, authenticated;
GRANT  INSERT (match_id, player_id, team) ON public.match_players TO authenticated;

REVOKE UPDATE ON public.match_players FROM anon, authenticated;
GRANT  UPDATE (confirmed) ON public.match_players TO authenticated;


-- ============================================================================
-- 3. TOURNAMENT_ENTRIES — no self-confirm, no fee bypass
-- ============================================================================
-- User may register (always lands as 'pending') and may withdraw. Moving an
-- entry to 'confirmed' is done by the payment webhook (service role) or an
-- admin — never by the registering user.

-- Insert: only these columns; status defaults to 'pending', payment_ref null.
REVOKE INSERT ON public.tournament_entries FROM anon, authenticated;
GRANT  INSERT (tournament_id, player_id, partner_id)
  ON public.tournament_entries TO authenticated;

-- Update: lock to the status column only (value is constrained by policy below).
REVOKE UPDATE ON public.tournament_entries FROM anon, authenticated;
GRANT  UPDATE (status) ON public.tournament_entries TO authenticated;

DROP POLICY IF EXISTS "tournament_entries: update own or admin" ON public.tournament_entries;

-- A user may only set their own entry to 'withdrawn'.
DROP POLICY IF EXISTS "t_entries: withdraw own" ON public.tournament_entries;
CREATE POLICY "t_entries: withdraw own" ON public.tournament_entries
  FOR UPDATE USING (player_id = auth.uid())
  WITH CHECK (player_id = auth.uid() AND status = 'withdrawn');

-- Admin may set any status (confirm / waitlist / etc.).
DROP POLICY IF EXISTS "t_entries: admin update" ON public.tournament_entries;
CREATE POLICY "t_entries: admin update" ON public.tournament_entries
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ============================================================================
-- 6. ADDRESSES  (must come before create_order — %ROWTYPE reference)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.addresses (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label       text,                       -- 'home' / 'work'
  full_name   text NOT NULL,
  phone       text NOT NULL,              -- couriers need this
  governorate text NOT NULL,              -- محافظة
  city        text NOT NULL,
  area        text,
  street      text NOT NULL,
  building    text,
  apartment   text,
  landmark    text,                       -- Egyptian addresses lean on these
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.addresses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "addresses: own" ON public.addresses
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP TRIGGER IF EXISTS trg_addresses_touch ON public.addresses;
CREATE TRIGGER trg_addresses_touch
  BEFORE UPDATE ON public.addresses
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE INDEX IF NOT EXISTS idx_addresses_user ON public.addresses (user_id);


-- ============================================================================
-- 4. ORDERS — secure creation (server owns the total)
-- ============================================================================
-- Direct client inserts are removed. Orders are created ONLY through
-- create_order(), which recomputes the total from real product prices, forces
-- status='pending', and snapshots the shipping address onto the order.

-- 4a. Shipping snapshot columns (copied at order time so history stays correct
--     even if the user later edits or deletes the address).
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS ship_name        text,
  ADD COLUMN IF NOT EXISTS ship_phone       text,
  ADD COLUMN IF NOT EXISTS ship_governorate text,
  ADD COLUMN IF NOT EXISTS ship_city        text,
  ADD COLUMN IF NOT EXISTS ship_area        text,
  ADD COLUMN IF NOT EXISTS ship_street      text,
  ADD COLUMN IF NOT EXISTS ship_building    text,
  ADD COLUMN IF NOT EXISTS ship_apartment   text,
  ADD COLUMN IF NOT EXISTS ship_landmark    text;

-- 4b. Remove direct insert rights (the RPC below is the only creation path).
DROP POLICY IF EXISTS "orders: insert own" ON public.orders;
DROP POLICY IF EXISTS "order_items: insert own" ON public.order_items;
REVOKE INSERT ON public.orders      FROM anon, authenticated;
REVOKE INSERT ON public.order_items FROM anon, authenticated;

-- 4c. The secure order-creation function.
--     p_items: jsonb array like '[{"product_id":"…","quantity":2}, …]'
CREATE OR REPLACE FUNCTION public.create_order(p_items jsonb, p_address_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_order_id uuid;
  v_total    numeric(10,2) := 0;
  v_item     jsonb;
  v_product  public.products%ROWTYPE;
  v_addr     public.addresses%ROWTYPE;
  v_qty      int;
  v_unit     numeric(10,2);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Address must belong to the caller.
  SELECT * INTO v_addr FROM public.addresses
    WHERE id = p_address_id AND user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid address';
  END IF;

  INSERT INTO public.orders (
    player_id, status, total,
    ship_name, ship_phone, ship_governorate, ship_city,
    ship_area, ship_street, ship_building, ship_apartment, ship_landmark
  ) VALUES (
    v_uid, 'pending', 0,
    v_addr.full_name, v_addr.phone, v_addr.governorate, v_addr.city,
    v_addr.area, v_addr.street, v_addr.building, v_addr.apartment, v_addr.landmark
  ) RETURNING id INTO v_order_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    SELECT * INTO v_product FROM public.products
      WHERE id = (v_item->>'product_id')::uuid AND is_visible = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'product unavailable: %', v_item->>'product_id';
    END IF;

    v_qty := GREATEST(COALESCE((v_item->>'quantity')::int, 1), 1);
    IF v_product.stock < v_qty THEN
      RAISE EXCEPTION 'insufficient stock for %', v_product.name;
    END IF;

    -- Price comes from the DB, never the client.
    v_unit := CASE
                WHEN v_product.on_sale AND v_product.sale_price IS NOT NULL
                THEN v_product.sale_price ELSE v_product.price
              END;

    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
      VALUES (v_order_id, v_product.id, v_qty, v_unit);

    v_total := v_total + (v_unit * v_qty);
  END LOOP;

  UPDATE public.orders SET total = v_total WHERE id = v_order_id;
  RETURN v_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order(jsonb, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.create_order(jsonb, uuid) TO authenticated;

-- Client usage:  supabase.rpc('create_order', { p_items: [...], p_address_id })
-- Then create the Paymob intention server-side for orders.total, and let the
-- webhook flip status to 'confirmed' and decrement stock.


-- ============================================================================
-- 5. PRODUCT COST — move out of public reach
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.product_costs (
  product_id uuid PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  cost       numeric(10,2),
  supplier   text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Migrate any existing cost values, THEN drop the leaky column.
INSERT INTO public.product_costs (product_id, cost)
  SELECT id, cost FROM public.products WHERE cost IS NOT NULL
  ON CONFLICT (product_id) DO NOTHING;

ALTER TABLE public.products DROP COLUMN IF EXISTS cost;   -- (destructive: review)

ALTER TABLE public.product_costs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "product_costs: admin only" ON public.product_costs
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ============================================================================
-- 7. PAYMENTS  (one table for store orders AND tournament entries)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id),
  purpose          text NOT NULL,                 -- what was paid for
  reference_id     uuid NOT NULL,                 -- orders.id OR tournament_entries.id
  amount           numeric(10,2) NOT NULL,
  currency         text NOT NULL DEFAULT 'EGP',
  method           text,                          -- card / wallet / apple_pay / google_pay
  status           text NOT NULL DEFAULT 'pending',
  gateway          text NOT NULL DEFAULT 'paymob',
  gateway_order_id text,
  gateway_txn_id   text,
  hmac_verified    boolean NOT NULL DEFAULT false,
  raw_payload      jsonb,                          -- store the webhook body
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.payments
  ADD CONSTRAINT payments_purpose_chk
  CHECK (purpose IN ('store_order','tournament_entry'));

ALTER TABLE public.payments
  ADD CONSTRAINT payments_status_chk
  CHECK (status IN ('pending','paid','failed','refunded'));

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- Users may READ their own payments; admins read all. Nobody but the service
-- role may write — the Paymob webhook (service role) is the only writer.
CREATE POLICY "payments: read own or admin" ON public.payments
  FOR SELECT USING (user_id = auth.uid() OR public.is_admin());

REVOKE INSERT, UPDATE, DELETE ON public.payments FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_payments_touch ON public.payments;
CREATE TRIGGER trg_payments_touch
  BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE INDEX IF NOT EXISTS idx_payments_user      ON public.payments (user_id);
CREATE INDEX IF NOT EXISTS idx_payments_reference ON public.payments (purpose, reference_id);
CREATE INDEX IF NOT EXISTS idx_payments_gateway   ON public.payments (gateway_order_id);
CREATE INDEX IF NOT EXISTS idx_payments_pending   ON public.payments (status) WHERE status = 'pending';


-- ============================================================================
-- 8. DEVICE TOKENS  (FCM push)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.device_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token      text NOT NULL,
  platform   text,                                -- ios / android / web
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, token)
);

ALTER TABLE public.device_tokens
  DROP CONSTRAINT IF EXISTS device_tokens_platform_chk;
ALTER TABLE public.device_tokens
  ADD CONSTRAINT device_tokens_platform_chk
  CHECK (platform IS NULL OR platform IN ('ios','android','web'));

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "device_tokens: own" ON public.device_tokens
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON public.device_tokens (user_id);

-- ============================================================================
-- END. After running: verify a non-admin user CANNOT
--   UPDATE profiles SET is_admin = true;   -- should fail (permission denied)
-- ============================================================================
