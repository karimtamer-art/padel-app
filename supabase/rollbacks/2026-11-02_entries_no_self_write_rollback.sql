-- ROLLBACK of 2026-11-02_entries_no_self_write.sql. Reopens direct player writes, exactly
-- as live had them on 2 Nov.
drop policy if exists "register self" on public.tournament_entries;
create policy "register self" on public.tournament_entries
  for insert with check (auth.uid() = player_id);
drop policy if exists "tournament_entries: insert own" on public.tournament_entries;
create policy "tournament_entries: insert own" on public.tournament_entries
  for insert with check (auth.uid() = player_id);
drop policy if exists "withdraw self" on public.tournament_entries;
create policy "withdraw self" on public.tournament_entries
  for update using (auth.uid() = player_id);
drop policy if exists "t_entries: withdraw own" on public.tournament_entries;
create policy "t_entries: withdraw own" on public.tournament_entries
  for update using (player_id = auth.uid())
  with check (player_id = auth.uid() and status = 'withdrawn');
