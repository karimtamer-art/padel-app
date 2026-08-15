-- ===========================================================================
-- player_ratings — move the ranking columns off `profiles` (2026-08-15)
--
-- Moves the 11 ranking columns off `profiles` into their own table. They do
-- not describe a person: they are engine state, written on every settled match
-- (where the rest of the row is written almost never), owned exclusively by
-- the server, and they are the anti-cheat boundary.
--
-- DONE IN ONE MOVE, not phased behind a mirror. A phased version — keep the
-- profiles columns as trigger-maintained copies, migrate readers later, drop
-- them last — buys uptime, and this app has no users yet beyond testers.
-- Paying for uptime you do not need costs a duplicate write path, a mirror
-- trigger and eleven columns that everyone has to remember are not the real
-- ones. Better to land it clean while that is still cheap.
--
-- The safety net instead is section 6: before the old columns are dropped, the
-- catalog is swept for any function still reading profiles.<ranking column>,
-- and the migration ABORTS naming it. A missed reader is caught here rather
-- than at runtime.
--
-- A REAL GAIN: player_ratings has NO column grants to
-- `authenticated` at all. On profiles, `rating` is safe because somebody
-- remembered not to grant it — and that exact omission is what broke the
-- notify_* columns for six weeks (2026-08-14). Here it is safe by
-- construction: clients cannot write the table, full stop.
--
-- Idempotent.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The table. Same types, same defaults, same generated expressions as the
--    profiles columns it replaces, so the backfill is a straight copy.
-- ---------------------------------------------------------------------------
create table if not exists public.player_ratings (
  player_id uuid primary key references public.profiles(id) on delete cascade,

  -- ── engine state (V3-F5) ──
  -- Full internal precision; the engine does no rounding of its own.
  rating      numeric(9,6),
  sigma       numeric not null default 0.95,
  is_anchor   boolean not null default false,
  competitive_matches int not null default 0,
  last_competitive_match_at timestamptz,

  -- ── display mirrors of rating, never read back into the math ──
  level       numeric,
  tier        text,

  -- ── placement / reveal ──
  placement_played   int     not null default 0,
  placement_revealed boolean not null default false,

  updated_at timestamptz not null default now()
);

do $$ begin
  alter table public.player_ratings
    add constraint player_ratings_sigma_range check (sigma >= 0.12 and sigma <= 1.0);
exception when duplicate_object then null; end $$;

alter table public.player_ratings
  add column if not exists reliability numeric
    generated always as (round((1 - sigma / 1.0) * 100, 0)) stored;
alter table public.player_ratings
  add column if not exists is_provisional boolean
    generated always as (sigma > 0.58 or competitive_matches < 20) stored;

comment on table public.player_ratings is
  'V3-F5 engine state, one row per player. Server-written only: no column '
  'grants to authenticated exist, so the anti-cheat boundary is structural '
  'rather than a rule someone has to remember. The equivalent profiles '
  'columns were dropped in the same change; there is no mirror.';

create index if not exists player_ratings_rating_idx
  on public.player_ratings (rating desc nulls last);

-- ---------------------------------------------------------------------------
-- 2. Backfill. Every profile gets a row, so readers never need to care about
--    a missing one.
-- ---------------------------------------------------------------------------
-- Guarded: section 5 drops the source columns, so on any RE-RUN this copy
-- must not be attempted. The second branch still gives every profile a row.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='rating') then
    execute $q$
      insert into public.player_ratings (
        player_id, rating, sigma, is_anchor, competitive_matches,
        last_competitive_match_at, level, tier, placement_played,
        placement_revealed)
      select p.id, p.rating, coalesce(p.sigma, 0.95),
             coalesce(p.is_anchor, false), coalesce(p.competitive_matches, 0),
             p.last_competitive_match_at, p.level, p.tier,
             coalesce(p.placement_played, 0), coalesce(p.placement_revealed, false)
        from public.profiles p
      on conflict (player_id) do nothing
    $q$;
  else
    insert into public.player_ratings (player_id)
    select p.id from public.profiles p
    on conflict (player_id) do nothing;
  end if;
end $$;

-- New signups get their row automatically, so handle_new_user does not have to
-- remember (and neither does any future path that creates a profile).
create or replace function public._player_ratings_row()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.player_ratings (player_id) values (new.id)
  on conflict (player_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_player_ratings_row on public.profiles;
create trigger trg_player_ratings_row
  after insert on public.profiles
  for each row execute function public._player_ratings_row();

-- ---------------------------------------------------------------------------
-- 3. RLS. Ratings are not secret — they are on every player card, lobby row
--    and leaderboard — so any signed-in user may READ. Nobody may write:
--    there is no insert/update/delete policy and no column grant, so the only
--    writers are SECURITY DEFINER functions (the engine and the admin RPC).
-- ---------------------------------------------------------------------------
alter table public.player_ratings enable row level security;

do $$ begin
  create policy "player_ratings: read all" on public.player_ratings
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

grant select on public.player_ratings to authenticated;
revoke insert, update, delete on public.player_ratings from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 3b. Every function that touched a ranking column, re-created against
--     player_ratings.
--
--     These bodies are EXTRACTED from migration_player_app.sql rather than
--     hand-copied, so the two files cannot disagree. Without them this delta
--     creates the table and then correctly refuses to drop the old columns,
--     because the functions on the database are still the old ones — which is
--     exactly what section 4 is for.
--
--     Reads are scalar subqueries, not joins:
--         (select rating from public.player_ratings where player_id = p.id)
--     A join has to be placed correctly inside a query shape; a scalar
--     subquery is valid anywhere the profile's id is already in scope, which
--     is what makes ~90 mechanical rewrites safe without a compiler.
--
--     Signatures are unchanged, so create-or-replace keeps every GRANT.
-- ---------------------------------------------------------------------------

create or replace function public.admin_players_console()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(row_to_json(x) order by x.rating desc nulls last), '[]'::json)
    from (
      select
        p.id,
        p.name,
        p.username,
        p.avatar_url,
        p.city,
        p.phone,
        u.email,
        u.last_sign_in_at,
        p.created_at                                          as joined,
        coalesce((select rating from public.player_ratings where player_id = p.id), (select level from public.player_ratings where player_id = p.id), 0)::numeric               as rating,
        coalesce((select level from public.player_ratings where player_id = p.id), (select rating from public.player_ratings where player_id = p.id), 0)::numeric               as level,
        (select sigma from public.player_ratings where player_id = p.id)::numeric                                      as sigma,
        (select reliability from public.player_ratings where player_id = p.id)::numeric                                as reliability,
        -- fallback only fires on a DB without the generated column; the
        -- threshold matches it (V3-F5 confidence gate, 2026-08-13)
        coalesce((select is_provisional from public.player_ratings where player_id = p.id),
                 coalesce((select competitive_matches from public.player_ratings where player_id = p.id), 0) < 20)     as is_provisional,
        coalesce((select competitive_matches from public.player_ratings where player_id = p.id), 0)                    as competitive_matches,
        coalesce((select placement_played from public.player_ratings where player_id = p.id), 0)                       as placement_played,
        coalesce((select is_anchor from public.player_ratings where player_id = p.id), false)                          as is_anchor,
        coalesce(p.status, 'active')                          as status,
        coalesce(agg.played, 0)                               as played,
        coalesce(agg.wins, 0)                                 as wins,
        coalesce(agg.played, 0) - coalesce(agg.wins, 0)       as losses,
        rank() over (order by coalesce((select rating from public.player_ratings where player_id = p.id), (select level from public.player_ratings where player_id = p.id), 0) desc) as rank
      from public.profiles p
      left join auth.users u on u.id = p.id
      left join lateral (
        select
          count(*)::int                                        as played,
          count(*) filter (where m.winner_team = mp.team)::int as wins
        from public.match_players mp
        join public.matches m on m.id = mp.match_id
        where mp.player_id = p.id
          and m.status = 'completed'
          and m.winner_team is not null
      ) agg on true
      where coalesce(p.is_admin, false) = false
    ) x
  );
