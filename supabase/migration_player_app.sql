-- ============================================================
-- Padel Egypt — player-app wiring migration
-- Safe to run on the existing project (IF NOT EXISTS everywhere).
-- Run in: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================

-- ── matches: columns the player app needs ─────────────────────
alter table public.matches add column if not exists court_id uuid references public.courts(id);
alter table public.matches add column if not exists min_elo int not null default 0;
alter table public.matches add column if not exists is_private boolean not null default false;
alter table public.matches add column if not exists invite_code text;
alter table public.matches add column if not exists result_submitted_by uuid references public.profiles(id);
alter table public.matches add column if not exists result_submitted_at timestamptz;

create unique index if not exists matches_invite_code_key on public.matches (invite_code) where invite_code is not null;

-- ── match_players ──────────────────────────────────────────────
alter table public.match_players add column if not exists created_at timestamptz not null default now();
create unique index if not exists match_players_unique on public.match_players (match_id, player_id);

-- ── tournament entries ─────────────────────────────────────────
create table if not exists public.tournament_entries (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  partner_name text,
  status text not null default 'registered', -- registered | withdrawn
  created_at timestamptz not null default now(),
  unique (tournament_id, player_id)
);

-- ── orders (store checkout) ────────────────────────────────────
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id),
  items jsonb not null,           -- [{product_id, name, brand, qty, unit_price}]
  subtotal int not null,
  shipping int not null default 0,
  discount int not null default 0,
  total int not null,
  promo_code text,
  payment_method text not null default 'cod',  -- cod until Paymob/Fawry are wired
  status text not null default 'pending',      -- pending | confirmed | shipped | delivered | cancelled
  created_at timestamptz not null default now()
);

-- ── ranking history ────────────────────────────────────────────
create table if not exists public.ranking_history (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  match_id uuid references public.matches(id),
  level_before numeric not null default 0,
  level_after numeric not null default 0,
  elo_before int,
  elo_after int,
  created_at timestamptz not null default now()
);

