# Padel Egypt — Project Guide for Claude Code

Flutter app (player + admin in one codebase) on Supabase. Read this fully
before changing anything.

## What this is

- **Player app**: `lib/frontend/` — matches, tournaments, rankings, store.
- **Admin console**: `lib/admin/` — same binary; admins (profiles.is_admin)
  are routed there by `auth_gate.dart`.
- **Backend services**: `lib/backend/services/` — ALL Supabase I/O lives here.
  Screens never call `Supabase.instance.client` directly except a few legacy
  spots; do not add new direct calls in screens — extend the services.
- **Database contract**: `supabase/migration_player_app.sql`. This file IS the
  schema + RPCs + RLS. It is idempotent and gets re-run on the live project.

## Hard rules (do not break these)

1. **Never change the DB schema from Dart alone.** Any new column/table/RPC
   must be added to `supabase/migration_player_app.sql` using
   `if not exists` / `create or replace`, keeping the file safe to re-run.
2. **Rating changes happen ONLY in Postgres** (`_settle_rating`,
   `submit_match_result`, `confirm_match_result`, `join_match`,
   `record_bracket_winner`, `generate_draw`). Never compute or write
   rating/level from the client — that's the anti-cheat boundary.
3. **One rating engine, one display (rating engine v2, 2026-07-02).** The engine
   is the native **0.00–7.00 `profiles.rating`** (Playtomic-style: Elo + sigma
   uncertainty + margin-of-victory + doubles averaging), settled server-side in
   `_settle_rating` (idempotent via `matches.rating_applied`). `profiles.level`
   is kept as a **display mirror** of `rating` (`level := rating` on every
   write); `profiles.elo` + `level_from_elo` are **legacy/backfill only**. The
   authoritative math is mirrored in Dart by **`RatingEngine`**
   (`lib/backend/models/rating_engine.dart`) — the reference/test copy: if you
   change the formula, change BOTH `_settle_rating` (SQL) and `RatingEngine`,
   and say so (golden vectors + simulation in `test/rating_engine_test.dart`).
   Display rounds to 0.25 steps (`RankingScale.fmtQuarter`). `reliability`
   (=(1−sigma)·100) + `is_provisional` are generated from `sigma` /
   `competitive_matches`. Casual matches are **unrated**. Full notes:
   `supabase/changes/2026-07-02_rating_engine_v2.sql`.
