-- ===========================================================================
-- Two loose ends from the last week's migrations (2026-08-15)
--
--   1. profiles.instapay_handle / instapay_link — superseded by
--      payout_accounts on 2026-08-14 and left in place for one release so an
--      older client kept working. Nothing reads them now.
--   2. The unranked prior — settlement and the eligibility gates assume 3.30
--      (rating_prior()), but the matchmaking/discovery RPCs still assume 2.0.
--
-- Both are small, and neither changes any code path's shape. (2) DOES change
-- behaviour — see its section.
--
-- Idempotent.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Drop the retired payout columns.
--
--    Verified first rather than assumed: the delta refuses if any function
--    still reads them, or if a row still holds something payout_accounts does
--    not already have. The second check matters because these columns were
--    deliberately left stale — if a client wrote one after 2026-08-14, that
--    edit never reached payout_accounts and dropping would lose it.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text; v_lost bigint;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosrc like '%profiles%'
     and (p.prosrc like '%instapay_handle%' or p.prosrc like '%instapay_link%')
     and p.prosrc not like '%payout_accounts%'
     and p.prosrc not like '%information_schema%';
  if v_bad is not null then
    raise exception 'function(s) still read profiles.instapay_*: %', v_bad;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='instapay_handle') then
    execute $q$
      select count(*) from public.profiles p
       where (nullif(btrim(p.instapay_handle), '') is not null
              or nullif(btrim(p.instapay_link), '') is not null)
         and not exists (select 1 from public.payout_accounts a
                          where a.player_id = p.id and a.provider = 'instapay')
    $q$ into v_lost;
    if v_lost > 0 then
      raise exception
        '% profile(s) hold payout details that never reached payout_accounts', v_lost
        using hint = 'Re-run 2026-08-14_payout_accounts.sql first, then this.';
    end if;
  end if;
end $$;

alter table public.profiles drop column if exists instapay_handle;
alter table public.profiles drop column if exists instapay_link;

-- ---------------------------------------------------------------------------
-- 2a. The functions the prior change touches, re-created.
--
--     Extracted from migration_player_app.sql rather than hand-copied. Without
--     these the delta would assert a state it never produced — the mistake the
--     player_ratings delta made on 2026-08-15, which its own sweep caught.
-- ---------------------------------------------------------------------------