end $$;

create or replace function public.admin_dashboard_counts()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then
    return json_build_object('error', 'admins_only');
  end if;
  return json_build_object(
    'players',     (select count(*) from public.profiles where coalesce(is_admin, false) = false),
    'matches',     (select count(*) from public.matches),
    'courts',      (select count(*) from public.courts),
    'tournaments', (select count(*) from public.tournaments),
    'divisions',   (select coalesce(json_object_agg(tier, c), '{}'::json) from (
                      select coalesce(r.tier, 'bronze') as tier, count(*) as c
                        from public.profiles p
                        join public.player_ratings r on r.player_id = p.id
                       where coalesce(p.is_admin, false) = false
                       group by 1) t),
    -- Store money. The app takes cash on delivery and InstaPay transfers, so
    -- this is real revenue today — it never depended on a payment gateway.
    'revenue',           (select coalesce(sum(o.total), 0)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')),
    'revenue_delivered', (select coalesce(sum(o.total), 0)::int from public.orders o
                           where o.status = 'delivered'),
    'revenue_month',     (select coalesce(sum(o.total), 0)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
                             and o.created_at >= now() - interval '30 days'),
    'orders',            (select count(*)::int from public.orders o
                           where coalesce(o.status, 'pending') not in ('cancelled', 'refunded'))
  );
end $$;

create or replace function public.generate_draw(p_tournament_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_entries uuid[];
  v_n int;
  v_size int := 2;
  v_slots int;
  i int;
  e1 uuid; e2 uuid;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;

  -- seed: best pairs first (pair level = avg of player + partner if known).
  -- Eligible = confirmed roster: free events land on 'registered', paid events
  -- on 'paid' once verified (never 'registered'), so both must count or paid
  -- tournaments draw from 0 pairs. LEFT JOIN profiles so guest entries
  -- (player_id NULL) are kept — they seed at level 0, drawn but unrated.
  select array_agg(id order by lvl desc) into v_entries from (
    select te.id,
           ( coalesce((select level from public.player_ratings where player_id = p1.id), 0) + coalesce((select level from public.player_ratings where player_id = p2.id), (select level from public.player_ratings where player_id = p1.id), 0) ) / 2.0 as lvl
      from tournament_entries te
      left join profiles p1 on p1.id = te.player_id
      left join profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status in ('registered', 'paid', 'confirmed')
  ) s;

  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 confirmed pairs.'; end if;

  while v_size < v_n loop v_size := v_size * 2; end loop;
  v_slots := v_size / 2;

  delete from tournament_matches where tournament_id = p_tournament_id;

  -- slot i: seed (i+1) vs seed (size - i); missing seed = bye
  for i in 0 .. v_slots - 1 loop
    e1 := v_entries[i + 1];
    e2 := case when (v_size - i) <= v_n then v_entries[v_size - i] else null end;
    insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, winner_entry)
    values (p_tournament_id, 'wb', 1, i, e1, e2,
            case when e2 is null then e1 else null end);
  end loop;

  -- propagate byes into round 2
  for i in 0 .. v_slots - 1 loop
    select entry1, winner_entry into e1, e2
      from tournament_matches
     where tournament_id = p_tournament_id and bracket='wb' and round=1 and slot=i;
    if e2 is not null then
      perform public._advance_winner(p_tournament_id, 'wb', 1, i, e2);
    end if;
  end loop;

  return null;
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
       date_of_birth, gender, preferred_hand, preferred_court_side)
    values
      (new.id, v_name, v_username,
       new.raw_user_meta_data->>'avatar_url',
       nullif(new.raw_user_meta_data->>'phone', ''),
       nullif(new.raw_user_meta_data->>'bio', ''),
       v_dob, v_gender,
       coalesce(v_hand, 'right'),
       coalesce(v_side, 'both'))
    -- Ranking state is NOT set here. trg_player_ratings_row creates the
    -- player_ratings row from its defaults: rating NULL (unranked), sigma
    -- 0.95 (the V3-F5 prior's uncertainty), placement_played 0. The player
    -- earns a rating over 5 placement matches, or an admin sets one.
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

create or replace function public.mm_set_center_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.mm_center_rating is null and new.created_by is not null then
    select coalesce(rating, level, 2.0) into new.mm_center_rating
      from public.player_ratings where player_id = new.created_by;
  end if;
  return new;
end $$;

create or replace function public.fanout_broadcast()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'broadcast', new.title, new.body,
         jsonb_build_object('broadcast_id', new.id, 'segment', new.segment)
  from public.profiles p
  where p.is_admin = false
    and case coalesce(new.segment, 'all')
          when 'all'      then true
          when 'ranked'   then coalesce((select placement_played from public.player_ratings where player_id = p.id), 0) >= 5
          when 'unranked' then coalesce((select placement_played from public.player_ratings where player_id = p.id), 0) < 5
          when 'specific' then p.id = any(coalesce(new.player_ids, '{}'::uuid[]))
          else true
        end;
  return new;
end $$;

create or replace function public.admin_list_staff()
returns table (
  id uuid, name text, email text, username text,
  admin_role text, admin_access jsonb, admin_scope text,
  is_owner boolean, avatar_url text, level numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._has_access('team') then return; end if;
  return query
    select p.id, p.name, u.email::text, p.username,
           p.admin_role, p.admin_access, p.admin_scope,
           coalesce(p.is_owner, false), p.avatar_url, (select level from public.player_ratings where player_id = p.id)::numeric
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is not null
     order by coalesce(p.is_owner, false) desc, p.name nulls last;
end $$;

create or replace function public.admin_search_users(p_term text)
returns table (id uuid, name text, email text, level numeric, avatar_url text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._has_access('team') then return; end if;
  if length(btrim(coalesce(p_term, ''))) < 2 then return; end if;
  return query
    select p.id, p.name, u.email::text, (select level from public.player_ratings where player_id = p.id)::numeric, p.avatar_url
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is null
       and (p.name ilike '%' || p_term || '%' or u.email ilike '%' || p_term || '%')
     order by p.name nulls last
     limit 8;
end $$;

create or replace function public.organizer_community_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid; v_res jsonb;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return '{}'::jsonb;
  end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return '{}'::jsonb; end if;
  select jsonb_build_object(
    'members', (select count(*) from public.community_members where community_id = v_cid),
    'inbox_unread', (
      select count(*) from (
        select cm.member_id,
               (array_agg(cm.sender_role order by cm.created_at desc))[1] as last_role
          from public.community_messages cm
         where cm.community_id = v_cid
         group by cm.member_id
      ) t where t.last_role = 'member'),
    'events_week', (
      select count(*) from public.tournaments
       where organizer_id = v_uid and start_date is not null
         and start_date between current_date and current_date + 7),
    'matches_made', (
      select count(*) from public.tournament_matches m
       join public.tournaments t on t.id = m.tournament_id
       where t.organizer_id = v_uid and m.winner_entry is not null),
    'tier_bronze', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce((select level from public.player_ratings where player_id = p.id), 0) < 3.5),
    'tier_gold', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce((select level from public.player_ratings where player_id = p.id), 0) >= 3.5 and coalesce((select level from public.player_ratings where player_id = p.id), 0) < 5.0),
    'tier_elite', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce((select level from public.player_ratings where player_id = p.id), 0) >= 5.0)
  ) into v_res;
  return v_res;
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
           row_number() over (order by coalesce((select rating from public.player_ratings where player_id = pr.id), (select level from public.player_ratings where player_id = pr.id), 0) desc) rnk
      from public.community_members cm
      join public.profiles pr on pr.id = cm.player_id
     where cm.community_id = p_community_id
  ) t where t.player_id = p_player_id;

  select joined_at into v_joined from public.community_members
   where community_id = p_community_id and player_id = p_player_id;

  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'avatar_url', p.avatar_url, 'tier', (select tier from public.player_ratings where player_id = p.id),
    'level', (select level from public.player_ratings where player_id = p.id), 'city', p.city,
    'hand', p.preferred_hand, 'side', p.preferred_court_side,
    'joined', v_joined, 'played', coalesce(v_played, 0),
    'wins', coalesce(v_wins, 0), 'rank', v_rank)
    into v_res from public.profiles p where p.id = p_player_id;
  return v_res;