4. **Match status machine** (don't invent new states):
   `open → full → (time passes) → pending_confirm → completed | disputed`.
   Casual (`match_type = 'casual'`) skips `pending_confirm`.
5. **Don't rewrite whole screens** to fix small issues. Prefer minimal,
   surgical edits. The visual language uses the shared kit in
   `lib/frontend/widgets/common.dart` (`AppCard`, `AppButton`, `AppTag`,
   `AppAvatar`) and themes in `lib/frontend/theme/` — reuse, don't restyle.
6. **No new dependencies** without asking. pubspec is intentionally small
   (supabase_flutter, url_launcher, google_sign_in, sign_in_with_apple…).
7. **Mock data** (`lib/backend/models/mock_data.dart`) is mostly retired but
   `CartLine`, `Product`, `MockData.egp()` are still live for the store —
   don't delete the file.
8. Anything payment-related is **cash-on-delivery only** for now. Do not stub
   or fake a payment gateway; that integration (Paymob/Fawry) is a planned,
   explicit task with a server-side webhook.

## Key flows (so you don't "fix" working behavior)

- **Create match**: `create_match_sheet.dart` → `MatchService.createMatch`
  (inserts `matches` + `match_players`, creator on team A) → root scaffold
  opens `MatchDetailScreen(matchId)` and bumps a key to refresh Home.
- **Join/leave**: via RPCs (`join_match`, `leave_match`) — capacity, min-ELO
  and team balance are checked server-side on purpose. Don't move that to Dart.
- **Score flow**: only players in the match can submit; only the OTHER team
  can confirm; settlement runs inside `confirm_match_result` → `_settle_rating`.
  Sets are stored as team-A-perspective strings, per set `A-B` comma-separated
  (`score_team_a='6-4,3-6,6-2'`); `_settle_rating` parses these for the games
  margin (a `10-8` match tie-break counts as one game).
- **Tournaments**: pair registration in `tournament_entries`
  (player_id + partner_id/partner_name). Bracket lives in
  `tournament_matches` (bracket wb/lb, round, slot). Admin generates the draw
  and records winners; players only read it.
- **Tournaments tab resilience**: `TournamentService.fetchTournaments` has a
  fallback plain query for pre-migration databases. Keep that fallback.
- **Money / Reports (P&L)**: the Reports tab is the platform's profit & loss.
  Money IN = store orders + paid tournament entries + collected repairs + the
  hand-recorded `income` table (money taken outside the app). Money OUT = cost
  of goods sold (auto, `product_costs.cost` × qty on what sold) + trade-in
  credit (auto, accepted offers) + the hand-recorded `expenses` table.
  All of it is computed server-side in `_finance_core` →
  `admin_finance_summary` / `admin_weekly_finance`; Dart mirrors the shapes in
  `lib/admin/data/finance_model.dart` and computes nothing. `LedgerKind` in
  that file is what lets one card + one sheet serve both hand-kept ledgers.
  **There is no "stock" expense category on purpose** — inventory is costed per
  product and hits the P&L as COGS when the item sells; recording a stock
  purchase too would double the cost. Same trap on the income side: never
  hand-record a store order or a paid entry. Finance is visible to super admins
  (and an Analyst holding Reports) via `_can_see_finance()`; only super admins
  may write to either ledger. See `supabase/changes/2026-08-06_expenses_and_pl.sql`
  and `2026-08-06_manual_income.sql`.
- **Weekly report as an emailable link** (added 2026-08-06). A week's P&L can
  be opened without logging in, which is the only way it works from a mail
  client. `report_links` holds one **permanent, reusable** token per week
  (partial unique index on `week_start where not revoked` — asking twice returns
  the same URL). Two Edge Functions, both deployed `--no-verify-jwt`:
  `weekly-report` renders the read-only HTML page (calls `report_render`, which
  is granted to **service_role only** — a leaked token is useless against
  PostgREST), and `weekly-report-send` mails the link via Resend. The sender
  authorises on either an `x-cron-secret` header (pg_cron) or the caller's own
  JWT checked against `_is_admin()`. Minting is super-admin-only
  (`admin_report_link`); `_can_see_finance()` alone is not enough. Secrets
  (`RESEND_API_KEY`, `REPORT_FROM`, `REPORT_TO`, `CRON_SECRET`) are set with
  `supabase secrets set` and are never committed. `REPORT_FROM` must be a
  Resend-verified domain or Gmail spams it. The page recomputes nothing — it
  reads the same `_finance_core` as the console, so the numbers can't disagree;
  its category labels mirror `finance_model.dart`. See
  `supabase/changes/2026-08-06_weekly_report_links.sql`, whose commented
  pg_cron block is the optional Monday auto-send.
  **Who receives it is data, not a secret** (2026-08-07): the
  `report_recipients` table, managed from the weekly card's "Who gets it" row.
  `REPORT_TO` is now only the fallback for an empty list or an unrun migration.
  Everyone gets their own copy via Resend's **batch** endpoint, so no recipient
  sees another's address. The add-a-teammate picker offers only staff who pass
  `_can_see_finance_of()`; anyone else must be typed in. Adding someone is
  super-admin-only because the link needs no login — **being on the list IS
  access to the numbers**. `_access_ids()` was refactored to delegate to the new
  `_access_ids_of(uuid)` (same logic, so every RLS policy calling it is
  unaffected). See `supabase/changes/2026-08-07_report_recipients.sql`.
  **Both Edge Functions are deployed** (2026-08-08, with JWT verification off —
  a deployed `weekly-report` answers `400 No report requested` to a bare GET,
  never `401`; a `401` means the JWT toggle got switched back on). Secrets
  `RESEND_API_KEY` and `REPORT_FROM` are set. What is still missing is the SQL:
  the functions call `report_link_ensure`, `report_render` and
  `report_recipients_active`, so nothing sends until deltas 12 and 13 run.
  **The page MUST be served through Cloudflare, not the Supabase URL**
  (2026-08-10). Supabase's gateway rewrites an Edge Function's
  `Content-Type: text/html` to `text/plain` and adds `nosniff` + a
  `default-src 'none'; sandbox` CSP — deliberate, so `*.supabase.co` can't host
  phishing pages — so the browser paints the page SOURCE instead of the page.
  Nothing set inside the function can override it; the rewrite happens after
  the response leaves the runtime. `functions/report.js` (a Cloudflare **Pages
  Function**, hence the `functions/` dir at the REPO ROOT, not in `docs/`)
  proxies the same body back with the right header at
  `padel-rivals.com/report`, and `REPORT_BASE_URL` points the mailer there.
  Tokens are unchanged, so links already sent keep working.
- **Sponsors / partners** (added 2026-08-06): the `sponsors` table is the
  player-facing "Our Partners" page (`lib/frontend/screens/sponsors/`, read via
  `SponsorService`), reached from the Home "Our Partners" strip. Managed from
  the console's own **Sponsors** section (`sponsors` is a real RBAC section id —
  it lives in `kSections` + `_allIds` AND in SQL `_role_default`; super admin by
  default, grantable). **It carries no money on purpose**: what a sponsor
  actually paid goes in the `income` ledger under category `sponsorship`.
  Never derive one from the other. Tier ids (`title/gold/silver/partner`) are
  mirrored in `SponsorTier` and `sponsors_tier_chk` — change both. See
  `supabase/changes/2026-08-06_sponsors.sql`.