create or replace function public.register_for_tournament(
  p_tournament_id      uuid,
  p_partner_id         uuid default null,
  p_partner_name       text default null,
  p_instapay_sender    text default null,
  p_instapay_proof_url text default null,
  p_fee_mode           text default 'both')
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_status text; v_start date; v_cap int; v_fee int;
  v_min numeric; v_max numeric; v_my_rating numeric;
  v_count  int; v_my_name text; v_new text;
  v_mode   text; v_pay int; v_tname text; v_eid uuid; v_reg_opens date;
  v_category text; v_my_gender text; v_partner_gender text;
  v_start_time text; v_reg_closed boolean; v_deadline timestamptz;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, start_date, capacity, min_rating, max_rating, entry_fee, name, registration_opens, category,
         start_time, coalesce(registration_closed, false)
    into v_status, v_start, v_cap, v_min, v_max, v_fee, v_tname, v_reg_opens, v_category,
         v_start_time, v_reg_closed
  from public.tournaments where id = p_tournament_id;
  if not found then return 'Tournament not found.'; end if;
  if v_status = 'cancelled' then
    return 'Registration is closed — this tournament has been cancelled.';
  end if;
  if v_reg_opens is not null and current_date < v_reg_opens then
    return 'Registration hasn''t opened for this tournament yet.';
  end if;
  if v_reg_closed then
    return 'Registration for this tournament has been closed by the organizer.';
  end if;
  -- Sign-ups run until 1 hour before the start time — NOT until midnight of the
  -- start day, which used to lock out same-day events before anyone woke up.
  v_deadline := public.tournament_reg_deadline(v_start, v_start_time);
  if v_deadline is not null and now() >= v_deadline then
    return 'Registration is closed — it stops 1 hour before the tournament starts.';
  end if;

  -- capacity (ignore withdrawn; an existing row for this user is a re-register)
  select count(*) into v_count
  from public.tournament_entries
  where tournament_id = p_tournament_id and status <> 'withdrawn' and player_id <> v_uid;
  if v_cap > 0 and v_count >= v_cap then return 'This tournament is full.'; end if;

  -- eligibility
  if v_min > 0 or (v_max is not null and v_max > 0) then
    -- An unrated player is judged at the engine's own prior, not at zero:
    -- profiles.rating is NULL until placement completes, and treating that as
    -- 0.0 would silently bar every new player from every levelled event.
    select coalesce(rating, public.rating_prior()) into v_my_rating
      from public.player_ratings where player_id = v_uid;
    if v_min > 0 and v_my_rating < v_min then
      return 'This event has a minimum level you haven''t reached yet.';
    end if;
    if v_max is not null and v_max > 0 and v_my_rating > v_max then
      return 'Your level is above the maximum for this event.';
    end if;
  end if;

  -- Gender category. Partner gender is only known for a real app user (guest
  -- partners added by the organizer skip this — the organizer vouches for them).
  if coalesce(v_category, 'open') <> 'open' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    if p_partner_id is not null then
      select gender into v_partner_gender from public.profiles where id = p_partner_id;
    end if;
    if v_category = 'mens' then
      if v_my_gender is distinct from 'male'
         or (p_partner_id is not null and v_partner_gender is distinct from 'male') then
        return 'This is a men''s-only event — both players must be men.';
      end if;
    elsif v_category = 'womens' then
      if v_my_gender is distinct from 'female'
         or (p_partner_id is not null and v_partner_gender is distinct from 'female') then
        return 'This is a women''s-only event — both players must be women.';
      end if;
    elsif v_category = 'mixed' then
      if v_my_gender = 'male' and p_partner_id is not null and v_partner_gender = 'male' then
        return 'Mixed event — a team can''t be two men.';
      end if;
    end if;
  end if;

  select name into v_my_name from public.profiles where id = v_uid;

  -- No partner to collect from → registrant covers the whole entry.
  v_mode := case when p_partner_id is null then 'both'
                 else coalesce(nullif(p_fee_mode, ''), 'both') end;
  if v_mode not in ('both', 'split') then v_mode := 'both'; end if;

  v_new := case when coalesce(v_fee, 0) > 0 then 'pending' else 'registered' end;
  v_pay := case when coalesce(v_fee, 0) <= 0 then null
                when v_mode = 'split' then v_fee
                else v_fee * 2 end;

  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status,
     paid_amount, payment_method, instapay_sender, instapay_proof_url, refund_status,
     fee_mode, payer_paid, partner_paid, partner_instapay_sender, partner_instapay_proof_url)
  values (p_tournament_id, v_uid, v_my_name, p_partner_id, p_partner_name, v_new,
     v_pay, case when coalesce(v_fee, 0) > 0 then 'instapay' else null end,
     p_instapay_sender, p_instapay_proof_url, 'none',
     case when coalesce(v_fee, 0) > 0 then v_mode else null end,
     false, false, null, null)
  on conflict (tournament_id, player_id) do update
    set player_name        = excluded.player_name,
        partner_id         = excluded.partner_id,
        partner_name       = excluded.partner_name,
        status             = excluded.status,
        paid_amount        = excluded.paid_amount,
        payment_method     = excluded.payment_method,
        instapay_sender    = excluded.instapay_sender,
        instapay_proof_url = excluded.instapay_proof_url,
        refund_status      = 'none',
        fee_mode           = excluded.fee_mode,
        payer_paid         = false,
        partner_paid       = false,
        partner_instapay_sender    = null,
        partner_instapay_proof_url = null
  returning id into v_eid;

  -- Tailored partner notification for PAID events.
  if coalesce(v_fee, 0) > 0 and p_partner_id is not null and p_partner_id <> v_uid then
    if v_mode = 'split' then
      insert into public.notifications (user_id, type, title, body, data)
      values (p_partner_id, 'tournament', 'Pay your share to lock your spot',
              coalesce(v_my_name, 'Your partner') || ' registered you for ' ||
                coalesce(v_tname, 'a tournament') || '. Pay your EGP ' || v_fee ||
                ' share to confirm your spot.',
              jsonb_build_object('tournament_id', p_tournament_id, 'entry_id', v_eid,
                                 'action', 'pay_share'));
    else
      insert into public.notifications (user_id, type, title, body, data)
      values (p_partner_id, 'tournament', 'You''re in — your entry is paid',
              coalesce(v_my_name, 'Your partner') || ' paid your entry for ' ||
                coalesce(v_tname, 'a tournament') || '. You''re registered together!',
              jsonb_build_object('tournament_id', p_tournament_id, 'entry_id', v_eid));
    end if;
  end if;

  return null;
