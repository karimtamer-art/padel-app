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
2. **Rating changes happen ONLY in Postgres** (`_settle_elo`,
   `submit_match_result`, `confirm_match_result`, `join_match`,
   `record_bracket_winner`, `generate_draw`). Never compute or write
   ELO/level from the client — that's the anti-cheat boundary.
3. **One rating engine, one display.** `profiles.elo` is the engine;
   `profiles.level` (0.0–7.0) is derived via `level = (elo − 800) / 200`,
   mirrored in Dart by `RankingScale.levelFromElo`. If you touch the mapping,
   change BOTH the SQL (`level_from_elo`) and the Dart helper, and say so.
   UI shows Level + Division as the main rank; raw ELO is secondary.
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
  can confirm; settlement runs inside `confirm_match_result`. Sets are stored
  as team-A-perspective strings (`score_team_a='6,3,6'`).
- **Tournaments**: pair registration in `tournament_entries`
  (player_id + partner_id/partner_name). Bracket lives in
  `tournament_matches` (bracket wb/lb, round, slot). Admin generates the draw
  and records winners; players only read it.
- **Tournaments tab resilience**: `TournamentService.fetchTournaments` has a
  fallback plain query for pre-migration databases. Keep that fallback.

## Environment / workflow

- Run `flutter analyze` BEFORE and AFTER changes; fix only what you touched
  plus genuine errors. Don't mass-apply lints across untouched files.
- `flutter pub get` first if dependencies look stale.
- The Supabase URL + anon key are in `lib/main.dart` (anon key is public by
  design; do not move it to a .env without being asked).
- There is no test suite yet. If you add logic-heavy Dart (e.g. anything in
  `RankingScale`), add a small test under `test/` rather than skipping.
- When a task needs DB changes: update the migration file AND list the exact
  SQL the user must re-run in your summary.

## Known intentional quirks (not bugs)

- Court booking is out of scope — the create flow tells users to book courts
  themselves.
- Losers-bracket pairing is arrival-order, not strict seeded DE crossing.
- Decay job needs the pg_cron extension enabled in Supabase to auto-run.
- Notifications screen reads admin `broadcasts`; there is no push (FCM) yet.
- `division_demo_screen.dart` is a demo/dev screen; ignore it.

## When unsure

Ask before: schema changes, deleting files, renaming public APIs in services,
or touching the rating math. Small UI fixes and obvious bug fixes: just do
them and report.