- **The domain, the email stack, and the legal site** (set up 2026-08-08).
  `padel-rivals.com` is registered at GoDaddy but its **DNS lives at
  Cloudflare** — nameservers were moved, so GoDaddy's DNS panel is now a
  dead end and every record change happens in Cloudflare.
  - **Receiving**: Cloudflare **Email Routing** forwards `help@`, `reports@`
    and `no-reply@` to `Padelrivals@gmail.com`. Aliases are free and
    unlimited — add more rather than inventing shared mailboxes. A *destination*
    is the real inbox mail lands in; a *routing rule* is the `@padel-rivals.com`
    address that forwards there. Putting an `@padel-rivals.com` address in the
    destination list is circular and silently bounces everything.
  - **Sending**: **Resend**, free tier (3,000/month, 100/day), root domain
    verified in `eu-west-1`. Its SPF and bounce MX sit on the `send.`
    subdomain, which is why they don't collide with Email Routing's records on
    the apex. **Never add a second SPF or DMARC record** — GoDaddy left a
    `_dmarc` behind and it was edited, not duplicated.
  - **Auth email**: Supabase runs on **custom SMTP** (`smtp.resend.com:587`,
    user `resend`) from `no-reply@padel-rivals.com`. This matters more than it
    looks: the built-in Supabase mailer is capped at ~2 emails/hour and is
    testing-only, so signups and password resets would have started failing
    silently at launch. The rate limit under Authentication → Rate Limits has
    to be raised by hand — enabling custom SMTP does not lift it.
  - **Cloudflare Email Address Obfuscation is OFF for this zone, on purpose.**
    It rewrites every `mailto:` into a JS-decoded blob, which renders the
    contact address as "[email protected]" to anything that doesn't run
    JavaScript — including Google Play's automated policy checks against the
    data-deletion page. Do not turn it back on.
  - **The legal site** is `docs/`, deployed to Cloudflare **Pages** (project
    connected to this repo, no build command, output directory `docs`). Every
    push republishes. Create it from the **Pages** flow, not Workers — the
    Workers flow has no "build output directory" field and will try to *execute*
    `docs` as a shell command.
  - **`docs/privacy.html` and `docs/terms.html` are GENERATED — do not edit
    them.** `legal/build_pages.py` builds them from the `.docx` files in
    `legal/`. Edit the Word document, re-run the script. The generator also
    carries a `PATCHES` list that corrects two paragraphs which the `.docx`
    files still get wrong (they claim a phone number is never public, which
    stopped being true when match tickets shipped). It raises and refuses to
    write if a patched paragraph moves, so the correction cannot silently
    regress — but **the `.docx` files themselves still need updating**.
  - URLs for the stores, extensionless because Pages canonicalises to them:
    `/privacy`, `/terms`, `/delete-account`, and `https://padel-rivals.com` as
    the support URL. Mirrored in `kPrivacyUrl` / `kTermsUrl` /
    `kDeleteAccountUrl` (`help_support_screen.dart`), alongside
    `kSupportEmail = help@padel-rivals.com`.
