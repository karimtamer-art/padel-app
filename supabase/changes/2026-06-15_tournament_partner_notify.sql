-- ============================================================
-- Incremental change · 2026-06-15
-- Notify a player when they're added to a tournament as a partner
-- ------------------------------------------------------------
-- When an entry is created with a partner_id (a real app user, not a free-text
-- name), send that partner a 'tournament' notification so they know they're in
-- — they didn't register themselves. Own-row RLS scopes it to that partner.
-- Also folded into the canonical migration. Idempotent.
-- ============================================================

create or replace function public.notify_tournament_partner()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  if new.partner_id is null or new.partner_id = new.player_id then
    return new;
  end if;
  select name into v_name from public.tournaments where id = new.tournament_id;
  insert into public.notifications (user_id, type, title, body, data)
  values (new.partner_id,
          'tournament',
          'Added to a tournament',
          'You''re entered in ' || coalesce(v_name, 'a tournament') ||
            ' as a partner.',
          jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
  return new;
end $$;

drop trigger if exists trg_notify_tournament_partner on public.tournament_entries;
create trigger trg_notify_tournament_partner
  after insert on public.tournament_entries
  for each row
  execute function public.notify_tournament_partner();

notify pgrst, 'reload schema';
