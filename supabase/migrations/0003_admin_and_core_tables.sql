-- ============================================================================
-- 0003_admin_and_core_tables.sql
-- Run in Supabase SQL Editor after 0001 and 0002.
--
-- Adds: is_admin flag, courts, matches, match_players, tournaments,
--       tournament_entries, products, orders, order_items, audit_log,
--       repair_requests, trade_requests, banners, broadcasts.
-- RLS: admin-write / player-read pattern throughout.
-- ============================================================================

-- ── HELPER: reuse touch_updated_at() from migration 0002 ────────────────────
-- Already created — skip. Add triggers for every new table below.


-- ============================================================================
-- 1. PROFILES — extend with admin flag + player status
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin     boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS status       text        NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS verified     boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS store_credit numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_active  timestamptz;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_status_chk;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_status_chk
  CHECK (status IN ('active','banned','flagged'));


-- ── ADMIN HELPER FUNCTION ────────────────────────────────────────────────────
-- Called in every RLS policy that needs an admin check. SECURITY DEFINER
-- so it bypasses RLS on profiles (avoids infinite recursion).
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT is_admin FROM public.profiles WHERE id = auth.uid()),
    false
  );
$$;


-- ============================================================================
-- 2. COURTS / VENUES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.courts (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text        NOT NULL,
  venue_name      text        NOT NULL,
  area            text,
  city            text        NOT NULL DEFAULT 'Cairo',
  address         text,
  lat             float,
  lng             float,
  price_per_hour  numeric(10,2),
  surface         text        NOT NULL DEFAULT 'artificial_grass',
  indoor          boolean     NOT NULL DEFAULT false,
  image_url       text,
  is_active       boolean     NOT NULL DEFAULT true,
  in_maintenance  boolean     NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.courts
  DROP CONSTRAINT IF EXISTS courts_surface_chk;
ALTER TABLE public.courts
  ADD CONSTRAINT courts_surface_chk
  CHECK (surface IN ('clay','artificial_grass','concrete','carpet'));

ALTER TABLE public.courts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "courts: read active" ON public.courts;
CREATE POLICY "courts: read active" ON public.courts
  FOR SELECT USING (is_active = true OR public.is_admin());

DROP POLICY IF EXISTS "courts: admin write" ON public.courts;
CREATE POLICY "courts: admin write" ON public.courts
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP TRIGGER IF EXISTS trg_courts_touch ON public.courts;
CREATE TRIGGER trg_courts_touch
  BEFORE UPDATE ON public.courts
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ============================================================================
-- 3. MATCHES + MATCH_PLAYERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.matches (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  court_id        uuid        REFERENCES public.courts(id) ON DELETE SET NULL,
  created_by      uuid        NOT NULL REFERENCES auth.users(id),
  scheduled_at    timestamptz NOT NULL,
  status          text        NOT NULL DEFAULT 'open',
  match_type      text        NOT NULL DEFAULT 'casual',
  min_elo         int,
  max_elo         int,
  score_team_a    text,
  score_team_b    text,
  winner_team     text,
  dispute_reason  text,
  resolved_by     uuid        REFERENCES auth.users(id),
  resolved_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.matches
  DROP CONSTRAINT IF EXISTS matches_status_chk;
ALTER TABLE public.matches
  ADD CONSTRAINT matches_status_chk
  CHECK (status IN ('open','full','in_progress','completed','cancelled','disputed'));

ALTER TABLE public.matches
  DROP CONSTRAINT IF EXISTS matches_type_chk;
ALTER TABLE public.matches
  ADD CONSTRAINT matches_type_chk
  CHECK (match_type IN ('casual','ranked'));

ALTER TABLE public.matches
  DROP CONSTRAINT IF EXISTS matches_winner_chk;
ALTER TABLE public.matches
  ADD CONSTRAINT matches_winner_chk
  CHECK (winner_team IS NULL OR winner_team IN ('a','b'));

ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

-- INSERT / UPDATE / DELETE policies can go here — no forward references.
DROP POLICY IF EXISTS "matches: insert own" ON public.matches;
CREATE POLICY "matches: insert own" ON public.matches
  FOR INSERT WITH CHECK (auth.uid() = created_by);

DROP POLICY IF EXISTS "matches: update own or admin" ON public.matches;
CREATE POLICY "matches: update own or admin" ON public.matches
  FOR UPDATE USING (auth.uid() = created_by OR public.is_admin());

DROP POLICY IF EXISTS "matches: delete admin" ON public.matches;
CREATE POLICY "matches: delete admin" ON public.matches
  FOR DELETE USING (public.is_admin());

DROP TRIGGER IF EXISTS trg_matches_touch ON public.matches;
CREATE TRIGGER trg_matches_touch
  BEFORE UPDATE ON public.matches
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


CREATE TABLE IF NOT EXISTS public.match_players (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id    uuid        NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  player_id   uuid        NOT NULL REFERENCES auth.users(id),
  team        text        NOT NULL,
  elo_before  float,
  elo_after   float,
  confirmed   boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (match_id, player_id)
);

ALTER TABLE public.match_players
  DROP CONSTRAINT IF EXISTS match_players_team_chk;
ALTER TABLE public.match_players
  ADD CONSTRAINT match_players_team_chk
  CHECK (team IN ('a','b'));

ALTER TABLE public.match_players ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "match_players: read" ON public.match_players;
CREATE POLICY "match_players: read" ON public.match_players
  FOR SELECT USING (
    player_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.matches m WHERE m.id = match_id AND m.created_by = auth.uid())
    OR public.is_admin()
  );

DROP POLICY IF EXISTS "match_players: insert own" ON public.match_players;
CREATE POLICY "match_players: insert own" ON public.match_players
  FOR INSERT WITH CHECK (auth.uid() = player_id);

DROP POLICY IF EXISTS "match_players: update own or admin" ON public.match_players;
CREATE POLICY "match_players: update own or admin" ON public.match_players
  FOR UPDATE USING (auth.uid() = player_id OR public.is_admin());

-- matches SELECT policy defined here (after match_players exists) because it
-- references match_players in a subquery.
DROP POLICY IF EXISTS "matches: read own or open" ON public.matches;
CREATE POLICY "matches: read own or open" ON public.matches
  FOR SELECT USING (
    status = 'open'
    OR created_by = auth.uid()
    OR EXISTS (SELECT 1 FROM public.match_players mp WHERE mp.match_id = id AND mp.player_id = auth.uid())
    OR public.is_admin()
  );


-- ============================================================================
-- 4. TOURNAMENTS + ENTRIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournaments (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  court_id     uuid        REFERENCES public.courts(id) ON DELETE SET NULL,
  venue_name   text,
  start_date   date        NOT NULL,
  end_date     date,
  entry_fee    numeric(10,2) NOT NULL DEFAULT 0,
  prize_pool   numeric(10,2) NOT NULL DEFAULT 0,
  court_fees   numeric(10,2) NOT NULL DEFAULT 0,
  capacity     int         NOT NULL DEFAULT 16,
  min_elo      int,
  format       text        NOT NULL DEFAULT 'knockout',
  status       text        NOT NULL DEFAULT 'upcoming',
  description  text,
  image_url    text,
  created_by   uuid        REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tournaments
  DROP CONSTRAINT IF EXISTS tournaments_format_chk;
ALTER TABLE public.tournaments
  ADD CONSTRAINT tournaments_format_chk
  CHECK (format IN ('knockout','round_robin','group_knockout'));

ALTER TABLE public.tournaments
  DROP CONSTRAINT IF EXISTS tournaments_status_chk;
ALTER TABLE public.tournaments
  ADD CONSTRAINT tournaments_status_chk
  CHECK (status IN ('upcoming','open','in_progress','completed','cancelled'));

ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tournaments: read all" ON public.tournaments;
CREATE POLICY "tournaments: read all" ON public.tournaments
  FOR SELECT USING (status != 'cancelled' OR public.is_admin());

DROP POLICY IF EXISTS "tournaments: admin write" ON public.tournaments;
CREATE POLICY "tournaments: admin write" ON public.tournaments
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP TRIGGER IF EXISTS trg_tournaments_touch ON public.tournaments;
CREATE TRIGGER trg_tournaments_touch
  BEFORE UPDATE ON public.tournaments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


CREATE TABLE IF NOT EXISTS public.tournament_entries (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id  uuid        NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  player_id      uuid        NOT NULL REFERENCES auth.users(id),
  partner_id     uuid        REFERENCES auth.users(id),
  status         text        NOT NULL DEFAULT 'pending',
  payment_ref    text,
  registered_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tournament_id, player_id)
);

ALTER TABLE public.tournament_entries
  DROP CONSTRAINT IF EXISTS tournament_entries_status_chk;
ALTER TABLE public.tournament_entries
  ADD CONSTRAINT tournament_entries_status_chk
  CHECK (status IN ('pending','confirmed','waitlisted','withdrawn'));

ALTER TABLE public.tournament_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tournament_entries: read own or admin" ON public.tournament_entries;
CREATE POLICY "tournament_entries: read own or admin" ON public.tournament_entries
  FOR SELECT USING (player_id = auth.uid() OR partner_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "tournament_entries: insert own" ON public.tournament_entries;
CREATE POLICY "tournament_entries: insert own" ON public.tournament_entries
  FOR INSERT WITH CHECK (auth.uid() = player_id);

DROP POLICY IF EXISTS "tournament_entries: update own or admin" ON public.tournament_entries;
CREATE POLICY "tournament_entries: update own or admin" ON public.tournament_entries
  FOR UPDATE USING (auth.uid() = player_id OR public.is_admin());


-- ============================================================================
-- 5. PRODUCTS + ORDERS + ORDER_ITEMS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.products (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  brand        text,
  category     text        NOT NULL DEFAULT 'accessories',
  description  text,
  price        numeric(10,2) NOT NULL,
  cost         numeric(10,2),
  stock        int         NOT NULL DEFAULT 0,
  stock_status text        GENERATED ALWAYS AS (
                 CASE WHEN stock = 0 THEN 'out'
                      WHEN stock <= 5 THEN 'low'
                      ELSE 'in' END
               ) STORED,
  image_url    text,
  is_visible   boolean     NOT NULL DEFAULT true,
  on_sale      boolean     NOT NULL DEFAULT false,
  sale_price   numeric(10,2),
  rating       numeric(3,2),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_category_chk;
ALTER TABLE public.products
  ADD CONSTRAINT products_category_chk
  CHECK (category IN ('rackets','shoes','apparel','balls','accessories'));

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_stock_chk;
ALTER TABLE public.products
  ADD CONSTRAINT products_stock_chk
  CHECK (stock >= 0);

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "products: read visible" ON public.products;
CREATE POLICY "products: read visible" ON public.products
  FOR SELECT USING (is_visible = true OR public.is_admin());

DROP POLICY IF EXISTS "products: admin write" ON public.products;
CREATE POLICY "products: admin write" ON public.products
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP TRIGGER IF EXISTS trg_products_touch ON public.products;
CREATE TRIGGER trg_products_touch
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


CREATE TABLE IF NOT EXISTS public.orders (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id   uuid        NOT NULL REFERENCES auth.users(id),
  status      text        NOT NULL DEFAULT 'pending',
  total       numeric(10,2) NOT NULL,
  payment_ref text,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_status_chk;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_status_chk
  CHECK (status IN ('pending','confirmed','shipped','delivered','cancelled','refunded'));

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "orders: read own or admin" ON public.orders;
CREATE POLICY "orders: read own or admin" ON public.orders
  FOR SELECT USING (player_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "orders: insert own" ON public.orders;
CREATE POLICY "orders: insert own" ON public.orders
  FOR INSERT WITH CHECK (auth.uid() = player_id);

DROP POLICY IF EXISTS "orders: update admin" ON public.orders;
CREATE POLICY "orders: update admin" ON public.orders
  FOR UPDATE USING (public.is_admin());

DROP TRIGGER IF EXISTS trg_orders_touch ON public.orders;
CREATE TRIGGER trg_orders_touch
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


CREATE TABLE IF NOT EXISTS public.order_items (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid        NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id  uuid        NOT NULL REFERENCES public.products(id),
  quantity    int         NOT NULL DEFAULT 1,
  unit_price  numeric(10,2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (quantity > 0)
);

ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "order_items: read own or admin" ON public.order_items;
CREATE POLICY "order_items: read own or admin" ON public.order_items
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND o.player_id = auth.uid())
    OR public.is_admin()
  );

DROP POLICY IF EXISTS "order_items: insert own" ON public.order_items;
CREATE POLICY "order_items: insert own" ON public.order_items
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND o.player_id = auth.uid())
  );


-- ============================================================================
-- 6. AUDIT LOG (admin ELO overrides + any sensitive action)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.audit_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id     uuid        NOT NULL REFERENCES auth.users(id),
  action       text        NOT NULL,
  target_type  text        NOT NULL,
  target_id    uuid        NOT NULL,
  old_value    jsonb,
  new_value    jsonb,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_log: admin only" ON public.audit_log;
CREATE POLICY "audit_log: admin only" ON public.audit_log
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ============================================================================
-- 7. REPAIR REQUESTS + TRADE REQUESTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.repair_requests (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id     uuid        NOT NULL REFERENCES auth.users(id),
  racket_desc   text        NOT NULL,
  issue         text        NOT NULL,
  status        text        NOT NULL DEFAULT 'pending',
  quote_amount  numeric(10,2),
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.repair_requests
  DROP CONSTRAINT IF EXISTS repair_requests_status_chk;
ALTER TABLE public.repair_requests
  ADD CONSTRAINT repair_requests_status_chk
  CHECK (status IN ('pending','quoted','in_repair','ready','collected'));

ALTER TABLE public.repair_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "repair_requests: read own or admin" ON public.repair_requests;
CREATE POLICY "repair_requests: read own or admin" ON public.repair_requests
  FOR SELECT USING (player_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "repair_requests: insert own" ON public.repair_requests;
CREATE POLICY "repair_requests: insert own" ON public.repair_requests
  FOR INSERT WITH CHECK (auth.uid() = player_id);

DROP POLICY IF EXISTS "repair_requests: update admin" ON public.repair_requests;
CREATE POLICY "repair_requests: update admin" ON public.repair_requests
  FOR UPDATE USING (public.is_admin());

DROP TRIGGER IF EXISTS trg_repair_requests_touch ON public.repair_requests;
CREATE TRIGGER trg_repair_requests_touch
  BEFORE UPDATE ON public.repair_requests
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


CREATE TABLE IF NOT EXISTS public.trade_requests (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id      uuid        NOT NULL REFERENCES auth.users(id),
  racket_desc    text        NOT NULL,
  condition      text,
  asking_credit  numeric(10,2),
  offer_credit   numeric(10,2),
  status         text        NOT NULL DEFAULT 'pending',
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.trade_requests
  DROP CONSTRAINT IF EXISTS trade_requests_condition_chk;
ALTER TABLE public.trade_requests
  ADD CONSTRAINT trade_requests_condition_chk
  CHECK (condition IS NULL OR condition IN ('new','like_new','good','fair','poor'));

ALTER TABLE public.trade_requests
  DROP CONSTRAINT IF EXISTS trade_requests_status_chk;
ALTER TABLE public.trade_requests
  ADD CONSTRAINT trade_requests_status_chk
  CHECK (status IN ('pending','offer_made','accepted','declined','completed'));

ALTER TABLE public.trade_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "trade_requests: read own or admin" ON public.trade_requests;
CREATE POLICY "trade_requests: read own or admin" ON public.trade_requests
  FOR SELECT USING (player_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "trade_requests: insert own" ON public.trade_requests;
CREATE POLICY "trade_requests: insert own" ON public.trade_requests
  FOR INSERT WITH CHECK (auth.uid() = player_id);

DROP POLICY IF EXISTS "trade_requests: update admin" ON public.trade_requests;
CREATE POLICY "trade_requests: update admin" ON public.trade_requests
  FOR UPDATE USING (public.is_admin());

DROP TRIGGER IF EXISTS trg_trade_requests_touch ON public.trade_requests;
CREATE TRIGGER trg_trade_requests_touch
  BEFORE UPDATE ON public.trade_requests
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ============================================================================
-- 8. BANNERS (promotions shown in the player app)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.banners (
  id          uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  title       text    NOT NULL,
  subtitle    text,
  image_url   text,
  link_type   text    NOT NULL DEFAULT 'none',
  link_id     uuid,
  link_url    text,
  is_active   boolean NOT NULL DEFAULT false,
  sort_order  int     NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.banners
  DROP CONSTRAINT IF EXISTS banners_link_type_chk;
ALTER TABLE public.banners
  ADD CONSTRAINT banners_link_type_chk
  CHECK (link_type IN ('tournament','product','url','none'));

ALTER TABLE public.banners ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "banners: read active" ON public.banners;
CREATE POLICY "banners: read active" ON public.banners
  FOR SELECT USING (is_active = true OR public.is_admin());

DROP POLICY IF EXISTS "banners: admin write" ON public.banners;
CREATE POLICY "banners: admin write" ON public.banners
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ============================================================================
-- 9. BROADCASTS (push / in-app notifications sent by admin)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadcasts (
  id          uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id    uuid    NOT NULL REFERENCES auth.users(id),
  title       text    NOT NULL,
  body        text    NOT NULL,
  segment     text    NOT NULL DEFAULT 'all',
  player_ids  uuid[],
  sent_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.broadcasts
  DROP CONSTRAINT IF EXISTS broadcasts_segment_chk;
ALTER TABLE public.broadcasts
  ADD CONSTRAINT broadcasts_segment_chk
  CHECK (segment IN ('all','ranked','unranked','specific'));

ALTER TABLE public.broadcasts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "broadcasts: admin only" ON public.broadcasts;
CREATE POLICY "broadcasts: admin only" ON public.broadcasts
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ============================================================================
-- 10. INDEXES (query performance for common lookups)
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_matches_status        ON public.matches (status);
CREATE INDEX IF NOT EXISTS idx_matches_scheduled     ON public.matches (scheduled_at DESC);
CREATE INDEX IF NOT EXISTS idx_matches_created_by    ON public.matches (created_by);
CREATE INDEX IF NOT EXISTS idx_match_players_match   ON public.match_players (match_id);
CREATE INDEX IF NOT EXISTS idx_match_players_player  ON public.match_players (player_id);
CREATE INDEX IF NOT EXISTS idx_tournaments_status    ON public.tournaments (status);
CREATE INDEX IF NOT EXISTS idx_tournaments_start     ON public.tournaments (start_date);
CREATE INDEX IF NOT EXISTS idx_t_entries_tournament  ON public.tournament_entries (tournament_id);
CREATE INDEX IF NOT EXISTS idx_t_entries_player      ON public.tournament_entries (player_id);
CREATE INDEX IF NOT EXISTS idx_products_category     ON public.products (category);
CREATE INDEX IF NOT EXISTS idx_orders_player         ON public.orders (player_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_admin       ON public.audit_log (admin_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_target      ON public.audit_log (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_profiles_is_admin     ON public.profiles (is_admin) WHERE is_admin = true;
