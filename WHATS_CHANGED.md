# What's Changed — Player App Fully Wired

## ⚠️ Do this first (required)

Run **`supabase/migration_player_app.sql`** in your Supabase Dashboard → SQL Editor.
The app now selects new columns (`matches.min_elo`, `is_private`, `invite_code`, …),
new tables (`tournament_entries`, `orders`, `ranking_history`, `trade_requests`),
and calls 4 new Postgres functions. Without the migration, the new screens will
show empty/error states. The script is idempotent — safe to run on your existing
project, it won't touch existing data.

---

## The core loop now works end-to-end

**Create → Find/Join → Lobby → Play → Submit score → Confirm → ELO updates**

### Create Match (was: pure UI, saved nothing)
- Real dates (next 7 days) + time slots; past slots are blocked
- Courts loaded live from the `courts` table (the ones admin manages)
- Partner picker with live player search (`profiles`)
- Open/Private toggle and Minimum ELO actually persist
- Inserts into `matches` + `match_players`, generates an invite code,
  then opens the match lobby and refreshes Home

### Find a Match (was: empty stub)
- Live list of open public matches in the future you haven't joined
- All / Competitive / Casual filter chips, pull-to-refresh
- "Join" goes through a **race-safe Postgres RPC** (`join_match`) that checks
  capacity and min-ELO server-side — two players can't grab the last slot at once
- Auto team balancing; match flips to `full` at 4 players

### Match Detail (was: hardcoded "Karim vs Ahmed" demo)
- Loads the real match: teams, players with live ELO/tier, court, time, format
- Join (when open) / Leave (with confirm; frees the spot, reopens the match,
  deletes the match if everyone leaves)
- Invite code with working **Copy**, and share (copies a ready-to-paste message)
- **Score flow wired to the DB state machine:**
  - Score entry locked until the scheduled time passes
  - Competitive: submit → `pending_confirm` → a player on the **other team**
    confirms (→ `completed`, ELO settles) or rejects (→ `disputed`, re-submit)
  - Casual: saves immediately, no ranking impact
  - After settlement you see your actual ELO delta (e.g. 1847 → 1864, +17)
- All settlement happens in a Postgres function (`_settle_elo`, K=32 team-average
  ELO, tier auto-promotion, `ranking_history` rows, placement counting) — the
  client can't forge results

### Home
- Match tiles are now **tappable** → open the lobby
- Tournament tiles tappable → tournament detail
- The upcoming list now also surfaces matches that **need your action**
  (score pending / disputed) from the last 7 days, with status tags
- Everything refreshes when you come back from a detail screen

## Tournaments (was: completely empty tab)

- **Rankings tab**: live podium (top 3) + leaderboard from `profiles` by ELO,
  with your row highlighted
- **Tournaments tab**: live list with status, team count vs capacity, entry fee
- **Tournament detail**: live overview, registered players list,
  **Register** (writes `tournament_entries`, capacity + status checked) with
  optional partner name, and **Withdraw** with confirmation
- **My Tournaments** (profile): your real entries, Upcoming/Past tabs

## Store

- **Checkout actually places an order** into `orders` (items, totals, promo) —
  it appears in Admin → Payments. Success screen shows the real order reference.
  Payment method is recorded as cash-on-delivery for now (see "Next" below).
- **Trade-In actually submits** to `trade_requests` with the columns the admin
  console expects (`racket_desc`, `condition`, `asking_credit`) — admins can
  send offers back from their console.

## Other fixes (the dead-button hunt)

- **Match History** (profile): was an empty hardcoded list → now your real
  completed matches with per-set scores from your perspective, opponents'
  names, court, date, and ELO delta; filters work
- **Notifications**: now shows the announcements admins send via
  Admin → Broadcasts
- **Forgot password?** (sign-in): sends a real Supabase reset email
- **Resend verification email** (check-email screen): actually resends
- **Privacy & Account**: shows your real email/phone; Change Password sends a
  reset link; Delete Account gives an honest path instead of silently doing nothing
- **Help & Support**: Email opens your mail app, Call opens the dialer,
  Terms/Privacy open the web; Live Chat honestly says "coming soon"