exception when others then
  return sqlerrm;
end $$;

create or replace function public.mm_set_center_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.mm_center_rating is null and new.created_by is not null then
    select coalesce(rating, level, public.rating_prior()) into new.mm_center_rating
      from public.player_ratings where player_id = new.created_by;
  end if;
  return new;
end $$;

create or replace function public.join_match(
  p_match_id uuid, p_team text default null, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_rating numeric;
  v_my_rating numeric;
  v_partner_rating numeric;
  v_team text;
  v_team_a int;
  v_team_b int;
  v_need int;
  v_private boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, min_rating, is_private into v_status, v_min_rating, v_private
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if coalesce(v_private, false) and not public._may_join_private(p_match_id) then
    return 'This match is private — you need its invite code.';
  end if;

  -- Unrated players are judged at the engine's prior (see rating_prior()),
  -- which is what settlement assumes about them too. Reading a stale ELO here
  -- made every player evaluate as level 1.0 regardless of actual skill.
  select coalesce(rating, public.rating_prior()) into v_my_rating
    from player_ratings where player_id = v_uid;
  if v_my_rating < v_min_rating then
    return 'This match needs level ' || trim(to_char(v_min_rating, 'FM9.99')) || '+.';
  end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null; -- already in: treat as success
  end if;

  -- Bringing a partner: validate them before we touch anything.
  if p_partner_id is not null then
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    select coalesce(rating, public.rating_prior()) into v_partner_rating
      from player_ratings where player_id = p_partner_id;
    if not found then return 'Partner not found.'; end if;
    if v_partner_rating < v_min_rating then
      return 'Your partner needs level '
             || trim(to_char(v_min_rating, 'FM9.99')) || '+ for this match.';
    end if;
  end if;

  -- Capacity now counts reserved slots, so a stranger can't take the seat a
  -- host is holding for their invited partner.
  v_need  := case when p_partner_id is not null then 2 else 1 end;
  v_count := public._match_taken(p_match_id);
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match is already full.' end;
  end if;

  v_team_a := public._team_taken(p_match_id, 'a');
  v_team_b := public._team_taken(p_match_id, 'b');

  if p_partner_id is not null then
    -- A pair needs one side with two open slots.
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    -- auto-balance teams unless caller asked for one
    v_team := coalesce(p_team, case when v_team_a <= v_team_b then 'a' else 'b' end);
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      return 'This match is already full.';
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  -- Raises (and rolls back this join) if the partner can't be invited.
  if p_partner_id is not null then
    perform public._invite_partner(p_match_id, p_partner_id, v_team);
  end if;

  -- Only real players fill a match; a held slot keeps it 'open'.
  if (select count(*) from match_players where match_id = p_match_id) >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;

create or replace function public.mm_accept(p_match_id uuid, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_status     text;
  v_created_by uuid;
  v_center     numeric;
  v_created_at timestamptz;
  v_my_rating  numeric;
  v_my_plac    boolean;
  v_cr_plac    boolean;
  v_count      int;
  v_team_a     int;
  v_team_b     int;
  v_team       text;
  v_need       int;
  v_hw         numeric;
  v_partner_rating numeric;
  v_private    boolean;
  v_type       text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at,
         is_private, match_type
    into v_status, v_created_by, v_center, v_created_at, v_private, v_type
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if coalesce(v_private, false) and not public._may_join_private(p_match_id) then
    return 'This match is private — you need its invite code.';
  end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null;
  end if;

  if p_partner_id is not null then
    if v_created_by = p_partner_id then
      return 'That player created this match.';
    end if;
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    if not exists (select 1 from profiles where id = p_partner_id) then
      return 'Partner not found.';
    end if;
  end if;

  v_need  := case when p_partner_id is not null then 2 else 1 end;
  v_count := public._match_taken(p_match_id);
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match just filled up.' end;
  end if;

  -- ── THE FIX ────────────────────────────────────────────────────────────
  -- Casual is unrated: no band, no placed/unplaced split. Mirrors the clause
  -- mm_candidates and mm_player_sees_match have always had. Skipping the whole
  -- block (not just the split) matters — the band check underneath would
  -- refuse a casual match on rating distance instead, which is the same bug
  -- wearing a different error message.
  if v_type is distinct from 'casual' then
    select coalesce(rating, level, public.rating_prior()), (coalesce(placement_played, 0) < 5)
      into v_my_rating, v_my_plac from profiles where id = v_uid;
    select (coalesce(placement_played, 0) < 5) into v_cr_plac
      from profiles where id = v_created_by;

    if v_my_plac or v_cr_plac then
      if not (v_my_plac and v_cr_plac) then
        return 'This match is outside your matchmaking pool.';
      end if;
    else
      v_hw := public.mm_band_halfwidth(extract(epoch from (now() - v_created_at)) / 60.0);
      if abs(v_my_rating - v_center) > v_hw then
        return 'This match is outside your rating band.';
      end if;
      if p_partner_id is not null then
        select coalesce(rating, level, public.rating_prior()) into v_partner_rating
          from player_ratings where player_id = p_partner_id;
        if abs(coalesce(v_partner_rating, 2.0) - v_center) > v_hw then
          return 'Your partner is outside this match''s rating band.';
        end if;
      end if;
    end if;
  end if;

  v_team_a := public._team_taken(p_match_id, 'a');
  v_team_b := public._team_taken(p_match_id, 'b');

  if p_partner_id is not null then
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    v_team := case when v_team_a <= v_team_b then 'a' else 'b' end;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      return 'This match just filled up.';
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  -- Raises (and rolls back this join) if the partner can't be invited.
  if p_partner_id is not null then
    perform public._invite_partner(p_match_id, p_partner_id, v_team);
  end if;

  if (select count(*) from match_players where match_id = p_match_id) >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. One prior for an unrated player, everywhere.
--
--    profiles.rating is NULL until placement completes, so every path that
--    needs a number for an unrated player picks a stand-in. Settlement uses
--    3.30 (the engine's own prior) and, since 2026-08-14, so do join_match and
--    register_for_tournament via rating_prior(). The matchmaking and discovery
--    RPCs were left on the old 2.0 because changing them moves who sees which
--    matches and there was no test coverage. Finishing it now.
--
--    THIS CHANGES BEHAVIOUR, deliberately: an unrated player is currently
--    SURFACED as a 2.0 while being RATED as a 3.30, so they get shown weaker
--    opponents than the engine will judge them against — and then take a
--    larger rating hit than the matchmaking implied. After this they are
--    treated as 3.30 throughout.
--
--    The affected functions are re-created by the migration; this section only
--    asserts the result, because the substitution is mechanical
--    (`coalesce(rating, level, 2.0)` -> `coalesce(rating, level,
--    public.rating_prior())`) and lives in migration_player_app.sql.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosrc like '%coalesce(rating, level, 2.0)%';
  if v_bad is not null then
    raise exception 'function(s) still assume an unranked player is 2.0: %', v_bad
      using hint = 'They should call public.rating_prior() like everything else.';
  end if;

  raise notice 'unranked prior is now rating_prior() = % everywhere.',
    public.rating_prior();
end $$;

notify pgrst, 'reload schema';