end $$;

create or replace function public.generate_from_format(
  p_tournament_id uuid, p_random boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_spec jsonb; v_stage jsonb; v_kind text;
  v_entries uuid[]; v_n int; v_g int;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select format_spec into v_spec from public.tournaments where id = p_tournament_id;
  if v_spec is null or jsonb_array_length(coalesce(v_spec->'stages', '[]'::jsonb)) = 0 then
    return 'No saved format to generate from.';
  end if;
  v_stage := v_spec->'stages'->0;
  v_kind := v_stage->>'kind';

  -- Eligible = confirmed roster (registered | paid | confirmed); LEFT JOIN so
  -- guest entries (player_id NULL) are drawn too. See generate_draw for why.
  select array_agg(id order by (case when p_random then random() else lvl end) desc)
    into v_entries from (
    select te.id,
           ((coalesce((select level from public.player_ratings where player_id = p1.id), 0) + coalesce((select level from public.player_ratings where player_id = p2.id), (select level from public.player_ratings where player_id = p1.id), 0)) / 2.0)::float8 as lvl
      from public.tournament_entries te
      left join public.profiles p1 on p1.id = te.player_id
      left join public.profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status in ('registered', 'paid', 'confirmed')
  ) s;
  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 confirmed pairs.'; end if;

  delete from public.tournament_matches where tournament_id = p_tournament_id;

  if v_kind = 'groups' then
    v_g := coalesce((v_stage->'cfg'->>'groups')::int, 4);
    declare gi int; a int; b int; v_label text; v_slot int; grp uuid[];
    begin
      for gi in 0 .. v_g - 1 loop
        grp := array(select v_entries[i] from generate_series(1, v_n) i where ((i - 1) % v_g) = gi);
        v_label := 'Group ' || chr(65 + gi);
        v_slot := 0;
        for a in 1 .. coalesce(array_length(grp, 1), 0) loop
          for b in a + 1 .. coalesce(array_length(grp, 1), 0) loop
            insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
            values (p_tournament_id, v_label, 1, v_slot, grp[a], grp[b], 0);
            v_slot := v_slot + 1;
          end loop;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind = 'roundRobin' then
    declare a int; b int; v_slot int := 0;
    begin
      for a in 1 .. v_n loop
        for b in a + 1 .. v_n loop
          insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, stage)
          values (p_tournament_id, 'Round robin', 1, v_slot, v_entries[a], v_entries[b], 0);
          v_slot := v_slot + 1;
        end loop;
      end loop;
    end;
    return null;

  elsif v_kind in ('knockout', 'doubleElim', 'consolation') then
    perform public._build_ko_round(p_tournament_id, 0, 1, v_entries);
    return null;

  else
    return 'The first stage (' || coalesce(v_kind, '?') || ') is drawn manually for now.';
  end if;
end $$;