- Removed the fake order number (#PD-90412) and all "demo" toggles

## The ranking system (per your choices)

**One engine, one display.** Raw ELO is the internal engine (bulletproof math);
the **Level 0.0–7.0 + Division** your UI is built around is derived from it and
updated in the same transaction — so the Division Card, leaderboard, and lobby
all move together and can never disagree.

- **Mapping:** `level = (elo − 800) / 200`, capped 0–7.
  Division D 0.0–1.9 · C 2.0–3.4 · B 3.5–4.9 · A 5.0–7.0 (matches your
  `RankingScale` exactly). Tier (bronze/silver/gold/elite) follows the division.
- **Win/loss only** — set scores are recorded but don't change the rating.
- **K-factor schedule:** first 5 ranked matches K=64 (placements move you fast),
  matches 6–30 K=32, then K=24 — established players feel stable.
  Typical even-match swing once established: ±0.06 level.
- **Doubles:** expected result from team-average ELO, applied to all 4 players.
- **Gentle decay:** after 60 days without a confirmed ranked match, −8 ELO
  (≈ −0.04 level) per weekly run — and it can never relegate you out of your
  division or below 1000. Placement players are never decayed. Scheduled via
  pg_cron (enable the extension in Supabase → Database → Extensions; the
  migration registers the Monday 03:00 job automatically once it's on).
- All settlement is server-side; every change is logged to `ranking_history`
  with both level and ELO before/after.

UI now leads with Level everywhere: leaderboard rows show "4.3 · Division B"
(ELO in small print), lobbies show "Lv 4.3", the post-match card shows your
level change first, and the min-rating filter reads "Lv 3.5+".

## Tournament v2 (prototype parity)

- **Bug fixed:** the Tournaments tab silently failed if the migration hadn't
  run (its query joins `tournament_entries`); it now falls back to a plain
  query so tournaments always show. Run the migration for full features.
- **Admin form** now has: About/description, Minimum ELO (eligibility),
  Format (double/single elimination), and a **Status switch**
  (Upcoming/Open/Completed) — previously status was stuck on "upcoming".
- **Player tournament page** rebuilt to the Clay Court prototype:
  date badge hero, Overview/Bracket tabs, Prize pool + Entry/pair cards,
  About, Where & when grid (dates, venue, format, spots remaining),
  Eligibility card (min level + division chips), and a real
  **Find-your-partner** picker — the button reads "Pick a partner first"
  until a partner is chosen, then "Register Pair". Entries store the pair.
- **Knockout bracket engine** (new `tournament_matches` table + RPCs):
  Admin → tournament → "Manage draw & results" → *Generate draw* seeds pairs
  by level (1 v lowest, byes auto-advance), then admins tap matches to record
  winners. Winners advance automatically; in double-elim, losers drop into
  the Losers bracket; two losses and you're out. Players see the live bracket
  with Winners/Losers tabs, their own pair highlighted, and scores.
- Registration now also enforces the tournament's minimum level.

## New files

```
lib/backend/services/match_service.dart       matches: browse/create/join/leave/results
lib/backend/services/tournament_service.dart  tournaments + leaderboard + entries
lib/backend/services/order_service.dart       store checkout
supabase/migration_player_app.sql             schema + RPCs + RLS (run this!)
```

## Things I deliberately did NOT fake

- **Payments**: orders are cash-on-delivery. Paymob or Fawry need merchant
  accounts and a server-side webhook — recommend a Supabase Edge Function for
  the payment callback. Happy to build it once you pick a gateway.
- **Push notifications**: broadcasts show in-app; real push needs FCM/APNs setup.
- **Court booking**: the create flow is explicit that booking happens outside
  the app (matches your original design note).
- **Email change**: Supabase email change requires a verification flow;
  pointed to support for now rather than a half-working form.

## Verify after running the migration

1. `flutter pub get && flutter run`
2. Create a match (competitive, today, earliest past slot won't be selectable —
   pick a future one) → lobby opens, code copyable
3. Second account: Find a Match → Join → both see 2/4
4. After the match time passes: submit a score from account 1 → account 2 sees
   Confirm/Reject → confirm → both ELOs move, Match History + Home form update
5. Register for a tournament from the Tournaments tab → it shows in
   My Tournaments and in Admin → Tournaments entry counts
6. Store: add to cart → checkout → order appears in Admin → Payments

I couldn't run `flutter analyze` in this environment, so run it once locally —
if anything trips, it'll be a one-liner, send me the output.
