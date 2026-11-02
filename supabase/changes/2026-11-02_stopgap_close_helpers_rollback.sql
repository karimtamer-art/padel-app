-- ROLLBACK of 2026-11-02_stopgap_close_helpers.sql. Restores what the 2026-11-02 live
-- audit showed: callable by anon and authenticated. This REOPENS the hole, so use it only
-- if the stopgap broke something, and tell whoever is looking at it which call failed.

grant execute on function public._finance_core(date, date) to anon, authenticated;
grant execute on function public._advance_winner(uuid, text, int, int, uuid) to anon, authenticated;
grant execute on function public.apply_rating_decay() to anon, authenticated;
grant execute on function public._award_tournament_season_points(uuid) to anon, authenticated;
grant execute on function public._award_season_points(uuid) to anon, authenticated;
grant execute on function public._settle_rating(uuid) to anon, authenticated;
grant execute on function public._invite_partner(uuid, uuid, text) to anon, authenticated;
grant execute on function public._seed_season_defaults(uuid) to anon, authenticated;
