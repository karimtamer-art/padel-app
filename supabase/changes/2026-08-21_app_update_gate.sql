-- ─────────────────────────────────────────────────────────────────────────
-- 2026-08-21 · "Please update" for out-of-date builds
--
-- "A newer version is published" is asked of the STORES, not of an admin:
-- Play's in-app update service on Android (the `in_app_update` package —
-- Google offers no version API at all) and Apple's public lookup endpoint on
-- iOS. Nothing has to be typed at release time, so nothing about the published
-- version lives in this table.
--
-- What is here is the part no store can answer:
--
--   update_min_build_<p>   older than this build cannot open the app at all
--   store_url_<p>          link override, for the day a listing moves
--   update_message         optional line shown on both screens
--
-- The minimum is a JUDGEMENT — "this old build talks to the server wrongly" —
-- which is why it stays a human decision and why the console confirms the
-- number out loud before saving it.
--
-- Compared against the BUILD number (pubspec's `+N`), never the version name:
-- the build is the one value guaranteed to only ever go up, and "1.10.0" sorts
-- before "1.9.0" as a string.
--
-- Empty string = no rule, and so is anything that isn't a positive integer, so
-- a half-filled row can never lock anybody out; nor can an unreachable
-- database or a store that won't answer. Only `update_min_build_*` blocks, and
-- only a build strictly BELOW it.
--
-- Written from the console: Broadcasts → App update. Reads are public (the
-- existing "app_settings: read" policy) because a signed-out build sitting on
-- the welcome screen has to be able to check too.
-- ─────────────────────────────────────────────────────────────────────────

insert into public.app_settings (key, value) values
  ('update_min_build_android', ''),
  ('update_min_build_ios',     ''),
  ('store_url_android', 'https://play.google.com/store/apps/details?id=com.padelegypt.app'),
  ('store_url_ios',     'https://apps.apple.com/app/id6786002098'),
  ('update_message',    '')
on conflict (key) do nothing;

-- Verify: five rows, all readable by anon (which is what an unauthenticated
-- launch reads them as).
--   select key, value from public.app_settings
--    where key like 'update\_%' or key like 'store\_url\_%' order by key;