- **Moderation lives under Reports, not Requests** (moved 2026-08-06).
  `AdminModerationView` is the player-report queue; Requests is repairs +
  trade-ins only. Its server guard is still `_can_edit('requests')`, so
  `navForAccess` deliberately opens the Reports section to anyone holding
  Requests — otherwise Support would lose the queue. They get the Moderation
  half only; the money stays behind `_can_see_finance()`.

## Environment / workflow

- Run `flutter analyze` BEFORE and AFTER changes; fix only what you touched
  plus genuine errors. Don't mass-apply lints across untouched files.
- `flutter pub get` first if dependencies look stale.
- The Supabase URL + anon key are in `lib/main.dart` (anon key is public by
  design; do not move it to a .env without being asked).
- Tests live under `test/` (run `flutter test`) — currently the rating engine
  (`rating_engine_test.dart`: golden vectors + a convergence simulation). Add a
  small test for logic-heavy Dart (e.g. `RankingScale`, `RatingEngine`) rather
  than skipping; keep `RatingEngine` and the SQL `_settle_rating` in lockstep.
- When a task needs DB changes: update the migration file AND list the exact
  SQL the user must re-run in your summary.
- `postgrest`'s `.order(col)` defaults to **descending** (`ascending: false`),
  unlike the JS client. It has bitten chat message order and the Home match
  list — pass `ascending:` explicitly or sort in Dart.

## Two developers, one repo (since 2026-07-31)

- Two laptops push to `origin/master`. The other collaborator is non-technical
  and also uses Claude Code — Claude owns the git mechanics: pull → commit →
  push, explained plainly.
- Loop: `git pull --rebase origin master` → commit → push (`pull.rebase=true`
  is set). **Never force-push master.**
- High-collision files — name what you touched in your summary:
  `supabase/migration_player_app.sql`, `pubspec.yaml` (version),
  `lib/frontend/widgets/common.dart`.
- **Only one person runs SQL on the live DB.** Always say which delta must run
  and ask whether the other person already ran it.
- Claude's memory dir is per-laptop and NOT in git — durable facts belong here
  in CLAUDE.md, not in memory.
- Commits: no `Co-Authored-By` line. On Windows use a PowerShell here-string
  (`git commit -m @'…'@`, closing `'@` at column 0) — bash heredocs fail.
- `desktop_admin/` and `supabase/demo/` are local-only (gitignored).

## Live-DB drift traps

- The live DB predates parts of the migration: `create table if not exists`
  blocks are SKIPPED, so columns/CHECKs inside them never apply. Use
  `alter table … add column if not exists`, and `drop constraint if exists`
  then re-add to widen a CHECK.
- **Adding a status/enum value? Widen the live CHECK in the same change.**
  `matches_status_chk` (from `migrations/0003`) lacked `pending_confirm`, so
  every RANKED score submission failed until 2026-08-01
  (`changes/2026-08-01_matches_status_chk.sql`). Casual matches skip that
  status and kept working, which hid the bug.
- Every DB change also gets a standalone delta in `supabase/changes/` so only
  the new part needs running on live.
- `profiles` RLS in the repo is read-own-row, but the live DB is looser
  (organizer/opponent names do resolve). Verify against live before assuming
  an embed returns other players' rows.

## Known intentional quirks (not bugs)

- Court booking is out of scope — the create flow tells users to book courts
  themselves.
- Losers-bracket pairing is arrival-order, not strict seeded DE crossing.
- Decay job needs the pg_cron extension enabled in Supabase to auto-run.
- Notifications screen reads admin `broadcasts`. Push IS live: FCM on Android +
  APNs on iOS via `PushService`, driven off `notifications` inserts and honouring
  `profiles.notify_*` prefs.
- `division_demo_screen.dart` is a demo/dev screen; ignore it.

## When unsure

Ask before: schema changes, deleting files, renaming public APIs in services,
or touching the rating math. Small UI fixes and obvious bug fixes: just do
them and report.
