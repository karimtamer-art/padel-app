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
  Money IN = store orders + paid tournament entries + collected repairs. Money
  OUT = cost of goods sold (auto, `product_costs.cost` × qty on what sold) +
  trade-in credit (auto, accepted offers) + the hand-recorded `expenses` table.
  All of it is computed server-side in `_finance_core` →
  `admin_finance_summary` / `admin_weekly_finance`; Dart mirrors the shapes in
  `lib/admin/data/finance_model.dart` and computes nothing.
  **There is no "stock" expense category on purpose** — inventory is costed per
  product and hits the P&L as COGS when the item sells; recording a stock
  purchase too would double the cost. Finance is visible to super admins (and
  an Analyst holding Reports) via `_can_see_finance()`; only super admins may
  write an expense. See `supabase/changes/2026-08-06_expenses_and_pl.sql`.

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
