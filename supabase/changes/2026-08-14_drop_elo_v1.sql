-- ===========================================================================
-- Remove the v1 ELO layer (2026-08-14)
--
-- ELO was the ORIGINAL rating system, superseded by rating v2 on 2026-07-02
-- and then by V3-F5. `profiles.elo` has not been written by any settlement
-- since v2 shipped -- only the two admin RPCs touched it -- so it has been a
-- frozen column for six weeks.
--
-- That mattered more than "dead column" suggests, because two LIVE code paths
-- were still READING it:
--
--   * join_match gated on `coalesce(elo, 1000) < min_elo`. With elo stale or
--     NULL, every player evaluated as level 1.0 regardless of actual skill, so
--     a levelled match either admitted everyone or nobody.
--   * register_for_tournament gated the same way.
--
-- Both now compare profiles.rating against a rating-native floor. The ELO
-- encoding was already vestigial in the UI: the admin tournament form stored
-- `800 + level*200` and converted it back for display, i.e. it thought in
-- levels and only the storage was ELO.
--
-- UNRATED PLAYERS: the gates use `coalesce(rating, rating_prior())` -- 3.30,
-- the same prior settlement assumes. profiles.rating is NULL until placement
-- completes, and reading that as 0.0 would silently bar every new player from
-- every levelled event. This also closes the inconsistency flagged during the
-- V3-F5 migration, where settlement assumed 3.30 but discovery assumed 2.0.
--
-- WHAT GOES
--   profiles.elo                        matches.min_elo
--   match_players.elo_before/elo_after  tournaments.min_elo / max_elo
--   level_from_elo(int)                 admin_set_player_rating(uuid, int)
--
-- admin_set_player_rating took an ELO int and is dropped, not ported: the
-- rating-native admin_set_rating(uuid, numeric, numeric, boolean, text)
-- already exists and is what the console calls.
--
-- Idempotent. Safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. What we assume about a player with no rating yet. One definition, used by
--    every eligibility gate, matching the c_prior constant inside
--    _settle_rating. A parity test asserts the two agree.
-- ---------------------------------------------------------------------------
create or replace function public.rating_prior()
returns numeric language sql immutable as $$ select 3.30::numeric $$;
grant execute on function public.rating_prior() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Rating-native eligibility floors, backfilled from the ELO ones.
--    min_elo stored `800 + level*200`, so the inverse is (min_elo-800)/200.
--    A 0 (or absent) floor means "no gate" and must stay 0, not become -4.0.
-- ---------------------------------------------------------------------------
alter table public.matches
  add column if not exists min_rating numeric(3,2) not null default 0;
alter table public.tournaments
  add column if not exists min_rating numeric(3,2) not null default 0;
alter table public.tournaments
  add column if not exists max_rating numeric(3,2);

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='matches' and column_name='min_elo') then
    update public.matches
       set min_rating = greatest(0, least(7, round((min_elo - 800) / 200.0, 2)))
     where coalesce(min_elo, 0) > 0 and min_rating = 0;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='tournaments' and column_name='min_elo') then
    update public.tournaments
       set min_rating = greatest(0, least(7, round((min_elo - 800) / 200.0, 2)))
     where coalesce(min_elo, 0) > 0 and min_rating = 0;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='tournaments' and column_name='max_elo') then
    update public.tournaments
       set max_rating = greatest(0, least(7, round((max_elo - 800) / 200.0, 2)))
     where coalesce(max_elo, 0) > 0 and max_rating is null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Every function that read elo / min_elo, re-created rating-native. These
