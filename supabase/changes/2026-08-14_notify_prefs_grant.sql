-- ===========================================================================
-- Fix: push notification preferences could not be saved (2026-08-14)
--
-- THE BUG. `NotificationService.setPref` writes profiles.notify_push /
-- notify_match / notify_tournament / notify_order directly. `authenticated`
-- has no UPDATE grant on those columns, so Postgres refuses the write — and
-- the Dart swallowed the error in `catch (_) {}`. The toggle flipped in the
-- UI, nothing persisted, and re-opening the screen showed the old value.
--
-- Net effect: **a player could not turn push notifications off.** push-notify
-- reads these same columns to decide whether to send, so it kept sending.
--
-- HOW IT HAPPENED. migrations/0004 (June) deliberately revoked blanket UPDATE
-- on profiles and granted back an explicit list of user-editable columns —
-- a good design, and the reason ratings and is_admin are safe from clients.
-- The notify_* columns were added later (2026-07-02, notification prefs) and
-- nobody added them to that list. Same for placement_revealed. The failure is
-- invisible precisely because it is a permission error on a fire-and-forget
-- write.
--
-- THE FIX, in two halves, because the two columns are not the same kind of
-- thing:
--
--   notify_*            → column grant. They are pure self-owned preferences
--                         with no rule attached, exactly like bio and city
--                         which 0004 already grants.
--   placement_revealed  → an RPC, NOT a grant. It sits in the ranking block,
--                         and "no client may write ANY ranking column" is a
--                         far easier invariant to keep than "none except this
--                         one". The RPC can only ever set it to true, for the
--                         caller's own row.
--
-- Idempotent.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The four preference columns join the user-editable list.
--
--    The row policy (profiles_update_own: auth.uid() = id) already restricts
--    WHICH row; this grant restricts WHICH columns. Both must pass, so this
--    lets a player edit their own preferences and nobody else's.
-- ---------------------------------------------------------------------------
grant update (notify_push, notify_match, notify_tournament, notify_order)
  on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- 2. placement_revealed gets an RPC instead, keeping the ranking columns
--    server-only without exception.
--
--    Display-only: it records that the one-time "placement complete" reveal
--    has been shown, so it does not fire on every launch. It never touches
--    rating math. Set-only-to-true so it cannot be used to replay the reveal.
-- ---------------------------------------------------------------------------
create or replace function public.mark_placement_revealed()
returns void
language sql security definer set search_path = public as $$
  update public.profiles
     set placement_revealed = true
   where id = auth.uid() and coalesce(placement_revealed, false) = false;
$$;
grant execute on function public.mark_placement_revealed() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Report what a client may now write, so the list is visible rather than
--    something you have to reconstruct from three migrations.
-- ---------------------------------------------------------------------------
do $$
declare v_cols text; v_missing text;
begin
  select string_agg(column_name, ', ' order by column_name) into v_cols
    from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'profiles'
     and grantee = 'authenticated' and privilege_type = 'UPDATE';
  raise notice 'profiles columns writable by authenticated: %', v_cols;

  select string_agg(c, ', ') into v_missing
    from unnest(array['notify_push','notify_match','notify_tournament','notify_order']) c
   where not exists (
     select 1 from information_schema.column_privileges p
      where p.table_schema='public' and p.table_name='profiles'
        and p.grantee='authenticated' and p.privilege_type='UPDATE'
        and p.column_name = c);
  if v_missing is not null then
    raise exception 'notify grant did not take for: %', v_missing;
  end if;

  -- and the ranking block must stay closed
  select string_agg(p.column_name, ', ') into v_missing
    from information_schema.column_privileges p
   where p.table_schema='public' and p.table_name='profiles'
     and p.grantee='authenticated' and p.privilege_type='UPDATE'
     and p.column_name in ('rating','sigma','level','tier','is_anchor',
                           'competitive_matches','placement_played',
                           'placement_revealed','is_admin','status');
  if v_missing is not null then
    raise exception 'a client can write ranking/privilege column(s): %', v_missing
      using hint = 'Rating changes happen only in Postgres. Revoke these.';
  end if;
end $$;

notify pgrst, 'reload schema';