-- ============================================================
-- RPC: join_match — race-safe join (capacity + min ELO checked
-- server-side so two players can't take the last slot at once).
-- ============================================================
create or replace function public.join_match(p_match_id uuid, p_team text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_elo int;
  v_my_elo int;
  v_team text;
  v_team_a int;
  v_team_b int;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, min_elo into v_status, v_min_elo
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  select coalesce(elo, 1000) into v_my_elo from profiles where id = v_uid;
  if v_my_elo < v_min_elo then
    return 'This match requires ' || v_min_elo || '+ ELO.';
  end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null; -- already in: treat as success
  end if;

  select count(*) into v_count from match_players where match_id = p_match_id;
  if v_count >= 4 then return 'This match is already full.'; end if;

  -- auto-balance teams unless caller asked for one
  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;
  v_team := coalesce(p_team, case when v_team_a <= v_team_b then 'a' else 'b' end);
  if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
    v_team := case v_team when 'a' then 'b' else 'a' end;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);

  if v_count + 1 >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;

-- ============================================================
-- RPC: leave_match
-- ============================================================
create or replace function public.leave_match(p_match_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select status into v_status from matches where id = p_match_id for update;
  if v_status in ('completed', 'in_progress') then
    return 'You can''t leave a match that already started.';
  end if;
  delete from match_players where match_id = p_match_id and player_id = v_uid;
  update matches set status = 'open' where id = p_match_id and status = 'full';
  -- if the creator left and nobody is in the match, cancel it
  delete from matches m where m.id = p_match_id
    and not exists (select 1 from match_players mp where mp.match_id = m.id);
  return null;
end $$;

-- ============================================================
-- RPC: submit_match_result — a player in the match records the
-- score. Casual: settles immediately. Competitive: status stays
-- pending until a player on the OTHER team confirms.
-- score format: '6-4,3-6,6-2' from team A's perspective.
-- ============================================================
create or replace function public.submit_match_result(
  p_match_id uuid, p_score_a text, p_score_b text, p_winner text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_type text;
  v_status text;
  v_sched timestamptz;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_winner not in ('a','b') then return 'Invalid winner.'; end if;
  if not exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return 'Only players in this match can submit a score.';
  end if;

  select match_type, status, scheduled_at into v_type, v_status, v_sched
    from matches where id = p_match_id for update;
  if v_status = 'completed' then return 'Result already confirmed.'; end if;
  if v_sched > now() then return 'Score entry opens after the match time.'; end if;

  update matches set
    score_team_a = p_score_a,
    score_team_b = p_score_b,
    winner_team  = p_winner,
    result_submitted_by = v_uid,
    result_submitted_at = now(),
    status = case when v_type = 'ranked' then 'pending_confirm' else 'completed' end
  where id = p_match_id;

  if v_type <> 'ranked' then
    perform public._settle_elo(p_match_id, false);
  end if;
  return null;
end $$;

-- ============================================================
-- RPC: confirm_match_result — opponent confirms (true) or
-- disputes (false). Confirm settles ELO atomically.
-- ============================================================
create or replace function public.confirm_match_result(p_match_id uuid, p_confirm boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_submitter uuid;
  v_status text;
  v_sub_team text;
  v_my_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select status, result_submitted_by into v_status, v_submitter
    from matches where id = p_match_id for update;
  if v_status <> 'pending_confirm' then return 'Nothing awaiting confirmation.'; end if;

  select team into v_sub_team from match_players where match_id = p_match_id and player_id = v_submitter;
  select team into v_my_team  from match_players where match_id = p_match_id and player_id = v_uid;
  if v_my_team is null then return 'Only players in this match can confirm.'; end if;
  if v_my_team = v_sub_team then return 'A player on the other team must confirm.'; end if;

  if p_confirm then
    update matches set status = 'completed' where id = p_match_id;
    perform public._settle_elo(p_match_id, true);
  else
    update matches set status = 'disputed', winner_team = null,
      score_team_a = null, score_team_b = null,
      result_submitted_by = null, result_submitted_at = null
    where id = p_match_id;
  end if;
  return null;
end $$;

-- ============================================================
-- Rating engine — ONE source of truth (ELO), Level 0–7 derived.
--
--   elo 800  → level 0.0      Division D (Bronze)   0.0–1.9
--   elo 1200 → level 2.0      Division C (Silver)   2.0–3.4
--   elo 1500 → level 3.5      Division B (Gold)     3.5–4.9
--   elo 1800 → level 5.0      Division A (Elite)    5.0–7.0
--   elo 2200 → level 7.0 (cap)
--
-- Win/loss only (no margin-of-victory). K-factor schedule:
--   first 5 ranked matches (placement)  K = 64   (find your level fast)
--   matches 6–30                        K = 32
--   31+                                 K = 24   (established, stable)
-- ============================================================

create or replace function public.level_from_elo(p_elo int)
returns numeric
language sql immutable as $$
  select least(7.0, greatest(0.0, round((p_elo - 800) / 200.0, 2)));
$$;

create or replace function public.tier_from_level(p_level numeric)
returns text
language sql immutable as $$
  select case
    when p_level >= 5.0 then 'elite'
    when p_level >= 3.5 then 'gold'
    when p_level >= 2.0 then 'silver'
    else 'bronze' end;
$$;

-- Admin cold-start seeding: set a known player's rating server-side (rule #2),
-- deriving level+tier from the ELO and marking them ranked (placement done).
-- The seed's ranking_history row has match_id NULL so it doesn't count toward
-- games played → first real matches still use K=64 and self-correct a bad seed.
create or replace function public.admin_set_player_rating(
  p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_elo   int;
  v_old_level numeric;
  v_elo       int;
  v_level     numeric;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  v_elo := greatest(800, least(2200, p_elo));
  select coalesce(elo, 1000), coalesce(level, 0)
    into v_old_elo, v_old_level
  from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  v_level := public.level_from_elo(v_elo);
  update public.profiles set
    elo = v_elo,
    level = v_level,
    tier = public.tier_from_level(v_level),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after, elo_before, elo_after)
  values (p_player_id, null, v_old_level, v_level, v_old_elo, v_elo);
  return null;
end $$;
grant execute on function public.admin_set_player_rating(uuid, int) to authenticated;

create or replace function public._settle_elo(p_match_id uuid, p_ranked boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_winner text;
  v_avg_a numeric;
  v_avg_b numeric;
  r record;
  v_expected numeric;
  v_k int;
  v_games int;
  v_delta int;
  v_new int;
  v_new_level numeric;
begin
  select winner_team into v_winner from matches where id = p_match_id;
  if v_winner is null then return; end if;

  select avg(coalesce(p.elo,1000)) filter (where mp.team='a'),
         avg(coalesce(p.elo,1000)) filter (where mp.team='b')
    into v_avg_a, v_avg_b
    from match_players mp join profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 1000);
  v_avg_b := coalesce(v_avg_b, 1000);

  for r in select mp.player_id, mp.team, coalesce(p.elo,1000) as elo,
                  coalesce(p.level,0) as level, coalesce(p.placement_played,0) as placed
             from match_players mp join profiles p on p.id = mp.player_id
            where mp.match_id = p_match_id
  loop
    if p_ranked then
      -- how many ranked matches has this player completed?
      select count(*) into v_games
        from ranking_history
       where profile_id = r.player_id and match_id is not null;

      v_k := case when v_games < 5 then 64
                  when v_games < 30 then 32
                  else 24 end;

      v_expected := 1.0 / (1.0 + power(10.0,
        ((case when r.team='a' then v_avg_b else v_avg_a end)
        - (case when r.team='a' then v_avg_a else v_avg_b end)) / 400.0));
      v_delta := round(v_k * ((case when r.team = v_winner then 1 else 0 end) - v_expected));
      v_new := greatest(800, r.elo + v_delta);
    else
      v_delta := 0;
      v_new := r.elo;
    end if;

    v_new_level := public.level_from_elo(v_new);

    update match_players set elo_before = r.elo, elo_after = v_new
      where match_id = p_match_id and player_id = r.player_id;

    if p_ranked then
      update profiles set
        elo = v_new,
        level = v_new_level,
        placement_played = least(r.placed + 1, 5),
        tier = public.tier_from_level(v_new_level)
      where id = r.player_id;

      insert into ranking_history (profile_id, match_id, level_before, level_after, elo_before, elo_after)
      values (r.player_id, p_match_id, r.level, v_new_level, r.elo, v_new);
    end if;
  end loop;
end $$;

-- ============================================================
-- Gentle inactivity decay — run weekly.
--   • Kicks in only after 60 days without a confirmed ranked match
--   • −8 ELO per weekly run (≈ −0.04 level)
--   • Never drops a player below the FLOOR of their current division,
--     and never below 1000 — inactivity loosens your spot inside the
--     division, it doesn't relegate you.
--   • Placement players (under 5 ranked matches) are never decayed.
-- ============================================================
create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_count int := 0;
  r record;
  v_floor int;
  v_new int;
  v_new_level numeric;
begin
  for r in
    select p.id, coalesce(p.elo,1000) as elo, coalesce(p.level,0) as level
      from profiles p
     where coalesce(p.is_admin,false) = false
       and coalesce(p.placement_played,0) >= 5
       and coalesce(p.elo,1000) > 1000
       and not exists (
         select 1 from ranking_history h
          where h.profile_id = p.id
            and h.match_id is not null
            and h.created_at > now() - interval '60 days')
  loop
    -- elo floor of the player's current division band
    v_floor := case
      when r.level >= 5.0 then 1800
      when r.level >= 3.5 then 1500
      when r.level >= 2.0 then 1200
      else 800 end;
    v_new := greatest(1000, greatest(v_floor, r.elo - 8));
    if v_new < r.elo then
      v_new_level := public.level_from_elo(v_new);
      update profiles set elo = v_new, level = v_new_level,
        tier = public.tier_from_level(v_new_level)
      where id = r.id;
      insert into ranking_history (profile_id, match_id, level_before, level_after, elo_before, elo_after)
      values (r.id, null, r.level, v_new_level, r.elo, v_new);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

-- Schedule the decay weekly (Mondays 03:00 UTC) if pg_cron is available.
-- In Supabase: Dashboard → Database → Extensions → enable "pg_cron" first.
do $$ begin
  perform cron.schedule('padel-rating-decay', '0 3 * * 1',
    'select public.apply_rating_decay()');
exception when others then
  raise notice 'pg_cron not available — enable the extension and re-run, or call apply_rating_decay() manually/via an Edge Function schedule.';
end $$;

-- ============================================================
-- RLS — enable + minimal policies (adjust to taste)
-- ============================================================
alter table public.matches            enable row level security;
alter table public.match_players      enable row level security;
alter table public.tournament_entries enable row level security;
alter table public.orders             enable row level security;
alter table public.ranking_history    enable row level security;

-- Older numbered migrations left a mutually-recursive pair of SELECT policies:
-- "matches: read own or open" subqueries match_players, and "match_players: read"
-- subqueries matches. Evaluating either makes Postgres evaluate the other, which
-- re-enters the first → "infinite recursion detected in policy" (42P17) on any
-- read of matches/match_players. The app's model is that matches and their
-- participants are publicly readable (the "*readable*" policies just below), so
-- drop the recursive pair outright.
drop policy if exists "matches: read own or open" on public.matches;
drop policy if exists "match_players: read"       on public.match_players;

do $$ begin
  create policy "matches readable" on public.matches for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "create own match" on public.matches for insert with check (auth.uid() = created_by);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "players readable" on public.match_players for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "entries readable" on public.tournament_entries for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "register self" on public.tournament_entries for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "withdraw self" on public.tournament_entries for update using (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "own orders read" on public.orders for select using (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "place own order" on public.orders for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "own history read" on public.ranking_history for select using (auth.uid() = profile_id);
exception when duplicate_object then null; end $$;

-- Table-level privileges. RLS decides WHICH rows; these grants decide whether the
-- role may touch the table at all. The pre-existing tournament_entries table never
-- got insert/update granted, so registration failed with "permission denied".
grant select, insert, update on public.tournament_entries to authenticated;
grant select on public.tournament_entries to anon;
grant select on public.tournament_matches  to authenticated, anon;

grant execute on function public.join_match(uuid, text) to authenticated;
grant execute on function public.leave_match(uuid) to authenticated;
grant execute on function public.submit_match_result(uuid, text, text, text) to authenticated;
grant execute on function public.confirm_match_result(uuid, boolean) to authenticated;

-- ── trade-in / repair requests (created if the admin console hasn't yet) ──
create table if not exists public.trade_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id),
  racket_desc text,
  condition text,
  asking_credit int,
  offer_credit int,
  note text,
  status text not null default 'pending', -- pending | offer_made | accepted | rejected
  created_at timestamptz not null default now()
);
alter table public.trade_requests enable row level security;
do $$ begin
  create policy "own trades read" on public.trade_requests for select using (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "create own trade" on public.trade_requests for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
-- NOTE: admin read/update policies + table GRANT live further down, after
-- public._is_admin() is defined (search "Trade-in access").

-- ── broadcasts readable by players (admin console writes them) ──
alter table public.broadcasts enable row level security;
do $$ begin
  create policy "broadcasts readable" on public.broadcasts for select using (true);
exception when duplicate_object then null; end $$;

-- ============================================================
-- Tournament v2: rich fields + pair entries + knockout bracket
-- ============================================================
alter table public.tournaments add column if not exists description text;
alter table public.tournaments add column if not exists end_date date;
alter table public.tournaments add column if not exists prize_pool int;
alter table public.tournaments add column if not exists min_elo int not null default 0;
alter table public.tournaments add column if not exists format text not null default 'double_elim';
alter table public.tournaments alter column status set default 'auto';
alter table public.tournaments add column if not exists best_of int not null default 3;
alter table public.tournaments add column if not exists max_elo int;

-- widen constraints so the app's values are accepted
alter table public.tournaments drop constraint if exists tournaments_format_chk;
alter table public.tournaments add constraint tournaments_format_chk
  check (format in ('knockout','round_robin','group_knockout','double_elim'));

alter table public.tournaments drop constraint if exists tournaments_status_chk;
alter table public.tournaments add constraint tournaments_status_chk
  check (status in ('upcoming','open','in_progress','completed','cancelled','auto','postponed'));

-- tournament_entries.status: the live table's old check constraint predates this
-- migration and rejects 'registered'. Widen it to the app's values (plus common
-- legacy ones so existing rows pass).
alter table public.tournament_entries drop constraint if exists tournament_entries_status_chk;
alter table public.tournament_entries add constraint tournament_entries_status_chk
  check (status in ('registered','withdrawn','confirmed','pending','paid','cancelled'));

-- admin can read all profiles (needed for dashboard player count)
drop policy if exists "profiles: admin read all" on public.profiles;
create policy "profiles: admin read all" on public.profiles
  for select using (public.is_admin());

-- Hygiene: profiles is never deleted/truncated from the client. DELETE isn't
-- reachable anyway (no policy) and TRUNCATE isn't exposed over REST, but revoke
-- them so the role's privileges match what the app actually needs.
revoke delete, truncate on public.profiles from authenticated, anon;

-- Drop the redundant duplicate insert policy (kept "profiles: insert own").
drop policy if exists "profiles_insert_own" on public.profiles;

-- Ensure FK constraints exist with the exact names PostgREST resolves hints by.
-- These may be missing if tables were created without FKs or via the dashboard.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'matches_created_by_fkey') then
    alter table public.matches
      add constraint matches_created_by_fkey
      foreign key (created_by) references public.profiles(id);
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tournament_entries_player_id_fkey') then
    alter table public.tournament_entries
      add constraint tournament_entries_player_id_fkey
      foreign key (player_id) references public.profiles(id) on delete cascade;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tournament_entries_partner_id_fkey') then
    alter table public.tournament_entries
      add constraint tournament_entries_partner_id_fkey
      foreign key (partner_id) references public.profiles(id);
  end if;
end $$;

alter table public.tournament_entries add column if not exists partner_id uuid references public.profiles(id);
-- partner_name: live table predates the create-table block, which is skipped when
-- the table already exists, so this column was never added. Needed for displaying
-- the second player's name on entries and brackets.
alter table public.tournament_entries add column if not exists partner_name text;
-- player_name: denormalised name of the registrant (mirrors partner_name) so an
-- entry row is self-describing in the DB without joining profiles on player_id.
alter table public.tournament_entries add column if not exists player_name text;

-- Entry payment (InstaPay) + refund tracking. Paid tournaments collect a
-- transfer at registration (admin-verified, like the store); a paid pair that
-- withdraws before the start date is refund-eligible.
alter table public.tournament_entries add column if not exists paid_amount int;
alter table public.tournament_entries add column if not exists payment_method text;
alter table public.tournament_entries add column if not exists instapay_sender text;
alter table public.tournament_entries add column if not exists instapay_proof_url text;
alter table public.tournament_entries add column if not exists refund_status text not null default 'none';
alter table public.tournament_entries drop constraint if exists tournament_entries_refund_chk;
alter table public.tournament_entries add constraint tournament_entries_refund_chk
  check (refund_status in ('none', 'due', 'refunded'));
-- Admins manage any entry (verify payment / process refund).
do $$ begin
  create policy "entries: admin write" on public.tournament_entries for update
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;

-- Backfill player_name for existing rows from profiles.
update public.tournament_entries te
   set player_name = p.name
  from public.profiles p
 where p.id = te.player_id and (te.player_name is null or te.player_name = '');

-- Bracket matches. slot is 0-based within the round.
create table if not exists public.tournament_matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  bracket text not null default 'wb',     -- wb (winners) | lb (losers) | gf (grand final)
  round int not null,
  slot int not null,
  entry1 uuid references public.tournament_entries(id),
  entry2 uuid references public.tournament_entries(id),
  winner_entry uuid references public.tournament_entries(id),
  score text,
  created_at timestamptz not null default now(),
  unique (tournament_id, bracket, round, slot)
);
alter table public.tournament_matches enable row level security;
do $$ begin
  create policy "bracket readable" on public.tournament_matches for select using (true);
exception when duplicate_object then null; end $$;

-- ── Admin guard used by the bracket RPCs ──────────────────────
create or replace function public._is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

-- ── Admin dashboard stats ──────────────────────────────────────
-- Aggregate counts + division breakdown for the admin Dashboard. SECURITY DEFINER
-- + _is_admin() gate so the numbers don't depend on per-table SELECT policies
-- resolving for the admin role (the prior RLS-only "admin read all" approach
-- returned 0 on the live DB). count(*) is exact — unlike fetching ids client-side,
-- which silently caps at PostgREST's 1000-row limit. Players excludes admins to
-- match the Players management screen.
create or replace function public.admin_dashboard_counts()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin() then
    return json_build_object('error', 'admins_only');
  end if;
  return json_build_object(
    'players',     (select count(*) from public.profiles where coalesce(is_admin, false) = false),
    'matches',     (select count(*) from public.matches),
    'courts',      (select count(*) from public.courts),
    'tournaments', (select count(*) from public.tournaments),
    'divisions',   (select coalesce(json_object_agg(tier, c), '{}'::json) from (
                      select coalesce(tier, 'bronze') as tier, count(*) as c
                        from public.profiles
                       where coalesce(is_admin, false) = false
                       group by 1) t)
  );
end $$;
grant execute on function public.admin_dashboard_counts() to authenticated;

-- ============================================================
-- STORE: products, costs, gallery images, and the product-images bucket.
-- Ported into this canonical migration (previously only in the numbered
-- migrations 0003/0004) so a clean re-run keeps the store, and shaped as a
-- generic commerce backend a future website store can share. Idempotent: on
-- the live DB the base tables already exist, so create-if-not-exists is a
-- no-op there and the add-column statements apply the web-sharing fields.
-- ============================================================

-- updated_at touch trigger fn (used by products)
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  brand        text,
  category     text not null default 'accessories',
  description  text,
  price        numeric(10,2) not null,
  stock        int not null default 0,
  stock_status text generated always as (
                 case when stock = 0 then 'out'
                      when stock <= 5 then 'low'
                      else 'in' end) stored,
  image_url    text,
  is_visible   boolean not null default true,
  on_sale      boolean not null default false,
  sale_price   numeric(10,2),
  rating       numeric(3,2),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- web-sharing columns (no-ops once present): slug for website URLs, sku, currency
alter table public.products add column if not exists slug text;
alter table public.products add column if not exists sku text;
alter table public.products add column if not exists currency text not null default 'EGP';
create unique index if not exists products_slug_key on public.products (lower(slug)) where slug is not null;
create index if not exists idx_products_category on public.products (category);

alter table public.products drop constraint if exists products_category_chk;
alter table public.products add constraint products_category_chk
  check (category in ('rackets','shoes','apparel','balls','accessories'));
alter table public.products drop constraint if exists products_stock_chk;
alter table public.products add constraint products_stock_chk check (stock >= 0);

alter table public.products enable row level security;
drop policy if exists "products: read visible" on public.products;
create policy "products: read visible" on public.products
  for select using (is_visible = true or public._is_admin());
drop policy if exists "products: admin write" on public.products;
create policy "products: admin write" on public.products
  for all using (public._is_admin()) with check (public._is_admin());

drop trigger if exists trg_products_touch on public.products;
create trigger trg_products_touch before update on public.products
  for each row execute function public.touch_updated_at();

-- admin-only wholesale cost, kept out of the public products row
create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  cost numeric(10,2)
);
alter table public.product_costs enable row level security;
drop policy if exists "product_costs: admin only" on public.product_costs;
create policy "product_costs: admin only" on public.product_costs
  for all using (public._is_admin()) with check (public._is_admin());

-- ── Home "featured" products ───────────────────────────────────
-- The Home store section shows best-sellers; if nothing has sold yet it falls
-- back to admin-picked items, then to newest. Admin curation lives here.
alter table public.products add column if not exists is_featured boolean not null default false;
alter table public.products add column if not exists featured_rank int;

-- Pick products for the Home store strip — purely the admin's choice:
--   1. admin-featured (is_featured) → ordered by featured_rank, then newest
--   2. else newest visible (so the section is never empty)
drop function if exists public.get_home_products(int);
create or replace function public.get_home_products(p_limit int default 6)
returns table (
  id           uuid,
  name         text,
  brand        text,
  category     text,
  description  text,
  image_url    text,
  price        numeric,
  sale_price   numeric,
  on_sale      boolean,
  stock_status text,
  rating       numeric,
  source       text
)
language sql security definer set search_path = public as $$
  with has_featured as (
    select exists(
      select 1 from public.products where is_visible and is_featured
    ) as f
  )
  select p.id, p.name, p.brand, p.category, p.description, p.image_url, p.price,
         p.sale_price, p.on_sale, p.stock_status, p.rating,
         case when p.is_featured then 'featured' else 'new' end as source
  from public.products p
  where p.is_visible
    and ( ((select f from has_featured) and p.is_featured)
          or (not (select f from has_featured)) )
  order by
    case when p.is_featured then coalesce(p.featured_rank, 999999)
         else 999999 end asc,
    p.created_at desc
  limit greatest(p_limit, 1);
$$;

-- multiple images per product (gallery); products.image_url stays as the
-- denormalised primary/thumbnail so the grid loads one small image per product.
create table if not exists public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  url text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_product_images_product on public.product_images (product_id, sort_order);
alter table public.product_images enable row level security;
drop policy if exists "product_images: read" on public.product_images;
create policy "product_images: read" on public.product_images
  for select using (exists (
    select 1 from public.products p
    where p.id = product_id and (p.is_visible or public._is_admin())));
drop policy if exists "product_images: admin write" on public.product_images;
create policy "product_images: admin write" on public.product_images
  for all using (public._is_admin()) with check (public._is_admin());

grant select on public.products, public.product_images to anon, authenticated;
grant select, insert, update, delete on public.products, public.product_images to authenticated;
grant select, insert, update, delete on public.product_costs to authenticated;

-- public Storage bucket for product images — app + website share the URLs.
-- Public read comes from the bucket flag; writes are admin-only via the policy.
insert into storage.buckets (id, name, public)
  values ('product-images', 'product-images', true)
  on conflict (id) do update set public = true;
drop policy if exists "product-images admin write" on storage.objects;
create policy "product-images admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'product-images' and public._is_admin())
  with check (bucket_id = 'product-images' and public._is_admin());

-- ============================================================
-- Promotional banners (Store top) + product sales.
-- A banner owns a set of products on sale; products.banner_id tracks
-- membership, while the existing products.on_sale / sale_price hold the
-- result so the store renders discounts unchanged.
-- ============================================================
create table if not exists public.banners (
  id           uuid primary key default gen_random_uuid(),
  title        text,
  subtitle     text,
  image_url    text,
  bg_color     text,                -- hex fallback bg when no image (e.g. '#21372F')
  discount_pct int,                 -- null = per-item custom prices
  is_active    boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- self-heal: a pre-migration drift `banners` table may predate these columns,
-- so `create table if not exists` above would have been a no-op. Add each.
alter table public.banners add column if not exists title        text;
alter table public.banners add column if not exists subtitle     text;
alter table public.banners add column if not exists image_url    text;
alter table public.banners add column if not exists bg_color     text;
alter table public.banners add column if not exists discount_pct int;
alter table public.banners add column if not exists is_active    boolean not null default true;
alter table public.banners add column if not exists sort_order   int not null default 0;
alter table public.banners add column if not exists created_at   timestamptz not null default now();
alter table public.banners add column if not exists updated_at   timestamptz not null default now();
alter table public.banners enable row level security;
drop policy if exists "banners: read active" on public.banners;
create policy "banners: read active" on public.banners
  for select using (is_active = true or public._is_admin());
drop policy if exists "banners: admin write" on public.banners;
create policy "banners: admin write" on public.banners
  for all using (public._is_admin()) with check (public._is_admin());
drop trigger if exists trg_banners_touch on public.banners;
create trigger trg_banners_touch before update on public.banners
  for each row execute function public.touch_updated_at();
grant select on public.banners to anon, authenticated;
grant select, insert, update, delete on public.banners to authenticated;

-- which banner a product currently belongs to (its active sale)
alter table public.products add column if not exists banner_id uuid references public.banners(id) on delete set null;
create index if not exists idx_products_banner on public.products (banner_id);

-- public bucket for banner artwork (public read; admin-only writes)
insert into storage.buckets (id, name, public)
  values ('banner-images', 'banner-images', true)
  on conflict (id) do update set public = true;
drop policy if exists "banner-images admin write" on storage.objects;
create policy "banner-images admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'banner-images' and public._is_admin())
  with check (bucket_id = 'banner-images' and public._is_admin());

-- Save a banner + its sale items atomically (admin only). p_items is
-- [{product_id, sale_price}]; sale_price null/'' → derive from p_discount_pct
-- (percentage mode). Items' on_sale mirrors p_is_active; any product dropped
-- from the set reverts to full price.
drop function if exists public.admin_save_banner(uuid,text,text,text,boolean,int,int,jsonb);
create or replace function public.admin_save_banner(
  p_id           uuid,
  p_title        text,
  p_subtitle     text,
  p_image_url    text,
  p_bg_color     text,
  p_is_active    boolean,
  p_sort_order   int,
  p_discount_pct int,
  p_items        jsonb default '[]'::jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public._is_admin() then
    raise exception 'admin only';
  end if;

  if p_id is null then
    insert into public.banners
      (title, subtitle, image_url, bg_color, discount_pct, is_active, sort_order)
      values (p_title, p_subtitle, p_image_url, p_bg_color, p_discount_pct,
              coalesce(p_is_active, true), coalesce(p_sort_order, 0))
      returning id into v_id;
  else
    update public.banners set
      title = p_title, subtitle = p_subtitle, image_url = p_image_url,
      bg_color = p_bg_color,
      discount_pct = p_discount_pct, is_active = coalesce(p_is_active, true),
      sort_order = coalesce(p_sort_order, 0)
      where id = p_id
      returning id into v_id;
    if v_id is null then raise exception 'banner not found'; end if;
  end if;

  -- revert products that were in this banner but are no longer listed
  update public.products p
     set banner_id = null, on_sale = false, sale_price = null
   where p.banner_id = v_id
     and p.id not in (
       select (it->>'product_id')::uuid from jsonb_array_elements(p_items) it
     );

  -- apply the sale to the listed products
  update public.products p set
    banner_id  = v_id,
    on_sale    = coalesce(p_is_active, true),
    sale_price = coalesce(
      nullif(i.sale_price, '')::numeric,
      case when p_discount_pct is not null
           then round(p.price * (100 - p_discount_pct) / 100.0, 2)
           else p.sale_price end
    )
  from (
    select (it->>'product_id')::uuid as product_id, it->>'sale_price' as sale_price
    from jsonb_array_elements(p_items) it
  ) i
  where p.id = i.product_id;

  return v_id;
end;
$$;

create or replace function public.admin_delete_banner(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then raise exception 'admin only'; end if;
  update public.products set banner_id = null, on_sale = false, sale_price = null
    where banner_id = p_id;
  delete from public.banners where id = p_id;
end;
$$;

-- ============================================================
-- RPC: generate_draw — (re)builds winners-bracket round 1 from
-- registered entries, seeded by pair average level (1 v lowest,
-- 2 v second-lowest, …). Byes auto-advance the seed.
-- ============================================================
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
  if not public._is_admin() then return 'Admins only.'; end if;

  -- seed: best pairs first (pair level = avg of player + partner if known)
  select array_agg(id order by lvl desc) into v_entries from (
    select te.id,
           ( coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0) ) / 2.0 as lvl
      from tournament_entries te
      join profiles p1 on p1.id = te.player_id
      left join profiles p2 on p2.id = te.partner_id
     where te.tournament_id = p_tournament_id
       and te.status = 'registered'
  ) s;

  v_n := coalesce(array_length(v_entries, 1), 0);
  if v_n < 2 then return 'Need at least 2 registered pairs.'; end if;

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

-- internal: put a winner into the next round's slot (creating it if needed)
create or replace function public._advance_winner(
  p_tid uuid, p_bracket text, p_round int, p_slot int, p_winner uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_next_slot int := p_slot / 2;
  v_first boolean := (p_slot % 2 = 0);
begin
  insert into tournament_matches (tournament_id, bracket, round, slot)
  values (p_tid, p_bracket, p_round + 1, v_next_slot)
  on conflict (tournament_id, bracket, round, slot) do nothing;

  if v_first then
    update tournament_matches set entry1 = p_winner
     where tournament_id = p_tid and bracket = p_bracket
       and round = p_round + 1 and slot = v_next_slot;
  else
    update tournament_matches set entry2 = p_winner
     where tournament_id = p_tid and bracket = p_bracket
       and round = p_round + 1 and slot = v_next_slot;
  end if;
end $$;

-- ============================================================
-- RPC: record_bracket_winner — admin marks a match winner.
--   • Winner advances within its bracket.
--   • Double-elim: a winners-bracket loser drops into the losers
--     bracket (paired in arrival order); a losers-bracket loser
--     is out. Single-elim: losers are simply out.
--   • If the next-round slot has no opponent left to come, the
--     admin keeps advancing until the final.
-- ============================================================
create or replace function public.record_bracket_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_loser uuid;
  v_format text;
  v_lb_round int;
  v_lb_slot int;
  v_open record;
begin
  if not public._is_admin() then return 'Admins only.'; end if;

  select * into m from tournament_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.winner_entry is not null then return 'Winner already recorded.'; end if;
  if p_winner not in (m.entry1, m.entry2) then return 'Winner must be one of the two pairs.'; end if;
  if m.entry1 is null or m.entry2 is null then return 'This match is still waiting for a pair.'; end if;

  v_loser := case when p_winner = m.entry1 then m.entry2 else m.entry1 end;

  update tournament_matches
     set winner_entry = p_winner, score = p_score
   where id = p_match_id;

  select format into v_format from tournaments where id = m.tournament_id;

  -- advance the winner (round caps handled by simply creating next rounds;
  -- the very last match of a bracket just stores its winner)
  perform public._advance_winner(m.tournament_id, m.bracket, m.round, m.slot, p_winner);

  -- double-elim: drop the WB loser into the losers bracket
  if v_format = 'double_elim' and m.bracket = 'wb' then
    -- find an LB match with a free seat, else open a new one
    select * into v_open
      from tournament_matches
     where tournament_id = m.tournament_id and bracket = 'lb'
       and winner_entry is null and (entry1 is null or entry2 is null)
     order by round, slot
     limit 1;
    if found then
      if v_open.entry1 is null then
        update tournament_matches set entry1 = v_loser where id = v_open.id;
      else
        update tournament_matches set entry2 = v_loser where id = v_open.id;
      end if;
    else
      select coalesce(max(round), 0) into v_lb_round
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb';
      select coalesce(max(slot) + 1, 0) into v_lb_slot
        from tournament_matches
       where tournament_id = m.tournament_id and bracket = 'lb'
         and round = greatest(v_lb_round, 1);
      insert into tournament_matches (tournament_id, bracket, round, slot, entry1)
      values (m.tournament_id, 'lb', greatest(v_lb_round, 1), v_lb_slot, v_loser);
    end if;
  end if;

  return null;
end $$;

grant execute on function public.generate_draw(uuid) to authenticated;
grant execute on function public.record_bracket_winner(uuid, uuid, text) to authenticated;

-- ============================================================
-- RPC: register_for_tournament — server-side eligibility so a crafted
-- API call can't bypass the capacity / level / deadline rules. Mirrors
-- join_match. Caller may only register themselves (uses auth.uid()).
-- Returns null on success, or a human-readable error message.
-- ============================================================
-- Drop the old 3-arg overload so only the payment-aware version exists.
drop function if exists public.register_for_tournament(uuid, uuid, text);

create or replace function public.register_for_tournament(
  p_tournament_id      uuid,
  p_partner_id         uuid default null,
  p_partner_name       text default null,
  p_instapay_sender    text default null,
  p_instapay_proof_url text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid      uuid := auth.uid();
  v_status   text;
  v_start    date;
  v_cap      int;
  v_min      int;
  v_max      int;
  v_fee      int;
  v_count    int;
  v_my_elo   int;
  v_my_name  text;
  v_new      text;
begin
  if v_uid is null then
    return 'Not signed in.';
  end if;

  select status, start_date, capacity, min_elo, max_elo, entry_fee
    into v_status, v_start, v_cap, v_min, v_max, v_fee
  from public.tournaments where id = p_tournament_id;

  if not found then
    return 'Tournament not found.';
  end if;
  if v_status = 'cancelled' then
    return 'Registration is closed — this tournament has been cancelled.';
  end if;
  if v_start is not null and v_start <= current_date then
    return 'Registration is closed — this tournament has already started.';
  end if;

  -- capacity (ignore withdrawn; an existing row for this user is a re-register)
  select count(*) into v_count
  from public.tournament_entries
  where tournament_id = p_tournament_id
    and status <> 'withdrawn'
    and player_id <> v_uid;
  if v_cap > 0 and v_count >= v_cap then
    return 'This tournament is full.';
  end if;

  -- eligibility
  if v_min > 0 or (v_max is not null and v_max > 0) then
    select coalesce(elo, 1000) into v_my_elo from public.profiles where id = v_uid;
    if v_min > 0 and v_my_elo < v_min then
      return 'This event has a minimum level you haven''t reached yet.';
    end if;
    if v_max is not null and v_max > 0 and v_my_elo > v_max then
      return 'Your level is above the maximum for this event.';
    end if;
  end if;

  select name into v_my_name from public.profiles where id = v_uid;
  -- Paid event -> 'pending' (holds the spot until an admin verifies the
  -- transfer); free event -> 'registered' straight away.
  v_new := case when coalesce(v_fee, 0) > 0 then 'pending' else 'registered' end;

  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status,
     paid_amount, payment_method, instapay_sender, instapay_proof_url, refund_status)
  values (p_tournament_id, v_uid, v_my_name, p_partner_id, p_partner_name, v_new,
     case when coalesce(v_fee, 0) > 0 then v_fee else null end,
     case when coalesce(v_fee, 0) > 0 then 'instapay' else null end,
     p_instapay_sender, p_instapay_proof_url, 'none')
  on conflict (tournament_id, player_id) do update
    set player_name        = excluded.player_name,
        partner_id         = excluded.partner_id,
        partner_name       = excluded.partner_name,
        status             = excluded.status,
        paid_amount        = excluded.paid_amount,
        payment_method     = excluded.payment_method,
        instapay_sender    = excluded.instapay_sender,
        instapay_proof_url = excluded.instapay_proof_url,
        refund_status      = 'none';
  return null;
exception when others then
  return sqlerrm;
end $$;

grant execute on function
  public.register_for_tournament(uuid, uuid, text, text, text) to authenticated;

-- Withdrawal: enforce the refund rule server-side. Refund is due only if money
-- was put down AND withdrawing strictly before the start date (same-day or
-- later forfeits the fee).
create or replace function public.withdraw_from_tournament(p_tournament_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_start  date;
  v_entry  public.tournament_entries%rowtype;
  v_refund text := 'none';
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select start_date into v_start from public.tournaments where id = p_tournament_id;
  select * into v_entry from public.tournament_entries
    where tournament_id = p_tournament_id and player_id = v_uid;
  if not found then return 'You are not registered for this tournament.'; end if;
  if v_entry.status = 'withdrawn' then return null; end if;

  if coalesce(v_entry.paid_amount, 0) > 0
     and (v_start is null or current_date < v_start) then
    v_refund := 'due';
  end if;

  update public.tournament_entries
    set status = 'withdrawn', refund_status = v_refund
    where id = v_entry.id;
  return null;
exception when others then
  return sqlerrm;
end $$;

grant execute on function public.withdraw_from_tournament(uuid) to authenticated;

-- Notify the registrant when an admin confirms payment or processes a refund.
create or replace function public.notify_tournament_entry_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    select name into v_name from public.tournaments where id = new.tournament_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (new.player_id, 'tournament', 'Tournament payment confirmed',
            'You''re confirmed in ' || coalesce(v_name, 'the tournament') || '.',
            jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
  end if;
  if new.refund_status = 'refunded' and old.refund_status is distinct from 'refunded' then
    select name into v_name from public.tournaments where id = new.tournament_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (new.player_id, 'tournament', 'Refund processed',
            'Your entry fee for ' || coalesce(v_name, 'the tournament') ||
              ' has been refunded.',
            jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
  end if;
  return new;
end $$;

drop trigger if exists trg_notify_tournament_entry_update on public.tournament_entries;
create trigger trg_notify_tournament_entry_update
  after update on public.tournament_entries
  for each row execute function public.notify_tournament_entry_update();

-- ============================================================
-- Profile column cleanup + signup hardening
--   • Drop legacy duplicate columns (dob/hand/court_side/full_name)
--   • Canonical names: date_of_birth, preferred_hand,
--     preferred_court_side, name
--   • Widen constraints to accept all UI values
--   • Trigger is bulletproof — signup never aborts on profile error
-- ============================================================

-- ensure canonical columns exist (no-ops if already there)
alter table public.profiles add column if not exists name text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists city text;
alter table public.profiles add column if not exists date_of_birth date;
alter table public.profiles add column if not exists gender text;
alter table public.profiles add column if not exists preferred_hand text;
alter table public.profiles add column if not exists preferred_court_side text;
alter table public.profiles add column if not exists elo int;
alter table public.profiles add column if not exists level numeric;
alter table public.profiles add column if not exists tier text;
alter table public.profiles add column if not exists division_pts int;
alter table public.profiles add column if not exists placement_played int;
alter table public.profiles add column if not exists username text;

-- migrate data from legacy columns before dropping them.
-- Guarded so the section is safe to re-run after the columns are already gone.
do $$
declare
  has_col boolean;
begin
  select exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='dob') into has_col;
  if has_col then
    update public.profiles set date_of_birth = dob where date_of_birth is null and dob is not null;
  end if;

  select exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='hand') into has_col;
  if has_col then
    update public.profiles set preferred_hand = hand where preferred_hand is null and hand is not null;
  end if;

  select exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='court_side') into has_col;
  if has_col then
    update public.profiles set preferred_court_side = court_side where preferred_court_side is null and court_side is not null;
  end if;

  select exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='full_name') into has_col;
  if has_col then
    update public.profiles set name = full_name where (name is null or name = '') and full_name is not null;
  end if;
end $$;

-- drop legacy duplicate columns (no-op once already dropped)
alter table public.profiles drop column if exists dob;
alter table public.profiles drop column if exists hand;
alter table public.profiles drop column if exists court_side;
alter table public.profiles drop column if exists full_name;

-- widen constraints to match all UI choices
alter table public.profiles drop constraint if exists profiles_gender_chk;
alter table public.profiles add constraint profiles_gender_chk
  check (gender is null or gender in ('male','female','other'));

alter table public.profiles drop constraint if exists profiles_side_chk;
alter table public.profiles add constraint profiles_side_chk
  check (preferred_court_side is null or preferred_court_side in ('left','right','both'));

-- also grant update on these columns that were added by cleanup
grant update (preferred_hand, preferred_court_side, date_of_birth)
  on public.profiles to authenticated;

-- grant update(id) so PostgREST upserts (onboarding save) work
grant update (id) on public.profiles to authenticated;

-- ── Username (searchable handle) ─────────────────────────────────────────────
-- Players are found by @username in the partner pickers (match + tournament),
-- since free-text name is ambiguous and email is intentionally not exposed.
-- Format: 3–20 chars, lowercase letters / digits / underscore. Stored lowercase.
alter table public.profiles drop constraint if exists profiles_username_chk;
alter table public.profiles add constraint profiles_username_chk
  check (username is null or username ~ '^[a-z0-9_]{3,20}$');

-- Generates a unique handle from a seed (usually the display name), falling back
-- to player<id-fragment> when the seed has too few usable characters. Dedupes by
-- appending the smallest integer suffix that is still free. Used by the backfill
-- below and by handle_new_user when signup metadata is missing/invalid/taken.
create or replace function public._unique_username(p_seed text, p_fallback_id uuid)
returns text
language plpgsql
security definer set search_path = public as $$
declare
  base text;
  cand text;
  n int := 0;
begin
  base := regexp_replace(lower(coalesce(p_seed, '')), '[^a-z0-9]+', '', 'g');
  if length(base) < 3 then
    base := 'player' || substr(replace(p_fallback_id::text, '-', ''), 1, 6);
  end if;
  base := substr(base, 1, 16);
  cand := base;
  while exists (select 1 from public.profiles where lower(username) = cand) loop
    n := n + 1;
    cand := substr(base, 1, 16 - length(n::text)) || n::text;
  end loop;
  return cand;
end $$;

-- Backfill existing players so everyone is immediately searchable.
do $$
declare r record;
begin
  for r in select id, name from public.profiles where username is null loop
    update public.profiles
       set username = public._unique_username(r.name, r.id)
     where id = r.id;
  end loop;
end $$;

-- Case-insensitive uniqueness (created after backfill so it can't fail on dupes).
create unique index if not exists profiles_username_key
  on public.profiles (lower(username));

-- Players may set/change their own handle — username is not a rating column, so a
-- plain column grant is safe (the unique index is the real guard).
grant update (username) on public.profiles to authenticated;

-- Availability check for the signup/edit screens. SECURITY DEFINER so it works
-- pre-auth (anon, during signup) without exposing the whole profiles table.
create or replace function public.username_available(p_username text)
returns boolean
language sql
security definer set search_path = public as $$
  select case
    when p_username is null
      or lower(trim(p_username)) !~ '^[a-z0-9_]{3,20}$' then false
    else not exists (
      select 1 from public.profiles where lower(username) = lower(trim(p_username)))
  end;
$$;
grant execute on function public.username_available(text) to anon, authenticated;

-- rebuild trigger with canonical column names only
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
  if v_gender not in ('male','female','other') then v_gender := null; end if;
  v_hand := nullif(new.raw_user_meta_data->>'preferred_hand', '');
  if v_hand not in ('right','left') then v_hand := null; end if;
  v_side := nullif(new.raw_user_meta_data->>'preferred_court_side', '');
  if v_side not in ('left','right','both') then v_side := null; end if;

  begin
    insert into public.profiles
      (id, name, username, avatar_url, phone, bio,
       date_of_birth, gender, preferred_hand, preferred_court_side,
       elo, level, tier, division_pts, placement_played)
    values
      (new.id, v_name, v_username,
       new.raw_user_meta_data->>'avatar_url',
       nullif(new.raw_user_meta_data->>'phone', ''),
       nullif(new.raw_user_meta_data->>'bio', ''),
       v_dob, v_gender,
       coalesce(v_hand, 'right'),
       coalesce(v_side, 'both'),
       1000, 1.0, 'bronze', 0, 0)
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- CHECKOUT v2 — saved delivery addresses, InstaPay manual
-- transfers, and the admin-editable merchant handle. All blocks
-- are idempotent so the file stays safe to re-run.
-- ============================================================

-- Saved delivery addresses — detailed Egyptian format, keyed by user_id.
-- This matches the pre-existing live table; the create is a no-op there and
-- only seeds the same shape on a fresh database.
create table if not exists public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  label text,
  full_name text not null,
  phone text not null,
  governorate text not null,
  city text not null,
  area text,
  street text not null,
  building text,
  apartment text,
  landmark text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Backfill the optional columns onto an older/partial live table so the app's
-- reads/writes resolve. Required columns are assumed present on any real table.
alter table public.addresses add column if not exists label text;
alter table public.addresses add column if not exists area text;
alter table public.addresses add column if not exists building text;
alter table public.addresses add column if not exists apartment text;
alter table public.addresses add column if not exists landmark text;
alter table public.addresses add column if not exists is_default boolean not null default false;
create index if not exists idx_addresses_user on public.addresses (user_id);
alter table public.addresses enable row level security;
do $$ begin
  create policy "addresses: own read" on public.addresses for select using (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "addresses: own write" on public.addresses for all
    using (auth.uid() = user_id) with check (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
grant select, insert, update, delete on public.addresses to authenticated;

-- The live `orders` table predates this migration's create block (so that
-- block was skipped). Backfill every column the checkout writes — nullable /
-- defaulted so existing rows survive — then the delivery + InstaPay fields.
alter table public.orders add column if not exists items jsonb;
alter table public.orders add column if not exists subtotal int;
alter table public.orders add column if not exists shipping int default 0;
alter table public.orders add column if not exists discount int default 0;
alter table public.orders add column if not exists total int;
alter table public.orders add column if not exists promo_code text;
alter table public.orders add column if not exists payment_method text default 'cod';
alter table public.orders add column if not exists status text default 'pending';
-- The live table's old status CHECK predates the checkout flow and rejects the
-- new states the admin writes ('paid', 'refunded'). Drop it and re-add one that
-- covers every status the app uses. (Schema-drift trap: a constraint, not a
-- column, this time — same root cause as the tournament_entries status check.)
alter table public.orders drop constraint if exists orders_status_chk;
do $$ begin
  alter table public.orders add constraint orders_status_chk check (
    status in ('pending','confirmed','paid','shipped','delivered','cancelled','refunded')
  );
exception when duplicate_object then null; end $$;
alter table public.orders add column if not exists address jsonb;
alter table public.orders add column if not exists instapay_sender text;
alter table public.orders add column if not exists instapay_proof_url text;

-- Admins manage every order (verify InstaPay, advance fulfilment). The
-- existing player policies only cover own-row read + insert.
do $$ begin
  create policy "orders: admin read" on public.orders for select using (public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "orders: admin update" on public.orders for update
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;
-- Table-level privilege (separate from RLS): without this the role is rejected
-- before any policy is evaluated → "permission denied for table orders".
grant select, insert, update on public.orders to authenticated;
-- Named FK so PostgREST can resolve the admin join profiles!orders_player_id_fkey.
-- A drifted live table may have an unnamed/missing FK; add the named one.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_player_id_fkey') then
    alter table public.orders
      add constraint orders_player_id_fkey
      foreign key (player_id) references public.profiles(id);
  end if;
end $$;

-- Trade-in access (defined here because it needs public._is_admin() above).
-- Players create + read their own; admins read all and update (offer/accept).
do $$ begin
  create policy "trades: admin read" on public.trade_requests for select using (public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "trades: admin update" on public.trade_requests for update
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;
-- Table-level privilege (separate from RLS): without this the role is rejected
-- before any policy is evaluated → "permission denied for table trade_requests".
grant select, insert, update on public.trade_requests to authenticated;
-- Named FK so PostgREST can resolve profiles!trade_requests_player_id_fkey.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'trade_requests_player_id_fkey') then
    alter table public.trade_requests
      add constraint trade_requests_player_id_fkey
      foreign key (player_id) references public.profiles(id);
  end if;
end $$;

-- Key/value app settings (admin-editable). The InstaPay merchant handle
-- lives here so the receiving account can change without a rebuild.
create table if not exists public.app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
insert into public.app_settings (key, value)
  values ('instapay_handle', 'padelpro@instapay')
  on conflict (key) do nothing;
alter table public.app_settings enable row level security;
do $$ begin
  create policy "app_settings: read" on public.app_settings for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "app_settings: admin write" on public.app_settings for all
    using (public._is_admin()) with check (public._is_admin());
exception when duplicate_object then null; end $$;
grant select on public.app_settings to anon, authenticated;
grant insert, update on public.app_settings to authenticated;

-- Private bucket for InstaPay transfer screenshots. Players upload; only
-- admins read them back (via signed URLs in the admin console).
insert into storage.buckets (id, name, public)
  values ('payment-proofs', 'payment-proofs', false)
  on conflict (id) do update set public = false;
drop policy if exists "payment-proofs upload" on storage.objects;
create policy "payment-proofs upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'payment-proofs');
drop policy if exists "payment-proofs admin read" on storage.objects;
create policy "payment-proofs admin read" on storage.objects
  for select to authenticated
  using (bucket_id = 'payment-proofs' and public._is_admin());

-- ============================================================
-- Notifications: per-user inbox (orders pass)
-- ============================================================
-- One row per user-facing event. For now the only producer is an orders
-- trigger (status changes), but `type` keeps the table open to match /
-- tournament events later. Admin `broadcasts` stay a separate global feed —
-- the notifications screen merges both — so we don't fan a broadcast into a
-- row per user.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'order',   -- order | match | tournament | ...
  title text not null,
  body text,
  data jsonb,                            -- {order_id, status, ...} for tap-through
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_user
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;
-- Recipients read and mark-read their own rows. Inserts come from the trigger
-- below (security definer) — never from the client — so there is no insert
-- policy on purpose.
do $$ begin
  create policy "notifications: own read" on public.notifications
    for select using (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "notifications: own update" on public.notifications
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
grant select, update on public.notifications to authenticated;

-- ── FCM device tokens (Android push) ───────────────────────────
-- The push-notify Edge Function reads these to fan a notifications insert out
-- to each of the user's devices. Drift-safe alters (a reserved device_tokens
-- table may predate these columns).
create table if not exists public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete cascade,
  token      text not null,
  platform   text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.device_tokens add column if not exists user_id    uuid references public.profiles(id) on delete cascade;
alter table public.device_tokens add column if not exists token      text;
alter table public.device_tokens add column if not exists platform   text not null default 'android';
alter table public.device_tokens add column if not exists created_at timestamptz not null default now();
alter table public.device_tokens add column if not exists updated_at timestamptz not null default now();
create unique index if not exists device_tokens_token_key on public.device_tokens (token);
create index if not exists idx_device_tokens_user on public.device_tokens (user_id);
alter table public.device_tokens enable row level security;
drop policy if exists "device_tokens: own" on public.device_tokens;
create policy "device_tokens: own" on public.device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update, delete on public.device_tokens to authenticated;
drop trigger if exists trg_device_tokens_touch on public.device_tokens;
create trigger trg_device_tokens_touch before update on public.device_tokens
  for each row execute function public.touch_updated_at();

-- Order ref shown to the buyer (matches the Dart OrderUi.ref(): PD-<first 6>).
create or replace function public._order_ref(p_id uuid)
returns text language sql immutable as $$
  select 'PD-' || upper(substr(replace(p_id::text, '-', ''), 1, 6));
$$;

-- Fire a notification to the buyer whenever an order's status changes. Runs as
-- definer so the admin who updates the order can insert a row owned by the
-- buyer (RLS would otherwise block a cross-user insert). Skips no-op /
-- back-to-pending transitions that have no customer-facing message.
create or replace function public.notify_order_status()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_title text;
  v_body  text;
  v_ref   text := public._order_ref(new.id);
begin
  case new.status
    when 'paid', 'confirmed' then
      v_title := 'Order confirmed';
      v_body  := v_ref || ' confirmed — we are preparing your order.';
    when 'shipped' then
      v_title := 'Out for delivery';
      v_body  := v_ref || ' is on its way to you.';
    when 'delivered' then
      v_title := 'Delivered';
      v_body  := v_ref || ' was delivered. Enjoy your gear!';
    when 'cancelled' then
      v_title := 'Order cancelled';
      v_body  := v_ref || ' was cancelled. Contact support if this is unexpected.';
    when 'refunded' then
      v_title := 'Refund issued';
      v_body  := v_ref || ' has been refunded.';
    else
      return new; -- no message for this transition
  end case;

  insert into public.notifications (user_id, type, title, body, data)
  values (new.player_id, 'order', v_title, v_body,
          jsonb_build_object('order_id', new.id, 'status', new.status));
  return new;
end $$;

drop trigger if exists trg_notify_order_status on public.orders;
create trigger trg_notify_order_status
  after update on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.notify_order_status();

-- Notify admins (privately) when a new order is placed. Own-row RLS keeps
-- these 'admin_order' rows visible only to admins; buyers are unaffected.
create or replace function public.notify_admins_new_order()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_ref    text := public._order_ref(new.id);
  v_method text := case when new.payment_method = 'instapay'
                        then 'InstaPay' else 'Cash on delivery' end;
begin
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_order',
         'New order to confirm',
         v_ref || ' · ' || v_method || ' · EGP ' || coalesce(new.total, 0)::text,
         jsonb_build_object('order_id', new.id, 'status', new.status, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_order on public.orders;
create trigger trg_notify_admins_new_order
  after insert on public.orders
  for each row
  execute function public.notify_admins_new_order();

-- Notify a player when they're added to a tournament as someone's partner.
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

-- Realtime so the Home bell updates live on insert (RLS still scopes delivery
-- to the row owner).
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- email_exists(): lets the sign-in screen distinguish an unknown email from a
-- wrong password (Supabase returns one generic error for both). NOTE: this is
-- an account-enumeration vector, accepted deliberately for clearer login UX.
create or replace function public.email_exists(p_email text)
returns boolean
language sql
security definer
set search_path = auth, public
stable as $$
  select exists (
    select 1 from auth.users where lower(email) = lower(trim(p_email))
  );
$$;
grant execute on function public.email_exists(text) to anon, authenticated;

-- ============================================================
-- Direct messages (player ↔ player DM) — one thread per unordered pair.
-- ============================================================
create table if not exists public.conversations (
  id         uuid primary key default gen_random_uuid(),
  player_a   uuid not null references public.profiles(id) on delete cascade,
  player_b   uuid not null references public.profiles(id) on delete cascade,
  match_id   uuid references public.matches(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (player_a, player_b)
);
create table if not exists public.direct_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  text            text not null,
  sent_at         timestamptz not null default now()
);
create index if not exists idx_dm_conversation
  on public.direct_messages (conversation_id, sent_at);

alter table public.conversations enable row level security;
do $$ begin
  create policy "conv: participant read" on public.conversations
    for select using (auth.uid() in (player_a, player_b));
exception when duplicate_object then null; end $$;
grant select on public.conversations to authenticated;

alter table public.direct_messages enable row level security;
do $$ begin
  create policy "dm: participant read" on public.direct_messages
    for select using (exists (
      select 1 from public.conversations c
      where c.id = conversation_id and auth.uid() in (c.player_a, c.player_b)));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "dm: participant send" on public.direct_messages
    for insert with check (sender_id = auth.uid() and exists (
      select 1 from public.conversations c
      where c.id = conversation_id and auth.uid() in (c.player_a, c.player_b)));
exception when duplicate_object then null; end $$;
grant select, insert on public.direct_messages to authenticated;

create or replace function public.get_or_create_conversation(
  p_other uuid, p_match_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_a uuid; v_b uuid; v_id uuid;
begin
  if v_uid is null or p_other is null or p_other = v_uid then return null; end if;
  v_a := least(v_uid, p_other);
  v_b := greatest(v_uid, p_other);
  insert into public.conversations (player_a, player_b, match_id)
  values (v_a, v_b, p_match_id)
  on conflict (player_a, player_b) do nothing;
  select id into v_id from public.conversations
    where player_a = v_a and player_b = v_b;
  return v_id;
end $$;
grant execute on function public.get_or_create_conversation(uuid, uuid) to authenticated;

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'direct_messages'
  ) then
    alter publication supabase_realtime add table public.direct_messages;
  end if;
end $$;

-- Notify the recipient of a new DM (type 'message'); bump an existing unread
-- one per conversation rather than flooding the inbox.
create or replace function public.notify_new_dm()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_recipient uuid;
  v_sender    text;
begin
  select case when c.player_a = new.sender_id then c.player_b else c.player_a end
    into v_recipient
  from public.conversations c where c.id = new.conversation_id;
  if v_recipient is null or v_recipient = new.sender_id then return new; end if;
  select name into v_sender from public.profiles where id = new.sender_id;
  if exists (
    select 1 from public.notifications n
    where n.user_id = v_recipient and n.type = 'message' and n.read = false
      and n.data->>'conversation_id' = new.conversation_id::text
  ) then
    update public.notifications
      set title = coalesce(v_sender, 'New message'),
          body = left(new.text, 80),
          created_at = now()
    where user_id = v_recipient and type = 'message' and read = false
      and data->>'conversation_id' = new.conversation_id::text;
  else
    insert into public.notifications (user_id, type, title, body, data)
    values (v_recipient, 'message',
            coalesce(v_sender, 'New message'),
            left(new.text, 80),
            jsonb_build_object('conversation_id', new.conversation_id,
                               'sender_id', new.sender_id));
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_new_dm on public.direct_messages;
create trigger trg_notify_new_dm
  after insert on public.direct_messages
  for each row execute function public.notify_new_dm();

-- ============================================================
-- Match notifications (type 'match'). Insert-only: these never touch ELO,
-- level, or match status — they only drop a row into `notifications`, which the
-- push-notify Edge Function fans out. `data.match_id` lets the app deep-link
-- straight into MatchDetailScreen.
-- ============================================================

-- Tell the host when another player joins their match.
create or replace function public.notify_match_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_host   uuid;
  v_joiner text;
begin
  select created_by into v_host from public.matches where id = new.match_id;
  -- No host, or the host themselves joined (match creation) → nothing to send.
  if v_host is null or v_host = new.player_id then return new; end if;
  select name into v_joiner from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_host, 'match', 'New player joined',
          coalesce(v_joiner, 'A player') || ' joined your match.',
          jsonb_build_object('match_id', new.match_id));
  return new;
end $$;
drop trigger if exists trg_notify_match_join on public.match_players;
create trigger trg_notify_match_join
  after insert on public.match_players
  for each row execute function public.notify_match_join();

-- When a result is submitted on a ranked match, ask the OTHER team to confirm.
-- Fires only on the transition into pending_confirm, so confirm/dispute (which
-- move the status away again) never re-notify.
create or replace function public.notify_match_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sub_team text;
begin
  if new.status = 'pending_confirm'
     and old.status is distinct from 'pending_confirm'
     and new.result_submitted_by is not null then
    select team into v_sub_team
      from public.match_players
      where match_id = new.id and player_id = new.result_submitted_by;
    insert into public.notifications (user_id, type, title, body, data)
    select mp.player_id, 'match', 'Confirm match result',
           'A score was submitted for your match. Tap to confirm or dispute.',
           jsonb_build_object('match_id', new.id)
    from public.match_players mp
    where mp.match_id = new.id
      and mp.player_id <> new.result_submitted_by
      and (v_sub_team is null or mp.team is distinct from v_sub_team);
  end if;
  return new;
end $$;
drop trigger if exists trg_notify_match_confirm on public.matches;
create trigger trg_notify_match_confirm
  after update on public.matches
  for each row execute function public.notify_match_confirm();

-- ============================================================
-- Schema cleanup: drop pre-migration drift (unused + empty). Kept on purpose:
-- device_tokens (push), banners (promotions), audit_log.
-- ============================================================
drop table if exists public.order_items;
drop table if exists public.payments;
alter table public.orders drop column if exists ship_name;
alter table public.orders drop column if exists ship_phone;
alter table public.orders drop column if exists ship_street;
alter table public.orders drop column if exists ship_building;
alter table public.orders drop column if exists ship_apartment;
alter table public.orders drop column if exists ship_area;
alter table public.orders drop column if exists ship_city;
alter table public.orders drop column if exists ship_governorate;
alter table public.orders drop column if exists ship_landmark;
alter table public.orders drop column if exists payment_ref;
alter table public.orders drop column if exists notes;
alter table public.tournament_entries drop column if exists payment_ref;
alter table public.tournaments        drop column if exists court_id;
alter table public.tournaments        drop column if exists created_by;
alter table public.tournaments        drop column if exists image_url;
alter table public.product_costs      drop column if exists supplier;
alter table public.profiles           drop column if exists last_active;

-- Reload PostgREST schema cache so new FK constraints are visible immediately.
notify pgrst, 'reload schema';