--    bodies are extracted verbatim from migration_player_app.sql so the two
--    files cannot drift.
-- ---------------------------------------------------------------------------
create or replace function public.admin_matches_console(p_limit int default 200)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(x order by x.scheduled_at desc nulls last), '[]'::json)
    from (
      select
        m.id, m.status, m.match_type, m.scheduled_at, m.min_rating, m.winner_team,
        m.score_team_a, m.score_team_b,
        c.venue_name, c.name as court_name,
        (select p.name from public.profiles p where p.id = m.created_by)            as host,
        (select p.name from public.profiles p where p.id = m.result_submitted_by)   as submitted_by,
        (select count(*)::int from public.match_players mp where mp.match_id = m.id) as player_count,
        (select coalesce(json_agg(json_build_object('name', pr.name, 'team', mp.team) order by mp.team), '[]'::json)
           from public.match_players mp join public.profiles pr on pr.id = mp.player_id
          where mp.match_id = m.id)                                                  as players,
        (select coalesce(json_agg(json_build_object(
                   'team', s.team,
                   'submitter', (select p2.name from public.profiles p2 where p2.id = s.submitter_id),
                   'score_a', s.score_team_a, 'score_b', s.score_team_b, 'winner', s.winner) order by s.team), '[]'::json)
           from public.match_result_submissions s where s.match_id = m.id)           as submissions,
        (select max(rh.delta) from public.ranking_history rh where rh.match_id = m.id) as rating_delta
      from public.matches m
      left join public.courts c on c.id = m.court_id
      order by m.scheduled_at desc nulls last
      limit p_limit
    ) x
  );
end $$;

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
      from public.profiles where id = v_uid;
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

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public as $$
declare
  v_name     text;
  v_username text;
  v_dob      date;
  v_gender   text;
  v_hand     text;
  v_side     text;