create or replace function public._award_season_points(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; v_frozen boolean;
  v_win int; v_loss int; v_streak int; v_upset int;
  v_winner text; v_type text;
  v_avg_a numeric; v_avg_b numeric;
  v_upset_a boolean; v_upset_b boolean;
  r record; v_prev_wins int; v_won boolean; v_is_upset boolean;
begin
  select s.id, s.frozen into v_sid, v_frozen
    from public.seasons s where s.status = 'live' limit 1;
  if v_sid is null or v_frozen then return; end if;

  select m.winner_team, m.match_type into v_winner, v_type
    from public.matches m where m.id = p_match_id;
  if v_winner is null then return; end if;
  if coalesce(v_type, 'ranked') <> 'ranked' then return; end if;  -- casual is unrated

  select coalesce((select pts from public.season_rules where season_id = v_sid and code = 'win'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'loss'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'streak'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'upset'), 0)
    into v_win, v_loss, v_streak, v_upset;

  select avg(coalesce((select rating from public.player_ratings where player_id = p.id), 2.0)) filter (where mp.team = 'a'),
         avg(coalesce((select rating from public.player_ratings where player_id = p.id), 2.0)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b
    from public.match_players mp join public.profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 2.0); v_avg_b := coalesce(v_avg_b, 2.0);
  -- an upset = the winning pair was rated at least 0.5 below the pair it beat
  v_upset_a := (v_winner = 'a' and v_avg_b - v_avg_a >= 0.5);
  v_upset_b := (v_winner = 'b' and v_avg_a - v_avg_b >= 0.5);

  for r in
    select mp.player_id, mp.team from public.match_players mp
     where mp.match_id = p_match_id
  loop
    v_won := (r.team = v_winner);
    v_is_upset := (r.team = 'a' and v_upset_a) or (r.team = 'b' and v_upset_b);

    insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
    values (v_sid, r.player_id, case when v_won then 'win' else 'loss' end,
            case when v_won then v_win else v_loss end, p_match_id)
    on conflict do nothing;

    if v_won and v_streak > 0 then
      -- consecutive wins BEFORE this match (ranking_history for this match is
      -- written after this call, so counting back from the newest row is safe)
      with h as (
        select rh.won, row_number() over (order by rh.created_at desc) as rn
          from public.ranking_history rh
         where rh.profile_id = r.player_id and rh.match_id is not null and rh.won is not null
         order by rh.created_at desc
         limit 30
      ), first_loss as (
        select coalesce(min(rn), 999) as rn from h where h.won is false
      )
      select count(*)::int into v_prev_wins
        from h, first_loss where h.rn < first_loss.rn and h.won;

      if coalesce(v_prev_wins, 0) + 1 >= 3 then
        insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
        values (v_sid, r.player_id, 'streak', v_streak, p_match_id)
        on conflict do nothing;
      end if;
    end if;

    if v_won and v_is_upset and v_upset > 0 then
      insert into public.season_points (season_id, player_id, rule_code, pts, match_id)
      values (v_sid, r.player_id, 'upset', v_upset, p_match_id)
      on conflict do nothing;
    end if;
  end loop;
end $$;

create or replace function public.season_standings(p_season_id uuid)
returns table (
  rank int, player_id uuid, name text, avatar_url text, tier text,
  pts int, played int, trend int
)
language sql stable security definer set search_path = public as $$
  with agg as (
    select sp.player_id,
           sum(sp.pts)::int as pts,
           count(distinct sp.match_id) filter (where sp.match_id is not null)::int as played
      from public.season_points sp
     where sp.season_id = p_season_id
       and not coalesce(sp.voided, false)
     group by sp.player_id
  ),
  ranked as (
    select row_number() over (order by a.pts desc, p.name nulls last, a.player_id)::int as rank,
           a.player_id, coalesce(p.name, 'Player') as name, p.avatar_url,
           coalesce((select tier from public.player_ratings where player_id = p.id), 'bronze') as tier, a.pts, a.played
      from agg a join public.profiles p on p.id = a.player_id
  ),
  base as (
    select max(s.taken_on) as d from public.season_rank_snapshots s
     where s.season_id = p_season_id and s.taken_on <= current_date - 7
  ),
  prev as (
    select s.player_id, s.rank from public.season_rank_snapshots s, base
     where s.season_id = p_season_id and s.taken_on = base.d
  )
  select r.rank, r.player_id, r.name, r.avatar_url, r.tier, r.pts, r.played,
         coalesce(pv.rank - r.rank, 0)::int as trend
    from ranked r left join prev pv on pv.player_id = r.player_id
   order by r.rank;
$$;

create or replace function public.admin_season_player(
  p_season_id uuid, p_player_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_name text; v_username text; v_avatar text; v_city text; v_phone text;
  v_rating numeric; v_tier text; v_sigma numeric; v_cm int;
  v_anchor boolean; v_status text; v_joined timestamptz;
  v_email text; v_last_seen timestamptz;
  v_rank int; v_pts int; v_played int; v_trend int;
  v_b_id uuid; v_b_label text; v_b_short text; v_b_icon text; v_b_color text;
  v_b_prize text; v_b_from int; v_b_to int;
  v_wins int; v_losses int; v_voided int;
  v_breakdown jsonb; v_ledger jsonb; v_season_name text;
begin
  if not public._is_admin() then
    return jsonb_build_object('error', 'Not authorised.');
  end if;

  select p.name, p.username, p.avatar_url, p.city, p.phone,
         coalesce((select rating from public.player_ratings where player_id = p.id), (select level from public.player_ratings where player_id = p.id), 0), coalesce((select tier from public.player_ratings where player_id = p.id), 'bronze'),
         coalesce((select sigma from public.player_ratings where player_id = p.id), 0.85), coalesce((select competitive_matches from public.player_ratings where player_id = p.id), 0),
         coalesce((select is_anchor from public.player_ratings where player_id = p.id), false), coalesce(p.status, 'active'), p.created_at
    into v_name, v_username, v_avatar, v_city, v_phone,
         v_rating, v_tier, v_sigma, v_cm, v_anchor, v_status, v_joined
    from public.profiles p where p.id = p_player_id;
  if v_name is null and v_status is null then
    return jsonb_build_object('error', 'Player not found.');
  end if;

  select u.email, u.last_sign_in_at into v_email, v_last_seen
    from auth.users u where u.id = p_player_id;

  select s.name into v_season_name from public.seasons s where s.id = p_season_id;

  -- standing (null when the player has not scored yet)
  select st.rank, st.pts, st.played, st.trend
    into v_rank, v_pts, v_played, v_trend
    from public.season_standings(p_season_id) st
   where st.player_id = p_player_id;

  if v_rank is not null then
    select b.id, b.label, coalesce(b.short, b.label), b.icon, b.color,
           b.prize, b.rank_from, b.rank_to
      into v_b_id, v_b_label, v_b_short, v_b_icon, v_b_color,
           v_b_prize, v_b_from, v_b_to
      from public.season_brackets b
     where b.season_id = p_season_id
       and v_rank between b.rank_from and b.rank_to
     limit 1;
  end if;

  select count(*) filter (where sp.rule_code = 'win'  and not coalesce(sp.voided, false))::int,
         count(*) filter (where sp.rule_code = 'loss' and not coalesce(sp.voided, false))::int,
         count(*) filter (where coalesce(sp.voided, false))::int
    into v_wins, v_losses, v_voided
    from public.season_points sp
   where sp.season_id = p_season_id and sp.player_id = p_player_id;

  -- where the points came from
  select jsonb_agg(jsonb_build_object(
           'code', t.rule_code,
           'label', coalesce(r.label, initcap(replace(t.rule_code, '_', ' '))),
           'icon', coalesce(r.icon, 'star'),
           'n', t.n, 'pts', t.pts) order by t.pts desc)
    into v_breakdown
    from (
      select sp.rule_code, count(*)::int as n, sum(sp.pts)::int as pts
        from public.season_points sp
       where sp.season_id = p_season_id and sp.player_id = p_player_id
         and not coalesce(sp.voided, false)
       group by sp.rule_code
    ) t
    left join public.season_rules r
      on r.season_id = p_season_id and r.code = t.rule_code;

  -- the ledger itself, newest first (voided rows included, flagged)
  select jsonb_agg(q.e order by q.ts desc) into v_ledger
    from (
      select jsonb_build_object(
               'id', sp.id,
               'code', sp.rule_code,
               'label', coalesce(r.label,
                          case sp.rule_code when 'adjustment' then 'Manual adjustment'
                          else initcap(replace(sp.rule_code, '_', ' ')) end),
               'icon', coalesce(r.icon,
                          case sp.rule_code when 'adjustment' then 'bolt' else 'star' end),
               'pts', sp.pts,
               'created_at', sp.created_at,
               'source', case when sp.tournament_id is not null then coalesce(t.name, 'Tournament')
                              when sp.match_id is not null then 'Match'
                              else 'Admin' end,
               'reason', sp.reason,
               'by', ab.name,
               'voided', coalesce(sp.voided, false),
               'void_reason', sp.void_reason
             ) as e,
             sp.created_at as ts
        from public.season_points sp
        left join public.season_rules r
          on r.season_id = sp.season_id and r.code = sp.rule_code
        left join public.tournaments t on t.id = sp.tournament_id
        left join public.profiles ab on ab.id = sp.created_by
       where sp.season_id = p_season_id and sp.player_id = p_player_id
       order by sp.created_at desc
       limit 60
    ) q;

  return jsonb_build_object(
    'season_name', v_season_name,
    'player', jsonb_build_object(
      'id', p_player_id, 'name', coalesce(v_name, 'Player'), 'username', v_username,
      'avatar_url', v_avatar, 'city', v_city, 'phone', v_phone, 'email', v_email,
      'joined', v_joined, 'last_seen', v_last_seen,
      'rating', v_rating, 'tier', v_tier, 'sigma', v_sigma,
      'reliability', round((1 - v_sigma) * 100)::int,
      -- mirrors profiles.is_provisional (V3-F5 confidence gate, 2026-08-13)
      'is_provisional', (v_sigma > 0.58 or v_cm < 20),
      'competitive_matches', v_cm, 'is_anchor', v_anchor, 'status', v_status),
    'season', jsonb_build_object(
      'rank', v_rank, 'pts', coalesce(v_pts, 0), 'played', coalesce(v_played, 0),
      'trend', coalesce(v_trend, 0), 'wins', coalesce(v_wins, 0),
      'losses', coalesce(v_losses, 0), 'voided', coalesce(v_voided, 0),
      'bracket', case when v_b_id is null then null else jsonb_build_object(
        'id', v_b_id, 'label', v_b_label, 'short', v_b_short, 'icon', v_b_icon,
        'color', v_b_color, 'prize', v_b_prize,
        'rank_from', v_b_from, 'rank_to', v_b_to) end),
    'breakdown', coalesce(v_breakdown, '[]'::jsonb),
    'ledger', coalesce(v_ledger, '[]'::jsonb));
end $$;

create or replace function public.admin_season_find_players(
  p_season_id uuid, p_term text default null, p_limit int default 25)
returns table (
  player_id uuid, name text, avatar_url text, tier text,
  pts int, rank int, scoring boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_term text := btrim(coalesce(p_term, ''));
begin
  if not public._is_admin() then return; end if;
  return query
    with st as (
      select s.player_id, s.pts, s.rank from public.season_standings(p_season_id) s
    )
    select p.id,
           coalesce(p.name, 'Player'),
           p.avatar_url,
           coalesce((select tier from public.player_ratings where player_id = p.id), 'bronze'),
           coalesce(st.pts, 0)::int,
           st.rank,
           (st.player_id is not null)
      from public.profiles p
      left join st on st.player_id = p.id
     where (
             v_term = ''
             or p.name ilike '%' || v_term || '%'
             or coalesce(p.username, '') ilike '%' || v_term || '%'
           )
     -- players already on the board first, then everyone else by name
     order by (st.rank is null), st.rank nulls last, p.name nulls last
     limit greatest(1, least(100, coalesce(p_limit, 25)));
end $$;

create or replace function public.ticket_roster(p_ticket uuid)
returns table (
  player_id   uuid,
  name        text,
  username    text,
  avatar_url  text,
  team        text,
  level       numeric,
  is_host     boolean,
  is_me       boolean,
  phone       text,
  share_state text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_open boolean;
  v_uid  uuid := auth.uid();
begin
  if not public._ticket_member(p_ticket) then
    raise exception 'Not a member of this ticket';
  end if;
  v_open := public._ticket_open(p_ticket);

  return query
  select
    p.id,
    p.name,
    p.username,
    p.avatar_url,
    mp.team,
    (select level from public.player_ratings where player_id = p.id),
    (m.created_by = p.id),
    (p.id = v_uid),
    -- A closed ticket hides numbers again, exactly as before; a swap that
    -- happened inside it survives, but this thread stops serving it.
    case when v_open and public._can_see_phone(v_uid, p.id)
         then p.phone else null end,
    case
      when p.id = v_uid then 'me'
      when public._can_see_phone(v_uid, p.id) then 'shared'
      when exists (select 1 from public.number_requests r
                    where r.requester_id = v_uid and r.target_id = p.id
                      and r.status = 'pending') then 'pending'
      else 'none'
    end
  from public.match_tickets t
  join public.matches m        on m.id = t.match_id
  join public.match_players mp on mp.match_id = m.id
  join public.profiles p       on p.id = mp.player_id
  where t.id = p_ticket
  order by mp.team, (m.created_by = p.id) desc, p.name;
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

create or replace function public.mm_candidates(
  p_limit int default 10,
  p_from  timestamptz default null,
  p_to    timestamptz default null
)
returns table (
  match_id        uuid,
  scheduled_at    timestamptz,
  match_type      text,
  court_name      text,
  venue_name      text,
  city            text,
  creator_id      uuid,
  creator_name    text,
  creator_rating  numeric,
  creator_level   numeric,
  players         int,
  center_rating   numeric,
  level_match_pct int
) language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric; v_uid uuid := auth.uid();
begin
  select coalesce((select rating from public.player_ratings where player_id = p.id), (select level from public.player_ratings where player_id = p.id), 2.0), p.city, (coalesce((select placement_played from public.player_ratings where player_id = p.id), 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = v_uid;
  v_window := coalesce((select value::numeric from public.app_settings
                         where key = 'mm_time_window_hours'), 12);

  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         cp.id, cp.name, (select rating from public.player_ratings where player_id = cp.id), (select level from public.player_ratings where player_id = cp.id),
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, (select rating from public.player_ratings where player_id = cp.id), (select level from public.player_ratings where player_id = cp.id), 2.0),
         greatest(0, 100 - round(abs(v_rating - coalesce(m.mm_center_rating, (select rating from public.player_ratings where player_id = cp.id), (select level from public.player_ratings where player_id = cp.id), 2.0)) * 40))::int
    from public.matches m
    join public.profiles cp on cp.id = m.created_by
    left join public.courts c on c.id = m.court_id
   where m.status = 'open'
     and not coalesce(m.is_private, false)   -- private: code only
     and m.created_by <> v_uid
     and m.scheduled_at > now() - public.mm_grace()
     and (
       case when p_from is null and p_to is null
         then m.scheduled_at < now() + (v_window * interval '1 hour')
         else m.scheduled_at >= greatest(now(), coalesce(p_from, now()))
              and m.scheduled_at <= coalesce(p_to, now() + interval '365 days')
       end
     )
     and (select count(*) from public.match_players mp2 where mp2.match_id = m.id) < 4
     and not exists (select 1 from public.match_players mp3
                      where mp3.match_id = m.id and mp3.player_id = v_uid)
     and (
       m.match_type = 'casual'
       or case when v_plac
         then coalesce((select placement_played from public.player_ratings where player_id = cp.id), 0) < 5
         else coalesce((select placement_played from public.player_ratings where player_id = cp.id), 0) >= 5
              and abs(v_rating - coalesce(m.mm_center_rating, (select rating from public.player_ratings where player_id = cp.id), (select level from public.player_ratings where player_id = cp.id), 2.0))
                  <= public.mm_band_halfwidth(extract(epoch from (now() - m.created_at)) / 60.0)
       end
     )
     and (v_city is null or coalesce(c.city, cp.city) is null or coalesce(c.city, cp.city) = v_city)
   order by abs(v_rating - coalesce(m.mm_center_rating, (select rating from public.player_ratings where player_id = cp.id), (select level from public.player_ratings where player_id = cp.id), 2.0)) asc,
            m.scheduled_at asc
   limit p_limit;
end $$;

create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
  v_type text; v_private boolean;
begin
  select coalesce((select rating from public.player_ratings where player_id = p.id), (select level from public.player_ratings where player_id = p.id), 2.0), p.city, (coalesce((select placement_played from public.player_ratings where player_id = p.id), 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = p_player;
  if not found then return false; end if;

  select m.status, m.created_by, coalesce(m.mm_center_rating, 2.0), m.created_at,
         m.scheduled_at, m.court_id, m.match_type, m.is_private
    into v_status, v_cby, v_center, v_created, v_sched, v_court, v_type, v_private
    from public.matches m where m.id = p_match;
  if not found or v_status <> 'open' or v_cby = p_player then return false; end if;
  if coalesce(v_private, false) then return false; end if;  -- code only
  if v_sched <= now() - public.mm_grace() then return false; end if;  -- past grace

  v_window := coalesce((select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);
  if v_sched >= now() + (v_window * interval '1 hour') then return false; end if;

  select count(*) into v_count from public.match_players where match_id = p_match;
  if v_count >= 4 then return false; end if;
  if exists (select 1 from public.match_players where match_id = p_match and player_id = p_player) then
    return false;
  end if;

  select (coalesce(pr.placement_played, 0) < 5), p.city into v_cplac, v_ccity
    from public.profiles p
    join public.player_ratings pr on pr.player_id = p.id
   where p.id = v_cby;
  select city into v_courtcity from public.courts where id = v_court;

  -- Casual is unrated: no band, no placement/placed split (see mm_candidates).
  if v_type is distinct from 'casual' then
    if v_plac or v_cplac then
      if not (v_plac and v_cplac) then return false; end if;
    elsif abs(v_rating - v_center)
          > public.mm_band_halfwidth(extract(epoch from (now() - v_created)) / 60.0) then
      return false;
    end if;
  end if;

  if v_city is not null and coalesce(v_courtcity, v_ccity) is not null
     and coalesce(v_courtcity, v_ccity) <> v_city then
    return false;
  end if;
  return true;
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
    select coalesce(rating, level, 2.0), (coalesce(placement_played, 0) < 5)
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
        select coalesce(rating, level, 2.0) into v_partner_rating
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

create or replace function public._settle_rating(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  -- ==== V3-F5 CONSTANT BLOCK (mirrored in RatingEngineV3F5; drift is a test
  -- failure, not a surprise in production) ================================
  c_prior      constant numeric   := 3.30;   -- hidden starting estimate
  c_sigma0     constant numeric   := 0.95;   -- starting uncertainty
  c_placement  constant int       := 5;      -- public placement matches
  c_stage_end  constant int[]     := array[2, 4, 5];         -- exclusive
  c_stage_k    constant numeric[] := array[1.15, 0.90, 0.70];
  c_stage_lo   constant numeric   := 0.35;   -- sigma scaling floor in placement
  c_k_min      constant numeric   := 0.04;
  c_k_max      constant numeric   := 0.35;
  c_curve      constant numeric   := 1.0;    -- logistic scale
  c_result_w   constant numeric   := 0.85;
  c_pl_relfl   constant numeric   := 1.00;   -- W floor while in placement
  c_relfl      constant numeric   := 0.65;   -- W floor once established
  c_pl_decay   constant numeric   := 0.970;  -- sigma decay, matches 1-5
  c_post_end   constant int[]     := array[10, 20];
  c_post_decay constant numeric[] := array[0.980, 0.975];
  c_decay      constant numeric   := 0.970;  -- established, matches 21+
  c_sig_min    constant numeric   := 0.12;
  c_sig_max    constant numeric   := 1.00;
  c_r_min      constant numeric   := 0.0;
  c_r_max      constant numeric   := 7.0;
  c_anchor     constant numeric   := 0.05;
  c_dp         constant int       := 6;      -- stored precision
  c_version    constant text      := 'v3_f5';
  -- ========================================================================

  v_type text;
  v_winner text; v_score_a text; v_applied boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric; v_s_a numeric; v_s_b numeric;
  v_raw_w_a numeric; v_raw_w_b numeric;
  r record; v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric; v_decay numeric;
  v_placement boolean;
begin
  select coalesce(match_type, 'ranked'), winner_team, score_team_a,
         coalesce(rating_applied, false)
    into v_type, v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;

  if v_type is null then return; end if;          -- no such match
  if v_type <> 'ranked' then return; end if;      -- casual is unrated, always
  if v_applied then return; end if;               -- idempotency: never twice
  if v_winner is null then return; end if;

  select a, b into v_ga, v_gb from public._parse_set_games(v_score_a);
  v_ga := coalesce(v_ga, 0); v_gb := coalesce(v_gb, 0); v_tot := v_ga + v_gb;

  -- Team strength is the plain average of the pair. lambda (team imbalance) is
  -- 0 and stays 0 until it can be fitted on real match history: 5.0 + 2.0 and
  -- 3.5 + 3.5 are the same team to this engine, knowingly.
  select avg(coalesce(pr.rating, c_prior))  filter (where mp.team = 'a'),
         avg(coalesce(pr.rating, c_prior))  filter (where mp.team = 'b'),
         avg(coalesce(pr.sigma,  c_sigma0)) filter (where mp.team = 'a'),
         avg(coalesce(pr.sigma,  c_sigma0)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join player_ratings pr on pr.player_id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, c_prior);  v_avg_b := coalesce(v_avg_b, c_prior);
  v_sig_a := coalesce(v_sig_a, c_sigma0); v_sig_b := coalesce(v_sig_b, c_sigma0);

  -- E_b is the COMPLEMENT of E_a, not a second logistic, so the pair sums to
  -- exactly 1 the way the reference implementation does.
  v_e_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / c_curve));
  v_e_b := 1.0 - v_e_a;

  v_s_a := c_result_w * (case when v_winner = 'a' then 1 else 0 end)
         + (1 - c_result_w) * public._v3f5_margin(v_ga, v_gb);
  v_s_b := c_result_w * (case when v_winner = 'b' then 1 else 0 end)
         + (1 - c_result_w) * public._v3f5_margin(v_gb, v_ga);

  -- W depends on the OPPONENTS' mean sigma, but its floor depends on the
  -- player's OWN match count, so the raw value is computed per team here and
  -- floored per player in the loop.
  v_raw_w_a := 0.5 + 0.5 * (1 - v_sig_b);
  v_raw_w_b := 0.5 + 0.5 * (1 - v_sig_a);

  -- Season ladder is a SEPARATE system and is untouched by V3-F5. It runs here
  -- because it must see the pre-match ratings (that is what its upset bonus is
  -- measured against).
  perform public._award_season_points(p_match_id);

  for r in
    select mp.player_id, mp.team,
           coalesce(r0.rating, c_prior)  as rating,
           coalesce(r0.sigma,  c_sigma0) as sigma,
           coalesce(r0.competitive_matches, 0) as cm,
           coalesce(r0.is_anchor, false) as anchor
      from match_players mp
      join player_ratings r0 on r0.player_id = mp.player_id
     where mp.match_id = p_match_id
  loop
    if r.team = 'a' then v_s := v_s_a; v_e := v_e_a; v_w := v_raw_w_a;
    else                 v_s := v_s_b; v_e := v_e_b; v_w := v_raw_w_b; end if;

    v_placement := (r.cm < c_placement);

    -- W: no opponent is discounted at all during a player's first five
    -- matches. Discounting opponents at launch, when nobody is established,
    -- suppresses exactly the evidence placement needs.
    v_w := greatest(v_w, case when v_placement then c_pl_relfl else c_relfl end);

    -- K: staged in placement (exploration / calibration / validation), scaled
    -- inside the stage by remaining uncertainty so the stage value is a
    -- ceiling. After placement, the plain sigma-driven formula — no
    -- intermediate schedule, and the drop from 0.62 to 0.29 between match 5
    -- and match 6 is characteristic of V3-F5, not a bug to smooth.
    if v_placement then
      if    r.cm < c_stage_end[1] then v_k := c_stage_k[1];
      elsif r.cm < c_stage_end[2] then v_k := c_stage_k[2];
      else                             v_k := c_stage_k[3];
      end if;
      v_k := v_k * greatest(c_stage_lo, least(1.0, r.sigma / c_sigma0));
    else
      v_k := c_k_min + (c_k_max - c_k_min) * r.sigma;
    end if;

    -- A huge favourite winning narrowly gives S < E and therefore a NEGATIVE
    -- delta. That is measured, accepted V3-F5 behaviour; do not add a
    -- `if won then delta := greatest(delta, 0)` here.
    v_delta := v_k * v_w * (v_s - v_e);
    -- Anchors are a SOFT pin: a hand-calibrated player still moves, by at most
    -- 0.05 a match, and their sigma still decays normally.
    if r.anchor then v_delta := greatest(-c_anchor, least(c_anchor, v_delta)); end if;
    v_after := round(greatest(c_r_min, least(c_r_max, r.rating + v_delta)), c_dp);

    -- Sigma: deterministic, keyed on matches already played. Approaches the
    -- established rate from ABOVE and never dips below it, which is what keeps
    -- K alive after the rating goes public. It ignores the RESULT entirely —
    -- the known "confidently wrong" weakness, preserved on purpose.
    if    v_placement            then v_decay := c_pl_decay;
    elsif r.cm < c_post_end[1]   then v_decay := c_post_decay[1];
    elsif r.cm < c_post_end[2]   then v_decay := c_post_decay[2];
    else                              v_decay := c_decay;
    end if;
    v_sig_after := round(greatest(c_sig_min, least(c_sig_max, r.sigma * v_decay)), c_dp);

    -- player_ratings is the engine's table; a trigger mirrors it back onto
    -- profiles for the readers not yet migrated (phase 1 of the split).
    update player_ratings set
      rating = v_after,
      -- level is the 2dp DISPLAY mirror of rating; it is never read back into
      -- the math, so display rounding cannot feed the engine.
      level  = round(v_after, 2),
      tier   = public.tier_from_level(v_after),
      sigma  = v_sig_after,
      competitive_matches = r.cm + 1,
      -- the placement counter, and with it the public reveal, at match 5
      placement_played = least(coalesce(placement_played, 0) + 1, c_placement),
      last_competitive_match_at = now(),
      updated_at = now()
    where player_id = r.player_id;

    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta,
       opp_avg_rating, games_for, games_against, won,
       engine_version, match_no, k_factor, w_opp, expected, signal)
    values (r.player_id, p_match_id, round(r.rating, 2), round(v_after, 2),
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, c_dp),
       round((case when r.team = 'a' then v_avg_b else v_avg_a end)::numeric, 4),
       case when r.team = 'a' then v_ga else v_gb end,
       case when r.team = 'a' then v_gb else v_ga end,
       (r.team = v_winner),
       -- the intermediate terms are recorded so a future engine can be
       -- replayed against real history without re-deriving them
       c_version, r.cm + 1, round(v_k, 6), round(v_w, 6), round(v_e, 6), round(v_s, 6));
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;

create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  update public.player_ratings r
     set sigma = greatest(r.sigma, least(0.60, r.sigma + 0.01)),
         updated_at = now()
  where r.sigma < 0.60
    and (r.last_competitive_match_at is null
         or r.last_competitive_match_at < now() - interval '14 days')
    and not exists (select 1 from public.profiles p
                     where p.id = r.player_id and coalesce(p.is_admin, false));
  get diagnostics v_count = row_count;
  -- returns players whose uncertainty was widened (it used to return players
  -- whose rating was cut, which is now always zero by construction)
  return v_count;
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
    from public.player_ratings where player_id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.player_ratings set
    rating = v_rating, level = round(v_rating, 2),
    tier = public.tier_from_level(v_rating),
    sigma = v_sigma, is_anchor = coalesce(p_is_anchor, false),
    competitive_matches = greatest(coalesce(competitive_matches, 0), 20),
    placement_played = greatest(coalesce(placement_played, 0), 5),
    updated_at = now()
  where player_id = p_player_id;
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

create or replace function public.mark_placement_revealed()
returns void
language sql security definer set search_path = public as $$
  update public.player_ratings
     set placement_revealed = true, updated_at = now()
   where player_id = auth.uid() and coalesce(placement_revealed, false) = false;
$$;

-- ---------------------------------------------------------------------------
-- 4. Every reader and writer now uses player_ratings. Before the old columns
--    go, prove nothing still reaches for them.
--
--    This is the check that makes a one-shot move safe: ~22 functions were
--    rewritten by hand against a database this environment cannot compile
--    against, so the catalog gets the last word.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname not in ('_player_ratings_row')
     and p.prosrc ~ 'profiles'
     and p.prosrc ~ '\m(rating|sigma|is_anchor|competitive_matches|placement_played|placement_revealed|last_competitive_match_at|is_provisional|reliability)\M'
     and p.prosrc !~ 'player_ratings';
  if v_bad is not null then
    raise exception 'function(s) still read a ranking column off profiles: %', v_bad
      using hint = 'Point them at player_ratings before dropping the columns.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Drop the old columns. Views first, if anything grew on them.
-- ---------------------------------------------------------------------------
do $$
declare v_dep text;
begin
  select string_agg(distinct dep.relname, ', ') into v_dep
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    join pg_class dep  on dep.oid = rw.ev_class
    join pg_class src  on src.oid = d.refobjid
    join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
   where src.relname = 'profiles'
     and a.attname in ('rating','sigma','level','tier','is_anchor',
                       'competitive_matches','last_competitive_match_at',
                       'placement_played','placement_revealed',
                       'is_provisional','reliability')
     and dep.relkind = 'v';
  if v_dep is not null then
    raise exception 'view(s) depend on the ranking columns: %', v_dep;
  end if;
end $$;

alter table public.profiles drop column if exists is_provisional;
alter table public.profiles drop column if exists reliability;
alter table public.profiles drop column if exists rating;
alter table public.profiles drop column if exists sigma;
alter table public.profiles drop column if exists level;
alter table public.profiles drop column if exists tier;
alter table public.profiles drop column if exists is_anchor;
alter table public.profiles drop column if exists competitive_matches;
alter table public.profiles drop column if exists last_competitive_match_at;
alter table public.profiles drop column if exists placement_played;
alter table public.profiles drop column if exists placement_revealed;

-- ---------------------------------------------------------------------------
-- 6. Verify before anyone relies on it.
-- ---------------------------------------------------------------------------
do $$
declare v_p bigint; v_r bigint; v_bad bigint;
begin
  select count(*) into v_p from public.profiles;
  select count(*) into v_r from public.player_ratings;
  if v_p <> v_r then
    raise exception 'player_ratings has % row(s) for % profile(s)', v_r, v_p
      using hint = 'the backfill missed someone — investigate before phase 2';
  end if;

  select count(*) into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name in ('rating','sigma','level','tier','is_anchor',
                         'competitive_matches','last_competitive_match_at',
                         'placement_played','placement_revealed',
                         'is_provisional','reliability');
  if v_bad > 0 then
    raise exception '% ranking column(s) still on profiles', v_bad;
  end if;

  -- the boundary this whole table exists to make structural
  if exists (select 1 from information_schema.column_privileges
              where table_schema='public' and table_name='player_ratings'
                and grantee in ('authenticated','anon')
                and privilege_type in ('UPDATE','INSERT','DELETE')) then
    raise exception 'a client can write player_ratings — that is the anti-cheat boundary';
  end if;

  raise notice 'player_ratings: % row(s) backfilled and mirrored.', v_r;
end $$;

notify pgrst, 'reload schema';