begin
  v_name := nullif(trim(coalesce(new.raw_user_meta_data->>'name',
                                 new.raw_user_meta_data->>'full_name', '')), '');

  -- keep a valid, free handle from signup metadata; otherwise generate one
  v_username := nullif(lower(trim(coalesce(new.raw_user_meta_data->>'username', ''))), '');
  if v_username is null
     or v_username !~ '^[a-z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where lower(username) = v_username) then
    v_username := public._unique_username(coalesce(v_username, v_name), new.id);
  end if;
  begin
    v_dob := nullif(new.raw_user_meta_data->>'date_of_birth', '')::date;
  exception when others then
    v_dob := null;
  end;
  if v_dob is not null and (v_dob > current_date - interval '13 years'
                         or v_dob < current_date - interval '100 years') then
    v_dob := null;
  end if;
  v_gender := nullif(new.raw_user_meta_data->>'gender', '');
  if v_gender is not null and v_gender not in ('male','female') then v_gender := null; end if;
  v_hand := nullif(new.raw_user_meta_data->>'preferred_hand', '');
  if v_hand not in ('right','left') then v_hand := null; end if;
  v_side := nullif(new.raw_user_meta_data->>'preferred_court_side', '');
  if v_side not in ('left','right','both') then v_side := null; end if;

  begin
    insert into public.profiles
      (id, name, username, avatar_url, phone, bio,
       date_of_birth, gender, preferred_hand, preferred_court_side,
       level, tier, division_pts, placement_played)
    values
      (new.id, v_name, v_username,
       new.raw_user_meta_data->>'avatar_url',
       nullif(new.raw_user_meta_data->>'phone', ''),
       nullif(new.raw_user_meta_data->>'bio', ''),
       v_dob, v_gender,
       coalesce(v_hand, 'right'),
       coalesce(v_side, 'both'),
       -- Start UNRANKED: no seeded level/tier. rating stays NULL, sigma keeps
       -- its default (0.95, the V3-F5 prior's uncertainty). The player earns a
       -- rating over 5 placement matches (or an admin sets it).
       -- placement_played 0 = in placement.
       null, null, 0, 0)
    on conflict (id) do nothing;
  exception when others then
    raise warning 'handle_new_user: % — inserting minimal profile for %', sqlerrm, new.id;
    begin
      insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
    exception when others then
      raise warning 'handle_new_user minimal insert also failed: %', sqlerrm;
    end;
  end;
  return new;
end $$;

create or replace function public.community_member_card(p_community_id uuid, p_player_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_played int; v_wins int; v_rank int; v_joined timestamptz; v_res jsonb;
begin
  select count(*), count(*) filter (where mp.team = m.winner_team)
    into v_played, v_wins
  from public.match_players mp
  join public.matches m on m.id = mp.match_id
  where mp.player_id = p_player_id
    and m.status = 'completed' and m.winner_team is not null;

  select rnk into v_rank from (
    select cm.player_id,
           row_number() over (order by coalesce(pr.rating, pr.level, 0) desc) rnk
      from public.community_members cm
      join public.profiles pr on pr.id = cm.player_id
     where cm.community_id = p_community_id
  ) t where t.player_id = p_player_id;

  select joined_at into v_joined from public.community_members
   where community_id = p_community_id and player_id = p_player_id;

  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'tier', p.tier,
    'level', p.level, 'city', p.city,
    'hand', p.preferred_hand, 'side', p.preferred_court_side,
    'joined', v_joined, 'played', coalesce(v_played, 0),
    'wins', coalesce(v_wins, 0), 'rank', v_rank)
    into v_res from public.profiles p where p.id = p_player_id;
  return v_res;
end $$;

create or replace function public.finalize_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_rated boolean; v_applied boolean; v_owner uuid;
  m record; v_wteam text; v_mid uuid; v_n int := 0;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select rated, coalesce(rating_applied, false), organizer_id
    into v_rated, v_applied, v_owner
    from public.tournaments where id = p_tournament_id;
  if not found then return 'Tournament not found.'; end if;
  if v_applied then return 'Ratings already applied for this tournament.'; end if;

  if not v_rated then
    update public.tournaments set status = 'completed' where id = p_tournament_id;
    return 'Marked complete — this tournament is not rated.';
  end if;

  if exists (select 1 from public.tournament_matches
              where tournament_id = p_tournament_id and winner_entry is null) then
    return 'Finish all current matches before finalizing.';
  end if;
  if not exists (select 1 from public.tournament_matches
                  where tournament_id = p_tournament_id and winner_entry is not null) then
    return 'No completed matches to rate yet.';
  end if;

  for m in
    select tm.id, tm.entry1, tm.entry2, tm.winner_entry, tm.score,
           e1.player_id as a1, e1.partner_id as a2,
           e2.player_id as b1, e2.partner_id as b2
      from public.tournament_matches tm
      join public.tournament_entries e1 on e1.id = tm.entry1
      join public.tournament_entries e2 on e2.id = tm.entry2
     where tm.tournament_id = p_tournament_id
       and tm.winner_entry is not null
  loop
    -- Rate only clean 2v2s of four real profiles (skip guests — no profile).
    if m.a1 is null or m.a2 is null or m.b1 is null or m.b2 is null then continue; end if;
    if m.a1 = m.a2 or m.b1 = m.b2 then continue; end if;
    if m.a1 in (m.b1, m.b2) or m.a2 in (m.b1, m.b2) then continue; end if;
    if exists (select 1 from public.matches where tournament_match_id = m.id) then continue; end if;

    v_wteam := case when m.winner_entry = m.entry1 then 'a' else 'b' end;
    insert into public.matches
      (status, match_type, scheduled_at, created_by, is_private, min_rating,
       winner_team, score_team_a, rating_applied, invite_code, tournament_match_id)
    values
      ('completed', 'ranked', now(), coalesce(v_owner, m.a1), true, 0,
       v_wteam, nullif(m.score, ''), false, 'TRN-' || replace(m.id::text, '-', ''), m.id)
    returning id into v_mid;

    insert into public.match_players (match_id, player_id, team) values
      (v_mid, m.a1, 'a'), (v_mid, m.a2, 'a'),
      (v_mid, m.b1, 'b'), (v_mid, m.b2, 'b');

    perform public._settle_rating(v_mid);
    v_n := v_n + 1;
  end loop;

  -- title + podium season points (separate from the per-match points above)
  perform public._award_tournament_season_points(p_tournament_id);

  update public.tournaments set rating_applied = true, status = 'completed'
   where id = p_tournament_id;
  return v_n || ' match' || (case when v_n = 1 then '' else 'es' end) || ' rated.';
end $$;

create or replace function public.create_match(
  p_competitive  boolean,
  p_scheduled_at timestamptz,
  p_court_id     uuid default null,
  p_partner_id   uuid default null,
  p_min_elo      int default 0,      -- LEGACY, ignored (see below)
  p_open         boolean default true,
  p_min_rating   numeric default 0
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_id      uuid;
  v_private boolean;
begin
  if v_uid is null then raise exception 'Not signed in.'; end if;
  if p_scheduled_at is null then raise exception 'Pick a time for the match.'; end if;

  -- p_open is IGNORED for ranked rather than rejected: an older client that
  -- still sends it shouldn't fail to create a match over a flag it doesn't
  -- know is casual-only.
  v_private := (not coalesce(p_open, true)) and not coalesce(p_competitive, false);

  insert into public.matches
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_rating, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     v_private,
     greatest(0, least(7, coalesce(p_min_rating, 0))),
     case when v_private then public._new_invite_code() else null end)
  returning id into v_id;

  insert into public.match_players (match_id, player_id, team) values (v_id, v_uid, 'a');

  -- The partner is ASKED, not added. They hold the second team-A slot while
  -- they decide; nothing about them is exposed until they accept.
  if p_partner_id is not null and p_partner_id <> v_uid then
    perform public._invite_partner(v_id, p_partner_id, 'a');
  end if;

  return v_id;
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
    from profiles where id = v_uid;
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
      from profiles where id = p_partner_id;
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

create or replace function public.admin_set_rating(
  p_player_id uuid, p_rating numeric, p_sigma numeric,
  p_is_anchor boolean default false, p_notes text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_rating numeric; v_sigma numeric;
  v_old_rating numeric; v_old_sigma numeric; v_old_anchor boolean;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  -- 6dp, matching the engine's own storage grain rather than the old 2dp/4dp
  v_rating := round(greatest(0.0, least(7.0, p_rating)), 6);
  v_sigma  := round(greatest(0.12, least(1.0, p_sigma)), 6);
  select coalesce(rating, coalesce(level, 0)), coalesce(sigma, 0.95), coalesce(is_anchor, false)
    into v_old_rating, v_old_sigma, v_old_anchor
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = round(v_rating, 2),
    tier = public.tier_from_level(v_rating),
    sigma = v_sigma, is_anchor = coalesce(p_is_anchor, false),
    competitive_matches = greatest(coalesce(competitive_matches, 0), 20),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta, engine_version)
  values (p_player_id, null, round(v_old_rating, 2), round(v_rating, 2),
     v_old_rating, v_rating, v_old_sigma, v_sigma,
     round(v_rating - v_old_rating, 6), 'admin');
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid,
    case when coalesce(p_is_anchor, false) then 'set_anchor_rating' else 'leveling_session' end,
    'profile', p_player_id,
    jsonb_build_object('rating', v_old_rating, 'sigma', v_old_sigma, 'is_anchor', v_old_anchor),
    jsonb_build_object('rating', v_rating,     'sigma', v_sigma,     'is_anchor', coalesce(p_is_anchor, false)),
    p_notes);
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Drop the v1 layer. Functions first -- a column cannot go while something
--    still references it.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_set_player_rating(uuid, int);
drop function if exists public.level_from_elo(int);

alter table public.profiles       drop column if exists elo;
alter table public.match_players  drop column if exists elo_before;
alter table public.match_players  drop column if exists elo_after;
alter table public.matches        drop column if exists min_elo;
alter table public.tournaments    drop column if exists min_elo;
alter table public.tournaments    drop column if exists max_elo;

-- ---------------------------------------------------------------------------
-- 5. Prove nothing still reaches for it. A stale reference would otherwise
--    surface only when somebody tried to join a levelled match.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.prosrc like '%level_from_elo%' or p.prosrc like '%min_elo%'
          or p.prosrc like '%max_elo%');
  if v_bad is not null then
    raise exception 'still referencing the v1 ELO layer: %', v_bad;
  end if;
  raise notice 'v1 ELO layer removed. Eligibility is rating-native (prior %).',
    public.rating_prior();
end $$;

notify pgrst, 'reload schema';
