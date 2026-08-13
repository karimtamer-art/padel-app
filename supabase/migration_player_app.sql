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
-- Matchmaking band center: snapshot of the creator's rating at creation, set by
-- trg_mm_center_rating (below). Drives who the match is visible to (mm_candidates).
alter table public.matches add column if not exists mm_center_rating numeric;
-- created_at drives the band's widen-over-time (search age). Guaranteed here in
-- case the drifted live table never had it.
alter table public.matches add column if not exists created_at timestamptz not null default now();

create unique index if not exists matches_invite_code_key on public.matches (invite_code) where invite_code is not null;

-- ── match_players ──────────────────────────────────────────────
alter table public.match_players add column if not exists created_at timestamptz not null default now();
-- Per-player ack of the "match complete" result hero (Phase 3). true once seen.
alter table public.match_players add column if not exists result_ack boolean not null default false;
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
-- NOTE: SUPERSEDED by the partner-invites block at the END of this file, which
-- makes p_partner_id raise an invite instead of inserting the partner, and
-- counts reserved slots in the capacity check. Edit it there, not here.
-- Signature CHANGED (added p_partner_id) → drop the old 2-arg version first so
-- the named-arg call isn't ambiguous.
drop function if exists public.join_match(uuid, text);
create or replace function public.join_match(
  p_match_id uuid, p_team text default null, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_elo int;
  v_my_elo int;
  v_partner_elo int;
  v_team text;
  v_team_a int;
  v_team_b int;
  v_need int;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

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

  -- Bringing a partner: validate them before we touch anything.
  if p_partner_id is not null then
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    select coalesce(elo, 1000) into v_partner_elo from profiles where id = p_partner_id;
    if not found then return 'Partner not found.'; end if;
    if v_partner_elo < v_min_elo then
      return 'Your partner needs ' || v_min_elo || '+ ELO for this match.';
    end if;
  end if;

  v_need := case when p_partner_id is not null then 2 else 1 end;
  select count(*) into v_count from match_players where match_id = p_match_id;
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match is already full.' end;
  end if;

  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;

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
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  if p_partner_id is not null then
    -- notify trigger pings the partner ("you were added"), not the host.
    perform set_config('padel.partner_add', '1', true);
    insert into match_players (match_id, player_id, team) values (p_match_id, p_partner_id, v_team);
  end if;

  if v_count + v_need >= 4 then
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

-- NOTE: submit_match_result / confirm_match_result live in the rating-engine-v2
-- block further down (v2 settles via _settle_rating). The old v1 definitions that
-- used to sit here — plus their _settle_elo helper — were dead (superseded by v2)
-- and removed. Drop the orphaned v1 helper from any DB that still has it:
drop function if exists public._settle_elo(uuid, boolean);

-- ============================================================
-- Rating engine — ELO→Level mapping helpers (kept; used by v2), Level 0–7.
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

-- admin_set_player_rating, the settlement helper, and apply_rating_decay live
-- in the rating-engine-v2 block further down (with their grants). Their old v1
-- (ELO-based) definitions that used to sit here were dead (superseded by v2) and
-- removed. The cron below only stores a command string, so it's fine that
-- apply_rating_decay is defined later.

-- Schedule the weekly inactivity sweep (Mondays 03:00 UTC) if pg_cron is
-- available. In Supabase: Dashboard → Database → Extensions → enable "pg_cron".
--
-- Despite the name, this job NO LONGER DECAYS RATINGS (removed 2026-08-13 with
-- V3-F5, which holds that absence is lost information rather than lost skill).
-- All it does now is widen sigma for idle players, monotonically. The name and
-- the job id are kept because pg_cron stores the command as a string.
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

-- Matchmaking visibility (Phase 1): matches are NOT public. Readable only by the
-- creator or a participant here; admins get a separate OR'd policy after
-- _is_admin() is defined. Discovery of matches you're not in goes through the
-- band-gatekept mm_candidates() RPC. Safe from 42P17 recursion because
-- match_players' SELECT policy is `using(true)` and never references matches.
drop policy if exists "matches readable" on public.matches;
do $$ begin
  create policy "matches: participant read" on public.matches for select
    using (
      created_by = auth.uid()
      or exists (select 1 from public.match_players mp
                  where mp.match_id = matches.id and mp.player_id = auth.uid())
    );
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

grant execute on function public.join_match(uuid, text, uuid) to authenticated;
grant execute on function public.leave_match(uuid) to authenticated;

-- Atomic create: match + players (creator + optional partner) in one txn.
-- SECURITY DEFINER because match_players has no client INSERT policy; a direct
-- client insert was being denied and leaving orphaned, player-less matches.
-- NOTE: SUPERSEDED by the partner-invites block at the END of this file — the
-- partner is now INVITED (match_invites), never inserted. Edit it there.
create or replace function public.create_match(
  p_competitive  boolean,
  p_scheduled_at timestamptz,
  p_court_id     uuid default null,
  p_partner_id   uuid default null,
  p_min_elo      int default 0,
  p_open         boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'Not signed in.'; end if;
  if p_scheduled_at is null then raise exception 'Pick a time for the match.'; end if;

  insert into public.matches
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_elo, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     not coalesce(p_open, true),
     coalesce(p_min_elo, 0),
     'PDL-' || upper(substr(md5(gen_random_uuid()::text), 1, 5)))
  returning id into v_id;

  insert into public.match_players (match_id, player_id, team) values (v_id, v_uid, 'a');
  if p_partner_id is not null and p_partner_id <> v_uid then
    -- Flag this insert as a deliberate partner-add so the notify trigger pings
    -- the PARTNER ("you were added") instead of the host. Transaction-local.
    perform set_config('padel.partner_add', '1', true);
    insert into public.match_players (match_id, player_id, team) values (v_id, p_partner_id, 'a');
  end if;

  return v_id;
end $$;
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- Admin: soft-remove a match (e.g. a faulty/orphaned one) from the console.
-- Marks it 'cancelled' so it disappears from every player-facing query (which
-- only surface active statuses) while KEEPING the match, its players, and its
-- history in the DB — recoverable and still visible to admins. No hard delete.
drop function if exists public.admin_delete_match(uuid);
drop function if exists public.admin_cancel_match(uuid);
create or replace function public.admin_cancel_match(
  p_match_id uuid, p_reason text default null, p_note text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old text;
begin
  if not public._can_edit('matches') then return 'Not authorised.'; end if;
  select status into v_old from public.matches where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  update public.matches set status = 'cancelled' where id = p_match_id;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'remove_match', 'match', p_match_id,
          jsonb_build_object('status', v_old),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason),
          p_note);
  return null;
end $$;
grant execute on function public.admin_cancel_match(uuid, text, text) to authenticated;

-- Rich admin matches console read (court, host, players, score, ELO delta) as JSON.
create or replace function public.admin_matches_console(p_limit int default 200)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then return '[]'::json; end if;
  return (
    select coalesce(json_agg(x order by x.scheduled_at desc nulls last), '[]'::json)
    from (
      select
        m.id, m.status, m.match_type, m.scheduled_at, m.min_elo, m.winner_team,
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
        (select max(rh.delta) from public.ranking_history rh where rh.match_id = m.id) as elo_delta
      from public.matches m
      left join public.courts c on c.id = m.court_id
      order by m.scheduled_at desc nulls last
      limit p_limit
    ) x
  );
end $$;
grant execute on function public.admin_matches_console(int) to authenticated;

-- Players console feed: one real-data array per non-admin player (rating v2 +
-- win/loss + last-active + email + global rank). KPIs/split derived client-side.
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
        coalesce(p.rating, p.level, 0)::numeric               as rating,
        coalesce(p.level, p.rating, 0)::numeric               as level,
        p.sigma::numeric                                      as sigma,
        p.reliability::numeric                                as reliability,
        -- fallback only fires on a DB without the generated column; the
        -- threshold matches it (V3-F5 confidence gate, 2026-08-13)
        coalesce(p.is_provisional,
                 coalesce(p.competitive_matches, 0) < 20)     as is_provisional,
        coalesce(p.competitive_matches, 0)                    as competitive_matches,
        coalesce(p.placement_played, 0)                       as placement_played,
        coalesce(p.is_anchor, false)                          as is_anchor,
        coalesce(p.status, 'active')                          as status,
        coalesce(agg.played, 0)                               as played,
        coalesce(agg.wins, 0)                                 as wins,
        coalesce(agg.played, 0) - coalesce(agg.wins, 0)       as losses,
        rank() over (order by coalesce(p.rating, p.level, 0) desc) as rank
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
grant execute on function public.admin_players_console() to authenticated;

-- Admin resolve a disputed match: set result, settle ELO, notify, audit.
create or replace function public.admin_resolve_match(
  p_match_id uuid, p_winner text,
  p_score_a text default null, p_score_b text default null, p_note text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if not public._can_edit('matches') then return 'Not authorised.'; end if;
  if p_winner not in ('a','b') then return 'Pick the winning team.'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status not in ('disputed','pending_confirm') then
    return 'This match is not awaiting resolution.';
  end if;
  update public.matches set
    winner_team         = p_winner,
    score_team_a        = nullif(btrim(coalesce(p_score_a, '')), ''),
    score_team_b        = nullif(btrim(coalesce(p_score_b, '')), ''),
    result_submitted_by = coalesce(result_submitted_by, v_uid),
    result_submitted_at = now(),
    status              = 'completed'
  where id = p_match_id;
  perform public._settle_rating(p_match_id);
  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Dispute resolved',
         'An admin finalized your match result — your rating has been updated.',
         jsonb_build_object('match_id', p_match_id)
    from public.match_players mp where mp.match_id = p_match_id;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'resolve_match', 'match', p_match_id,
          jsonb_build_object('status', v_status),
          jsonb_build_object('status', 'completed', 'winner', p_winner,
                             'score_a', p_score_a, 'score_b', p_score_b),
          p_note);
  return null;
end $$;
grant execute on function public.admin_resolve_match(uuid, text, text, text, text) to authenticated;

-- Admin match list (creator name + player count), gated + definer so it's
-- immune to the locked-down matches RLS / embed resolution.
create or replace function public.admin_list_matches(p_limit int default 100)
returns table(
  id           uuid,
  status       text,
  match_type   text,
  scheduled_at timestamptz,
  created_by   uuid,
  creator_name text,
  players      int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._has_access('matches') then return; end if;
  return query
    select m.id, m.status, m.match_type, m.scheduled_at, m.created_by,
           (select p.name from public.profiles p where p.id = m.created_by),
           (select count(*)::int from public.match_players mp where mp.match_id = m.id)
      from public.matches m
     order by m.scheduled_at desc nulls last
     limit p_limit;
end $$;
grant execute on function public.admin_list_matches(int) to authenticated;
-- submit_match_result / confirm_match_result grants moved to the v2 block (their
-- definitions live there now, so the grants must follow them).

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
-- Drift guard: the live table (migration 0003) shipped a `notes` column and no
-- `note`, but the app (store trade-in sheet) writes `note`. Without this, every
-- real trade-in submission fails with "column note does not exist". Idempotent.
alter table public.trade_requests add column if not exists note text;
-- Photos of the racket being traded in (storage PATHS in the private
-- `trade-photos` bucket, not URLs — the console signs them to view). Without
-- these the admin was pricing a trade-in from a text description alone.
-- Bucket + policies live further down, after _has_access() is defined.
alter table public.trade_requests
  add column if not exists photos text[] not null default '{}';
-- A racket can be taken in at the counter from someone with no account, so
-- player_id is optional and a typed name stands in — same shape as
-- tournament_entries' partner_id / partner_name. One of the two is required,
-- otherwise the row belongs to nobody. See changes/2026-08-10_admin_add_trade.sql.
alter table public.trade_requests alter column player_id drop not null;
alter table public.trade_requests add column if not exists player_name text;
alter table public.trade_requests drop constraint if exists trade_requests_who_chk;
alter table public.trade_requests
  add constraint trade_requests_who_chk
  check (player_id is not null
         or btrim(coalesce(player_name, '')) <> '');
-- What went out with the player. Records a fact only: no COGS, no stock move —
-- see changes/2026-08-10_trade_given_racket.sql for why that would double-count.
alter table public.trade_requests
  add column if not exists given_product_id uuid
    references public.products(id) on delete set null,
  add column if not exists given_name text;
-- The money in the swap: ticket price, what they actually paid in cash, and
-- what it cost us. Deal profit = paid_amount - given_cost, shown in the console
-- only — _finance_core does NOT read these, or the same racket rung up as an
-- order would be counted twice. See changes/2026-08-10_trade_deal_money.sql.
alter table public.trade_requests
  add column if not exists given_price numeric(10,2),
  add column if not exists paid_amount numeric(10,2),
  add column if not exists given_cost  numeric(10,2);
alter table public.trade_requests drop constraint if exists trade_requests_money_chk;
alter table public.trade_requests
  add constraint trade_requests_money_chk
  check ((given_price is null or given_price >= 0)
     and (paid_amount is null or paid_amount >= 0)
     and (given_cost  is null or given_cost  >= 0));
alter table public.trade_requests enable row level security;
do $$ begin
  create policy "own trades read" on public.trade_requests for select using (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "create own trade" on public.trade_requests for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
-- NOTE: admin read/update policies + table GRANT live further down, after
-- public._is_admin() is defined (search "Trade-in access").

-- Base admin/commerce tables (also defined in migrations/0003; created here so
-- this canonical file is self-contained and re-runs top-to-bottom on a fresh DB
-- before the RLS/triggers/selects below reference them).
create table if not exists public.broadcasts (
  id          uuid    primary key default gen_random_uuid(),
  admin_id    uuid    not null references auth.users(id),
  title       text    not null,
  body        text    not null,
  segment     text    not null default 'all',
  player_ids  uuid[],
  sent_at     timestamptz,
  created_at  timestamptz not null default now()
);
create table if not exists public.repair_requests (
  id            uuid        primary key default gen_random_uuid(),
  player_id     uuid        not null references auth.users(id),
  racket_desc   text        not null,
  issue         text        not null,
  status        text        not null default 'pending',
  quote_amount  numeric(10,2),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

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
alter table public.tournaments add column if not exists start_time text;
alter table public.tournaments add column if not exists format_note text;
-- Organizer/admin marks an event "sponsored" → a ribbon on its card.
alter table public.tournaments add column if not exists sponsored boolean not null default false;
-- Day registration opens. Before it the auto status is 'upcoming' (no register);
-- from that day it flips to 'open'. Null = open immediately.
alter table public.tournaments add column if not exists registration_opens date;
-- Organizer/admin shuts sign-ups early. Independent of capacity and of the
-- automatic 1-hour-before-start cutoff — any of the three closes registration.
alter table public.tournaments
  add column if not exists registration_closed boolean not null default false;
-- Gender category of the event: open (any) | mens (both men) | womens (both
-- women) | mixed (a team can't be two men). Enforced in register_for_tournament.
alter table public.tournaments add column if not exists category text not null default 'open';
do $$ begin
  alter table public.tournaments drop constraint if exists tournaments_category_chk;
  alter table public.tournaments add constraint tournaments_category_chk
    check (category in ('open', 'mens', 'womens', 'mixed'));
exception when others then null; end $$;

-- widen constraints so the app's values are accepted
alter table public.tournaments drop constraint if exists tournaments_format_chk;
alter table public.tournaments add constraint tournaments_format_chk
  check (format in ('knockout','round_robin','group_knockout','double_elim','custom'));

alter table public.tournaments drop constraint if exists tournaments_status_chk;
alter table public.tournaments add constraint tournaments_status_chk
  check (status in ('upcoming','open','in_progress','completed','cancelled','auto','postponed'));

-- tournament_entries.status: the live table's old check constraint predates this
-- migration and rejects 'registered'. Widen it to the app's values (plus common
-- legacy ones so existing rows pass).
alter table public.tournament_entries drop constraint if exists tournament_entries_status_chk;
alter table public.tournament_entries add constraint tournament_entries_status_chk
  check (status in ('registered','withdrawn','confirmed','pending','paid','cancelled'));

-- matches.status: the live constraint (migration 0003) predates the status
-- machine and has no 'pending_confirm', so submit_match_result's ranked path
-- (`status = case when ranked then 'pending_confirm' ...`) failed with
-- matches_status_chk on EVERY ranked score submission. Widen it to exactly the
-- set the app writes: open → full → pending_confirm → completed | disputed,
-- plus in_progress (legacy) and cancelled (host cancel / stale sweep).
alter table public.matches drop constraint if exists matches_status_chk;
alter table public.matches add constraint matches_status_chk
  check (status in ('open','full','in_progress','pending_confirm',
                    'completed','cancelled','disputed'));

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

-- match_players.player_id → profiles, so PostgREST can embed the player's
-- profile (name/level/…) on match reads (MatchService.matchCols). Missing on
-- drifted live tables where player_id only referenced auth.users. Guarded on
-- the *target table* (not a constraint name) so we never add a second,
-- ambiguous profiles relationship.
do $$ begin
  if not exists (
    select 1 from pg_constraint c
    join pg_class rel  on rel.oid  = c.conrelid
    join pg_class frel on frel.oid = c.confrelid
    where c.contype = 'f'
      and rel.relnamespace = 'public'::regnamespace
      and rel.relname  = 'match_players'
      and frel.relname = 'profiles'
  ) then
    -- Distinct name: a drifted table already has match_players_player_id_fkey
    -- pointing at auth.users. Both may coexist — PostgREST only exposes the
    -- public.profiles one, so the embed stays unambiguous.
    alter table public.match_players
      add constraint match_players_player_id_profiles_fkey
      foreign key (player_id) references public.profiles(id) on delete cascade;
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

-- RBAC columns. Their canonical home (with the CHECK, index and backfill) is
-- the block further down, but the guards below are `language sql` and so are
-- parsed at CREATE time — they need these columns to already exist on a fresh
-- database. `if not exists` makes the duplicate declaration a no-op.
alter table public.profiles add column if not exists admin_role   text;
alter table public.profiles add column if not exists admin_access jsonb;
alter table public.profiles add column if not exists admin_scope  text;
alter table public.profiles add column if not exists is_owner     boolean not null default false;

-- Staff gate (RBAC, 2026-07-18). Only super_admin has is_admin=true; organizer/
-- support/analyst are is_admin=false but DO hold a console role. The shared
-- read consoles (players/matches/dashboard) must let any staffer see data —
-- gating them on _is_admin() left support's and analyst's tabs permanently
-- empty. Nav access is enforced client-side (roles_model); these read RPCs just
-- stop blocking staff. Write/moderation actions use _can_moderate() below.
create or replace function public._is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_admin or admin_role is not null from profiles where id = auth.uid()),
    false);
$$;
grant execute on function public._is_staff() to authenticated;

-- Player/match moderation gate: super admins + the Support · Moderator role
-- ("keeps play fair — players, disputes and service requests"). Organizers and
-- the read-only Analyst are excluded.
create or replace function public._can_moderate()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_admin or admin_role = 'support' from profiles where id = auth.uid()),
    false);
$$;
grant execute on function public._can_moderate() to authenticated;

-- ── Section access (RBAC phase 2, 2026-08-03) ──────────────────
-- `admin_grant_role` stores the ticked section ids in profiles.admin_access,
-- but until now nothing in the DB read them: every guard was role-shaped, so a
-- section granted OUTSIDE the role's default set showed in the nav and then
-- answered "Not authorised." on every call. These three functions are the one
-- resolver all section-scoped guards go through.
-- `_is_admin()` stays "super admin" on purpose — it is the blanket god-check
-- behind unrelated RLS; only the section guards moved.
-- The defaults below MUST stay in lockstep with kRoles in
-- lib/admin/data/roles_model.dart.
create or replace function public._role_default(p_role text)
returns text[] language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin' then array['dashboard','reports','players','matches',
                                  'tournaments','formats','courts','store',
                                  'promotions','sponsors','payments','requests',
                                  'broadcasts','team']
    when 'organizer'   then array['tournaments','formats','courts','broadcasts']
    when 'support'     then array['players','matches','requests']
    when 'analyst'     then array['dashboard','reports']
    else '{}'::text[] end;
$$;
grant execute on function public._role_default(text) to authenticated;

-- The caller's effective sections: super admin → everything (this also covers a
-- legacy admin whose admin_role backfill never ran); otherwise admin_access,
-- falling back to the role's default set when it is null/empty.
create or replace function public._access_ids()
returns text[] language plpgsql stable security definer set search_path = public as $$
declare
  v_is_admin boolean; v_role text; v_access jsonb;
begin
  select coalesce(is_admin, false), admin_role, admin_access
    into v_is_admin, v_role, v_access
    from public.profiles where id = auth.uid();
  if not found then return '{}'::text[]; end if;
  if v_is_admin then return public._role_default('super_admin'); end if;
  if v_role is null then return '{}'::text[]; end if;
  if jsonb_typeof(v_access) = 'array' and jsonb_array_length(v_access) > 0 then
    return (select array(select jsonb_array_elements_text(v_access)));
  end if;
  return public._role_default(v_role);
end $$;
grant execute on function public._access_ids() to authenticated;

-- Can the caller OPEN this console section?
create or replace function public._has_access(p_section text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_section = any (public._access_ids());
$$;
grant execute on function public._has_access(text) to authenticated;

-- Can the caller CHANGE things in it? Analysts are read-only by definition.
create or replace function public._can_edit(p_section text)
returns boolean language sql stable security definer set search_path = public as $$
  select public._has_access(p_section)
     and coalesce((select is_admin or admin_role is distinct from 'analyst'
                     from public.profiles where id = auth.uid()), false);
$$;
grant execute on function public._can_edit(text) to authenticated;

-- Admin read on matches (OR'd with the participant policy above). Defined here
-- because it needs the guards above; the participant policy earlier
-- deliberately avoids referencing them so it can be created first.
drop policy if exists "matches: admin read" on public.matches;
create policy "matches: admin read" on public.matches for select
  using (public._has_access('matches'));

-- The Broadcasts console inserts straight into `broadcasts` (the fan-out
-- trigger does the rest). Players only ever read it — see the policy above.
drop policy if exists "broadcasts: staff write" on public.broadcasts;
create policy "broadcasts: staff write" on public.broadcasts
  for insert to authenticated with check (public._can_edit('broadcasts'));
grant select, insert on public.broadcasts to authenticated;

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
  if not public._is_staff() then
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
  -- Rackets and the like are sourced per order, not held: a made-to-order item
  -- is always sellable and its stock is never touched. See the alters below,
  -- which also apply to the drifted live table.
  made_to_order boolean not null default false,
  stock_status text generated always as (
                 case when made_to_order then 'in'
                      when stock = 0 then 'out'
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
-- Drift-safe: the create-table above is skipped on the live DB, so apply the
-- made-to-order column + the stock_status rule that depends on it here too.
-- stock_status is generated (derived), so dropping and re-adding loses nothing;
-- get_home_products has a string body and holds no dependency on it.
alter table public.products
  add column if not exists made_to_order boolean not null default false;
alter table public.products drop column if exists stock_status;
alter table public.products add column stock_status text
  generated always as (
    case when made_to_order then 'in'
         when stock = 0     then 'out'
         when stock <= 5    then 'low'
         else 'in' end
  ) stored;

create index if not exists idx_products_category on public.products (category);

alter table public.products drop constraint if exists products_category_chk;
alter table public.products add constraint products_category_chk
  check (category in ('rackets','shoes','apparel','balls','accessories'));
alter table public.products drop constraint if exists products_stock_chk;
alter table public.products add constraint products_stock_chk check (stock >= 0);

alter table public.products enable row level security;
drop policy if exists "products: read visible" on public.products;
create policy "products: read visible" on public.products
  for select using (is_visible = true or public._has_access('store'));
drop policy if exists "products: admin write" on public.products;
create policy "products: admin write" on public.products
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

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
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

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
    where p.id = product_id and (p.is_visible or public._has_access('store'))));
drop policy if exists "product_images: admin write" on public.product_images;
create policy "product_images: admin write" on public.product_images
  for all using (public._can_edit('store')) with check (public._can_edit('store'));

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
  using (bucket_id = 'product-images' and public._can_edit('store'))
  with check (bucket_id = 'product-images' and public._can_edit('store'));

-- public Storage bucket for profile avatars — public read (bucket flag); each
-- user writes only inside their own `<uid>/…` folder (set at sign-up).
insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do update set public = true;
drop policy if exists "avatars owner write" on storage.objects;
create policy "avatars owner write" on storage.objects
  for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

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
  for select using (is_active = true or public._has_access('promotions'));
drop policy if exists "banners: admin write" on public.banners;
create policy "banners: admin write" on public.banners
  for all using (public._can_edit('promotions')) with check (public._can_edit('promotions'));
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
  using (bucket_id = 'banner-images' and public._can_edit('promotions'))
  with check (bucket_id = 'banner-images' and public._can_edit('promotions'));

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
  if not public._can_edit('promotions') then
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
  if not public._can_edit('promotions') then raise exception 'admin only'; end if;
  update public.products set banner_id = null, on_sale = false, sale_price = null
    where banner_id = p_id;
  delete from public.banners where id = p_id;
end;
$$;

-- ============================================================
-- Sponsors / partners — the brands and clubs backing the
-- platform, shown to players on the "Our Partners" page and
-- managed from the console's Sponsors section.
--
-- Flat table, no logic, no money: sponsorship money that changes
-- hands is recorded in the `income` ledger (category
-- 'sponsorship'). Keeping the two apart is deliberate — the
-- shop window is not a receipt.
-- ============================================================
create table if not exists public.sponsors (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  tagline     text,                 -- one line under the name, on the card
  blurb       text,                 -- longer copy, shown in the detail sheet
  logo_url    text,
  website_url text,
  tier        text not null default 'partner',
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- self-heal, same reason as banners above: a drift `sponsors` table would make
-- the create a no-op and none of these columns would exist.
alter table public.sponsors add column if not exists name        text;
alter table public.sponsors add column if not exists tagline     text;
alter table public.sponsors add column if not exists blurb       text;
alter table public.sponsors add column if not exists logo_url    text;
alter table public.sponsors add column if not exists website_url text;
alter table public.sponsors add column if not exists tier        text not null default 'partner';
alter table public.sponsors add column if not exists is_active   boolean not null default true;
alter table public.sponsors add column if not exists sort_order  int not null default 0;
alter table public.sponsors add column if not exists created_at  timestamptz not null default now();
alter table public.sponsors add column if not exists updated_at  timestamptz not null default now();

-- Mirrors SponsorTier in lib/backend/services/sponsor_service.dart — change both.
alter table public.sponsors drop constraint if exists sponsors_tier_chk;
alter table public.sponsors add constraint sponsors_tier_chk check (
  tier in ('title', 'gold', 'silver', 'partner'));

create index if not exists sponsors_active_idx on public.sponsors (is_active, sort_order);

alter table public.sponsors enable row level security;
drop policy if exists "sponsors: read active" on public.sponsors;
create policy "sponsors: read active" on public.sponsors for select
  using (is_active = true or public._has_access('sponsors'));
drop policy if exists "sponsors: admin write" on public.sponsors;
create policy "sponsors: admin write" on public.sponsors for all
  using (public._can_edit('sponsors')) with check (public._can_edit('sponsors'));
drop trigger if exists trg_sponsors_touch on public.sponsors;
create trigger trg_sponsors_touch before update on public.sponsors
  for each row execute function public.touch_updated_at();
grant select on public.sponsors to anon, authenticated;
grant select, insert, update, delete on public.sponsors to authenticated;

-- public bucket for sponsor logos (public read; console writes)
insert into storage.buckets (id, name, public)
  values ('sponsor-logos', 'sponsor-logos', true)
  on conflict (id) do update set public = true;
drop policy if exists "sponsor-logos admin write" on storage.objects;
create policy "sponsor-logos admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'sponsor-logos' and public._can_edit('sponsors'))
  with check (bucket_id = 'sponsor-logos' and public._can_edit('sponsors'));

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
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;

  -- seed: best pairs first (pair level = avg of player + partner if known).
  -- Eligible = confirmed roster: free events land on 'registered', paid events
  -- on 'paid' once verified (never 'registered'), so both must count or paid
  -- tournaments draw from 0 pairs. LEFT JOIN profiles so guest entries
  -- (player_id NULL) are kept — they seed at level 0, drawn but unrated.
  select array_agg(id order by lvl desc) into v_entries from (
    select te.id,
           ( coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0) ) / 2.0 as lvl
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
  select * into m from tournament_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
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

-- ── Custom draw building (manual matches for 'custom' format) ───────────────
create or replace function public.add_custom_match(
  p_tournament_id uuid, p_label text, p_entry1 uuid, p_entry2 uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_label text; v_slot int;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  v_label := coalesce(nullif(btrim(p_label), ''), 'Round 1');
  if p_entry1 is null and p_entry2 is null then return 'Pick at least one pair.'; end if;
  if p_entry1 is not null and p_entry1 = p_entry2 then return 'Pick two different pairs.'; end if;
  if p_entry1 is not null and not exists (
       select 1 from tournament_entries where id = p_entry1 and tournament_id = p_tournament_id)
     then return 'Pair not in this tournament.'; end if;
  if p_entry2 is not null and not exists (
       select 1 from tournament_entries where id = p_entry2 and tournament_id = p_tournament_id)
     then return 'Pair not in this tournament.'; end if;
  select coalesce(max(slot) + 1, 0) into v_slot
    from tournament_matches
   where tournament_id = p_tournament_id and bracket = v_label and round = 1;
  insert into tournament_matches (tournament_id, bracket, round, slot, entry1, entry2)
  values (p_tournament_id, v_label, 1, v_slot, p_entry1, p_entry2);
  return null;
end $$;
grant execute on function public.add_custom_match(uuid, text, uuid, uuid) to authenticated;

create or replace function public.set_match_winner(
  p_match_id uuid, p_winner uuid, p_score text default null)
returns text language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from tournament_matches where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  if p_winner is not null and p_winner not in (m.entry1, m.entry2) then
    return 'Winner must be one of the two pairs.';
  end if;
  -- Organizer override — resolves any pending/disputed player submission.
  update tournament_matches set
    winner_entry = p_winner, score = p_score,
    result_status = case when p_winner is null then 'open' else 'confirmed' end,
    submitted_winner = null, submitted_score = null, submitted_by = null
   where id = p_match_id;
  return null;
end $$;
grant execute on function public.set_match_winner(uuid, uuid, text) to authenticated;

-- ============================================================================
-- Player-driven tournament results (2026-07-18). A player in the match submits
-- a winner (+ optional score); the OTHER team confirms or disputes; a dispute
-- clears the submission and pings both teams to re-submit. The organizer never
-- has to referee (but set_match_winner is the override). winner_entry is set
-- only on CONFIRM, so advance_stage still keys off confirmed results. Matches
-- against an all-guest pair auto-confirm (no one to confirm).
-- ============================================================================
alter table public.tournament_matches
  add column if not exists submitted_winner uuid references public.tournament_entries(id) on delete set null;
alter table public.tournament_matches add column if not exists submitted_score text;
alter table public.tournament_matches
  add column if not exists submitted_by uuid references public.profiles(id) on delete set null;
alter table public.tournament_matches
  add column if not exists result_status text not null default 'open'; -- open|pending|confirmed|disputed

create or replace function public.submit_tournament_result(
  p_match_id uuid, p_winner_entry uuid, p_score text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m record; v_my_team text; v_opp_has_app boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select tm.*, e1.player_id a1, e1.partner_id a2, e2.player_id b1, e2.partner_id b2
    into m
    from public.tournament_matches tm
    join public.tournament_entries e1 on e1.id = tm.entry1
    join public.tournament_entries e2 on e2.id = tm.entry2
   where tm.id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  -- Legacy single/double-elim draws (wb/lb/gf) are advanced by the organizer via
  -- record_bracket_winner; a player result would set winner_entry and stall it.
  if m.bracket in ('wb', 'lb', 'gf') then
    return 'The organizer records results for this draw.';
  end if;
  if m.entry1 is null or m.entry2 is null then return 'This match isn''t ready.'; end if;
  if m.result_status = 'confirmed' or m.winner_entry is not null then
    return 'A result is already recorded.';
  end if;
  if p_winner_entry not in (m.entry1, m.entry2) then
    return 'Winner must be one of the two pairs.';
  end if;
  if v_uid in (m.a1, m.a2) then v_my_team := 'a';
  elsif v_uid in (m.b1, m.b2) then v_my_team := 'b';
  else return 'Only players in this match can submit a result.'; end if;

  update public.tournament_matches set
    submitted_winner = p_winner_entry, submitted_score = nullif(btrim(p_score), ''),
    submitted_by = v_uid, result_status = 'pending'
   where id = p_match_id;

  v_opp_has_app := case when v_my_team = 'a' then (m.b1 is not null or m.b2 is not null)
                                             else (m.a1 is not null or m.a2 is not null) end;
  if not v_opp_has_app then
    -- opponent is all guests → nothing to confirm, record it
    update public.tournament_matches set
      winner_entry = p_winner_entry, score = nullif(btrim(p_score), ''),
      result_status = 'confirmed'
     where id = p_match_id;
    return null;
  end if;

  insert into public.notifications (user_id, type, title, body, data)
  select pid, 'tournament', 'Confirm match result',
         'A score was submitted for your tournament match — tap to confirm or dispute.',
         jsonb_build_object('tournament_id', m.tournament_id, 'match_id', p_match_id)
  from (select unnest(case when v_my_team = 'a' then array[m.b1, m.b2]
                                                else array[m.a1, m.a2] end) as pid) x
  where pid is not null;
  return null;
end $$;
grant execute on function public.submit_tournament_result(uuid, uuid, text) to authenticated;

create or replace function public.confirm_tournament_result(p_match_id uuid, p_confirm boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m record; v_sub_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select tm.*, e1.player_id a1, e1.partner_id a2, e2.player_id b1, e2.partner_id b2
    into m
    from public.tournament_matches tm
    join public.tournament_entries e1 on e1.id = tm.entry1
    join public.tournament_entries e2 on e2.id = tm.entry2
   where tm.id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.result_status <> 'pending' then return 'There''s nothing to confirm.'; end if;

  if m.submitted_by in (m.a1, m.a2) then v_sub_team := 'a';
  elsif m.submitted_by in (m.b1, m.b2) then v_sub_team := 'b';
  else v_sub_team := null; end if;

  if v_sub_team = 'a' then
    if v_uid not in (m.b1, m.b2) then return 'Only the other team can confirm this.'; end if;
  elsif v_sub_team = 'b' then
    if v_uid not in (m.a1, m.a2) then return 'Only the other team can confirm this.'; end if;
  else
    return 'Couldn''t resolve the teams.';
  end if;

  if p_confirm then
    update public.tournament_matches set
      winner_entry = submitted_winner, score = submitted_score, result_status = 'confirmed'
     where id = p_match_id;
  else
    update public.tournament_matches set
      result_status = 'disputed',
      submitted_winner = null, submitted_score = null, submitted_by = null
     where id = p_match_id;
    insert into public.notifications (user_id, type, title, body, data)
    select pid, 'tournament', 'Result disputed',
           'A tournament match result was rejected — agree on the score and re-submit.',
           jsonb_build_object('tournament_id', m.tournament_id, 'match_id', p_match_id)
    from (select unnest(array[m.a1, m.a2, m.b1, m.b2]) as pid) x
    where pid is not null and pid <> v_uid;
  end if;
  return null;
end $$;
grant execute on function public.confirm_tournament_result(uuid, boolean) to authenticated;

create or replace function public.delete_tournament_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from tournament_matches where id = p_match_id;
  if not found then return null; end if;
  if not public.owns_tournament(m.tournament_id) then return 'Not authorised.'; end if;
  delete from tournament_matches where id = p_match_id;
  return null;
end $$;
grant execute on function public.delete_tournament_match(uuid) to authenticated;

-- ============================================================
-- RPC: register_for_tournament — server-side eligibility so a crafted
-- API call can't bypass the capacity / level / deadline rules. Mirrors
-- join_match. Caller may only register themselves (uses auth.uid()).
-- Returns null on success, or a human-readable error message.
-- ============================================================
-- Drop the old 3-arg overload so only the payment-aware version exists.
-- Per-player (split) entry payment: fee is PER PLAYER; a pair pays 2×. The
-- registrant pays 'both' (2×) or 'split' (own share). Per-share tracking on the
-- pair row. Full notes: supabase/changes/2026-07-29_split_entry_payment.sql
alter table public.tournament_entries add column if not exists fee_mode text;               -- 'both' | 'split'
alter table public.tournament_entries add column if not exists payer_paid   boolean not null default false;
alter table public.tournament_entries add column if not exists partner_paid boolean not null default false;
alter table public.tournament_entries add column if not exists partner_instapay_sender    text;
alter table public.tournament_entries add column if not exists partner_instapay_proof_url text;

drop function if exists public.register_for_tournament(uuid, uuid, text);
-- tournaments.start_time is free text from the admin picker ('6:00 PM'). Parse
-- it defensively — a junk/legacy value must not blow up registration.
create or replace function public._tournament_clock(p_text text)
returns time
language plpgsql immutable as $$
begin
  if p_text is null or btrim(p_text) = '' then return null; end if;
  return btrim(p_text)::time;
exception when others then
  return null;
end $$;

-- When sign-ups stop: 1 hour before the first ball. start_date is a date and
-- start_time a local wall-clock string, so the two are combined in Cairo time
-- (the DB runs UTC; without this a 6 PM event would stay open until 9 PM).
-- Rows with no start_time keep the legacy midnight cutoff.
create or replace function public.tournament_reg_deadline(
  p_start date, p_start_time text)
returns timestamptz
language sql stable as $$
  select case
    when p_start is null then null
    when public._tournament_clock(p_start_time) is null
      then (p_start::timestamp at time zone 'Africa/Cairo')
    else ((p_start::timestamp + public._tournament_clock(p_start_time))
            at time zone 'Africa/Cairo') - interval '1 hour'
  end
$$;

drop function if exists public.register_for_tournament(uuid, uuid, text, text, text);

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
  v_status text; v_start date; v_cap int; v_min int; v_max int; v_fee int;
  v_count  int; v_my_elo int; v_my_name text; v_new text;
  v_mode   text; v_pay int; v_tname text; v_eid uuid; v_reg_opens date;
  v_category text; v_my_gender text; v_partner_gender text;
  v_start_time text; v_reg_closed boolean; v_deadline timestamptz;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select status, start_date, capacity, min_elo, max_elo, entry_fee, name, registration_opens, category,
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
    select coalesce(elo, 1000) into v_my_elo from public.profiles where id = v_uid;
    if v_min > 0 and v_my_elo < v_min then
      return 'This event has a minimum level you haven''t reached yet.';
    end if;
    if v_max is not null and v_max > 0 and v_my_elo > v_max then
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
grant execute on function
  public.register_for_tournament(uuid, uuid, text, text, text, text) to authenticated;

-- The PARTNER submits their own share (split mode).
create or replace function public.pay_partner_share(
  p_entry_id uuid, p_instapay_sender text, p_instapay_proof_url text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_tid uuid; v_player uuid; v_partner uuid; v_mode text; v_status text;
  v_fee int; v_tname text; v_pname text; v_org uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select e.tournament_id, e.player_id, e.partner_id, e.fee_mode, e.status,
         coalesce(t.entry_fee, 0), t.name, t.organizer_id
    into v_tid, v_player, v_partner, v_mode, v_status, v_fee, v_tname, v_org
    from public.tournament_entries e
    join public.tournaments t on t.id = e.tournament_id
   where e.id = p_entry_id;
  if not found then return 'Registration not found.'; end if;
  if v_partner is null or v_partner <> v_uid then
    return 'This isn''t your registration to pay for.';
  end if;
  if v_status in ('withdrawn', 'cancelled') then
    return 'This registration is no longer active.';
  end if;
  if v_fee <= 0 then return 'This is a free event.'; end if;
  if coalesce(v_mode, 'both') <> 'split' then
    return 'Your partner already covered the full entry — nothing to pay.';
  end if;

  update public.tournament_entries
     set partner_instapay_sender    = p_instapay_sender,
         partner_instapay_proof_url = p_instapay_proof_url,
         status = case when status = 'withdrawn' then status else 'pending' end
   where id = p_entry_id;

  select name into v_pname from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_player, 'tournament', 'Your partner paid their share',
          coalesce(v_pname, 'Your partner') || ' paid their share for ' ||
            coalesce(v_tname, 'the tournament') || '. Waiting on the organizer to confirm.',
          jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id));

  -- Tell the organizer (+ admins) a partner share landed and needs verifying.
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'admin_tournament', 'Partner share paid — verify',
         coalesce(v_pname, 'A partner') || ' paid their EGP ' || v_fee ||
           ' share for ' || coalesce(v_tname, 'a tournament') || '.',
         jsonb_build_object('tournament_id', v_tid, 'entry_id', p_entry_id, 'admin', true)
  from (select v_org as uid where v_org is not null
        union select p.id from public.profiles p where p.is_admin = true) r
  where uid is not null;
  return null;
end $$;
grant execute on function public.pay_partner_share(uuid, text, text) to authenticated;

-- Organizer/admin verifies ONE share; the entry flips to 'paid' only when the
-- pair is fully covered.
create or replace function public.verify_entry_share(p_entry_id uuid, p_which text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_tid uuid; v_mode text; v_partner uuid;
  v_payer boolean; v_partnerpaid boolean; v_full boolean;
begin
  select tournament_id, fee_mode, partner_id, payer_paid, partner_paid
    into v_tid, v_mode, v_partner, v_payer, v_partnerpaid
    from public.tournament_entries where id = p_entry_id;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_tid) then return 'Not your tournament.'; end if;

  if p_which = 'payer' then
    v_payer := true;
    if coalesce(v_mode, 'both') <> 'split' then v_partnerpaid := true; end if;
  elsif p_which = 'partner' then
    v_partnerpaid := true;
  else
    return 'Unknown payment share.';
  end if;

  v_full := v_payer and (v_partnerpaid
                         or coalesce(v_mode, 'both') <> 'split'
                         or v_partner is null);

  update public.tournament_entries
     set payer_paid   = v_payer,
         partner_paid = v_partnerpaid,
         status       = case when v_full then 'paid' else 'pending' end
   where id = p_entry_id;
  return null;
end $$;
grant execute on function public.verify_entry_share(uuid, text) to authenticated;

-- ============================================================================
-- Guest entries + organizer entry manager (2026-07-18). Not everyone in an
-- organizer's WhatsApp crowd is on the app yet, so entries can be GUESTS (names
-- only, no profile). player_id becomes nullable; the display layer already reads
-- player_name/partner_name (no profile join), so guests render as-is. Guests
-- can't be rated (finalize skips non-profile pairs) and can't self-report.
-- ============================================================================
alter table public.tournament_entries alter column player_id drop not null;
-- registered_at exists in migrations/0003; add it here too so the admin list
-- (which orders by it) works on a DB built from this canonical file alone.
alter table public.tournament_entries
  add column if not exists registered_at timestamptz not null default now();

-- Organizer adds a pair — a real player (p_player_id) or a guest (name only).
create or replace function public.organizer_add_entry(
  p_tournament_id uuid,
  p_player_id     uuid default null,
  p_player_name   text default null,
  p_partner_id    uuid default null,
  p_partner_name  text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_pname text; v_partname text;
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  if p_player_id is not null then
    select name into v_pname from public.profiles where id = p_player_id;
    if not found then return 'Player not found.'; end if;
    if exists (select 1 from public.tournament_entries
                where tournament_id = p_tournament_id and player_id = p_player_id
                  and status <> 'withdrawn') then
      return 'That player is already entered.';
    end if;
  end if;
  v_pname := coalesce(v_pname, nullif(btrim(p_player_name), ''));
  if v_pname is null then return 'Enter a name for the first player.'; end if;
  if p_partner_id is not null then
    select name into v_partname from public.profiles where id = p_partner_id;
  end if;
  v_partname := coalesce(v_partname, nullif(btrim(p_partner_name), ''));
  insert into public.tournament_entries
    (tournament_id, player_id, player_name, partner_id, partner_name, status)
  values (p_tournament_id, p_player_id, v_pname, p_partner_id, v_partname, 'registered');
  return null;
end $$;
grant execute on function public.organizer_add_entry(uuid, uuid, text, uuid, text) to authenticated;

-- Organizer removes an entry. Hard-delete if it isn't in the draw yet, else
-- soft-withdraw (a tournament_matches FK still points at it).
create or replace function public.organizer_remove_entry(p_entry_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_tid uuid;
begin
  select tournament_id into v_tid from public.tournament_entries where id = p_entry_id;
  if not found then return 'Entry not found.'; end if;
  if not public.owns_tournament(v_tid) then return 'Not authorised.'; end if;
  if exists (select 1 from public.tournament_matches
              where entry1 = p_entry_id or entry2 = p_entry_id or winner_entry = p_entry_id) then
    update public.tournament_entries set status = 'withdrawn' where id = p_entry_id;
  else
    delete from public.tournament_entries where id = p_entry_id;
  end if;
  return null;
end $$;
grant execute on function public.organizer_remove_entry(uuid) to authenticated;

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
    if new.partner_id is not null and new.partner_id <> new.player_id then
      insert into public.notifications (user_id, type, title, body, data)
      values (new.partner_id, 'tournament', 'Tournament payment confirmed',
              'You''re confirmed in ' || coalesce(v_name, 'the tournament') || '.',
              jsonb_build_object('tournament_id', new.tournament_id, 'entry_id', new.id));
    end if;
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

-- Notify every registered player (registrant + partner) when an organizer marks
-- a tournament postponed (with the new date) or cancelled (with an optional
-- reason). Fires only on the status transition, so re-saving doesn't re-notify.
-- Full notes: supabase/changes/2026-07-30_tournament_status_notify.sql
alter table public.tournaments add column if not exists cancel_reason text;

create or replace function public.notify_tournament_status_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_title text; v_body text; v_notify boolean := false;
begin
  -- Cancelled: on the transition into cancelled. Postponed: on entering postponed
  -- OR while already postponed if the start date moves again (re-postpone).
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    v_notify := true;
  elsif new.status = 'postponed'
        and (old.status is distinct from 'postponed'
             or new.start_date is distinct from old.start_date) then
    v_notify := true;
  end if;
  if not v_notify then return new; end if;

  select array_agg(distinct uid) into v_ids from (
    select player_id  uid from public.tournament_entries
      where tournament_id = new.id and status <> 'withdrawn' and player_id  is not null
    union
    select partner_id     from public.tournament_entries
      where tournament_id = new.id and status <> 'withdrawn' and partner_id is not null
  ) u;
  if v_ids is null or array_length(v_ids, 1) is null then return new; end if;

  if new.status = 'cancelled' then
    v_title := 'Tournament cancelled';
    v_body  := coalesce(new.name, 'A tournament') || ' has been cancelled.'
             || case when nullif(btrim(coalesce(new.cancel_reason, '')), '') is not null
                     then ' Reason: ' || btrim(new.cancel_reason) else '' end;
  else
    v_title := 'Tournament postponed';
    v_body  := coalesce(new.name, 'A tournament') || ' has been postponed'
             || case when new.start_date is not null
                     then ' to ' || to_char(new.start_date, 'Mon DD') else '' end || '.';
  end if;

  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'tournament', v_title, v_body,
         jsonb_build_object('tournament_id', new.id)
    from unnest(v_ids) as uid;
  return new;
end $$;

drop trigger if exists trg_notify_tournament_status_change on public.tournaments;
create trigger trg_notify_tournament_status_change
  after update on public.tournaments
  for each row execute function public.notify_tournament_status_change();

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
-- Legacy/backfill columns (rating engine v2 uses `rating`): allow NULL so an
-- unranked player can have no elo/level/tier. Older DBs created elo NOT NULL.
alter table public.profiles alter column elo   drop not null;
alter table public.profiles alter column level drop not null;
alter table public.profiles alter column tier  drop not null;
alter table public.profiles add column if not exists username text;
-- One-time gate for the "placement complete" reveal on Home: set true after the
-- player has seen the celebration once. Display-only (the client flips it).
alter table public.profiles add column if not exists placement_revealed boolean not null default false;
-- Backfill: players already placed before this feature shipped shouldn't get a
-- retroactive celebration — only NEW placements (going forward) trigger it.
update public.profiles
   set placement_revealed = true
 where coalesce(placement_played, 0) >= 5
   and placement_revealed is not true;

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

-- gender is male/female only (the 'other' option was removed from the UI); any
-- legacy 'other' rows are nulled so the tightened constraint applies cleanly.
update public.profiles set gender = null where gender = 'other';
alter table public.profiles drop constraint if exists profiles_gender_chk;
alter table public.profiles add constraint profiles_gender_chk
  check (gender is null or gender in ('male','female'));

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
  if v_gender is not null and v_gender not in ('male','female') then v_gender := null; end if;
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
       -- Start UNRANKED: no seeded elo/level/tier. rating stays NULL, sigma
       -- keeps its default (0.85). The player earns a rating over 5 placement
       -- matches (or an admin sets it). placement_played 0 = in placement.
       null, null, null, 0, 0)
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
-- Both the Payments section and Store & Orders work these rows.
drop policy if exists "orders: admin read" on public.orders;
create policy "orders: admin read" on public.orders for select
  using (public._has_access('payments') or public._has_access('store'));
drop policy if exists "orders: admin update" on public.orders;
create policy "orders: admin update" on public.orders for update
  using (public._can_edit('payments') or public._can_edit('store'))
  with check (public._can_edit('payments') or public._can_edit('store'));
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
drop policy if exists "trades: admin read" on public.trade_requests;
create policy "trades: admin read" on public.trade_requests for select
  using (player_id = auth.uid() or public._has_access('requests'));
drop policy if exists "trades: admin update" on public.trade_requests;
create policy "trades: admin update" on public.trade_requests for update
  using (public._can_edit('requests')) with check (public._can_edit('requests'));
-- Counter trade-ins never passed through the app, so the console records them
-- itself. Permissive policies OR together — the player's own "create own trade"
-- insert path above is unaffected. See changes/2026-08-10_admin_add_trade.sql.
drop policy if exists "trades: staff insert" on public.trade_requests;
create policy "trades: staff insert" on public.trade_requests for insert
  with check (public._can_edit('requests'));
-- Table-level privilege (separate from RLS): without this the role is rejected
-- before any policy is evaluated → "permission denied for table trade_requests".
grant select, insert, update on public.trade_requests to authenticated;
-- Named FK so PostgREST can resolve profiles!trade_requests_player_profile_fkey.
-- Guarded on the FK's TARGET, not its name: migrations/0003 created the table
-- with player_id → auth.users under the auto name `trade_requests_player_id_fkey`,
-- so a name-only guard skipped and the admin embed stayed broken.
do $$
declare c text;
begin
  select con.conname into c
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_class tgt on tgt.oid = con.confrelid
   where con.contype = 'f'
     and rel.relname = 'trade_requests'
     and rel.relnamespace = 'public'::regnamespace
     and tgt.relname = 'profiles'
     and tgt.relnamespace = 'public'::regnamespace
   limit 1;
  if c is null then
    -- NOT VALID: legacy rows whose player has no profiles row would block
    -- validation. PostgREST reads pg_constraint, so the embed resolves anyway.
    alter table public.trade_requests
      add constraint trade_requests_player_profile_fkey
      foreign key (player_id) references public.profiles(id) not valid;
  elsif c <> 'trade_requests_player_profile_fkey' then
    execute format(
      'alter table public.trade_requests rename constraint %I to trade_requests_player_profile_fkey', c);
  end if;
end $$;
-- The trade-in sheet submits human labels ('Like New', 'Good', 'Fair', 'Worn'),
-- so 0003's snake_case enum check has to go or every submission fails.
alter table public.trade_requests
  drop constraint if exists trade_requests_condition_chk;
-- Status vocabulary must include 'rejected' (admin declines a request).
alter table public.trade_requests
  drop constraint if exists trade_requests_status_chk;
alter table public.trade_requests
  add constraint trade_requests_status_chk
  check (status in ('pending','offer_made','accepted','rejected','declined','completed'));

-- Private bucket for trade-in racket photos (see trade_requests.photos above).
-- Players write only inside their own <uid>/ folder; the owner and requests
-- staff can read. Full notes: supabase/changes/2026-08-03_trade_photos.sql
insert into storage.buckets (id, name, public)
  values ('trade-photos', 'trade-photos', false)
  on conflict (id) do update set public = false;
drop policy if exists "trade-photos owner write" on storage.objects;
create policy "trade-photos owner write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'trade-photos'
              and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "trade-photos read" on storage.objects;
create policy "trade-photos read" on storage.objects
  for select to authenticated
  using (bucket_id = 'trade-photos'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public._has_access('requests')));

-- Repair requests: players submit their own; admins read/update the queue.
-- (Table created earlier alongside broadcasts; policies live here, after
-- _is_admin is defined.)
alter table public.repair_requests enable row level security;
drop policy if exists "repair: read own or admin" on public.repair_requests;
create policy "repair: read own or admin" on public.repair_requests
  for select using (player_id = auth.uid() or public._has_access('requests'));
do $$ begin
  create policy "repair: insert own" on public.repair_requests
    for insert with check (auth.uid() = player_id);
exception when duplicate_object then null; end $$;
drop policy if exists "repair: admin update" on public.repair_requests;
create policy "repair: admin update" on public.repair_requests
  for update using (public._can_edit('requests'))
  with check (public._can_edit('requests'));
grant select, insert, update on public.repair_requests to authenticated;
-- Same FK story as trade_requests: 0003 pointed player_id at auth.users, which
-- PostgREST cannot embed — the admin queue needs a relationship to profiles.
do $$
declare c text;
begin
  select con.conname into c
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_class tgt on tgt.oid = con.confrelid
   where con.contype = 'f'
     and rel.relname = 'repair_requests'
     and rel.relnamespace = 'public'::regnamespace
     and tgt.relname = 'profiles'
     and tgt.relnamespace = 'public'::regnamespace
   limit 1;
  if c is null then
    alter table public.repair_requests
      add constraint repair_requests_player_profile_fkey
      foreign key (player_id) references public.profiles(id) not valid;
  elsif c <> 'repair_requests_player_profile_fkey' then
    execute format(
      'alter table public.repair_requests rename constraint %I to repair_requests_player_profile_fkey', c);
  end if;
end $$;
-- 'rejected' is written when an admin declines; 0003's check omitted it.
alter table public.repair_requests
  drop constraint if exists repair_requests_status_chk;
alter table public.repair_requests
  add constraint repair_requests_status_chk
  check (status in ('pending','quoted','in_repair','ready','collected','rejected'));

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

-- ── Matchmaking band config (Phase 0) ──────────────────────────
-- Tunable constants for the video-game-style matchmaker (band = who sees/gets
-- paired with whom). Single source of truth, admin-editable, no redeploy.
-- Mirrored in Dart by MatchmakingConfig; keep in lockstep with that + the
-- mm_* consumers below. See supabase/changes/2026-07-15_matchmaking_config.sql.
insert into public.app_settings (key, value) values
  ('mm_band_base',         '0.4'),
  ('mm_band_widen_per_min','0.05'),
  ('mm_band_max',          '1.5'),
  ('mm_time_window_hours', '12'),
  ('mm_confirm_seconds',   '120'),
  ('mm_range_mode',        'city'),
  ('mm_ticket_ttl_hours',  '6')     -- background search ticket freshness window
on conflict (key) do nothing;

-- Band half-width for a search running age_minutes minutes. coalesce() falls
-- back to seed defaults so it's safe if a key is deleted.
create or replace function public.mm_band_halfwidth(age_minutes numeric)
returns numeric
language sql stable as $$
  with c as (
    select
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_base'), 0.4)          as base,
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_widen_per_min'), 0.05) as widen,
      coalesce((select value::numeric from public.app_settings where key = 'mm_band_max'), 1.5)           as bmax
  )
  select least(c.bmax, c.base + c.widen * greatest(coalesce(age_minutes, 0), 0)) from c;
$$;
grant execute on function public.mm_band_halfwidth(numeric) to authenticated;

-- ── Matchmaking Phase 1: band-center snapshot + discovery RPCs ──
-- Snapshot the creator's rating onto the match at creation so the band center
-- can't be forged from the client.
create or replace function public.mm_set_center_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.mm_center_rating is null and new.created_by is not null then
    select coalesce(rating, level, 2.0) into new.mm_center_rating
      from public.profiles where id = new.created_by;
  end if;
  return new;
end $$;

drop trigger if exists trg_mm_center_rating on public.matches;
create trigger trg_mm_center_rating before insert on public.matches
  for each row execute function public.mm_set_center_rating();

update public.matches m
   set mm_center_rating = coalesce(
         (select coalesce(p.rating, p.level, 2.0) from public.profiles p where p.id = m.created_by),
         2.0)
 where m.mm_center_rating is null
   and m.created_by is not null;

-- ============================================================================
-- Match lifecycle: grace window + auto-expire (2026-07-18). An under-filled
-- 'open' match stays fillable for a grace window PAST scheduled_at; if it's
-- still short of 4 after that, expire_stale_matches cancels it and notifies the
-- joined players (it then drops off every player-facing query, which all filter
-- to active statuses). cancel_match lets the host kill their own match anytime.
-- ============================================================================
-- Grace window (minutes) — how long past scheduled_at a match may still fill.
create or replace function public.mm_grace()
returns interval language sql stable set search_path = public as $$
  select coalesce((select value::numeric from public.app_settings
                    where key = 'mm_grace_minutes'), 30) * interval '1 minute';
$$;

-- Cancel every open match that's past its grace window and still under 4, and
-- notify everyone who had joined. Idempotent; safe for anyone to invoke (only
-- touches genuinely-stale matches).
create or replace function public.expire_stale_matches()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int := 0; r record;
begin
  for r in
    select mt.id from public.matches mt
     where mt.status = 'open'
       and mt.scheduled_at < now() - public.mm_grace()
       and (select count(*) from public.match_players mp where mp.match_id = mt.id) < 4
  loop
    update public.matches set status = 'cancelled' where id = r.id;
    insert into public.notifications (user_id, type, title, body, data)
    select mp.player_id, 'match', 'Match cancelled',
           'Your match didn''t fill up in time, so it was cancelled.',
           jsonb_build_object('match_id', r.id)
      from public.match_players mp where mp.match_id = r.id;
    v_n := v_n + 1;
  end loop;

  -- Auto-settle ranked matches stuck in pending_confirm for 48h+ (the other team
  -- never confirmed or disputed) — the submitted result stands. Idempotent via
  -- _settle_rating's rating_applied guard.
  for r in
    select id from public.matches
     where status = 'pending_confirm'
       and result_submitted_at is not null
       and result_submitted_at < now() - interval '48 hours'
  loop
    update public.matches set status = 'completed' where id = r.id;
    perform public._settle_rating(r.id);
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;
grant execute on function public.expire_stale_matches() to authenticated;

-- Host (or admin) cancels their own match; notifies the other joined players.
create or replace function public.cancel_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_creator uuid; v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select created_by, status into v_creator, v_status
    from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_creator <> v_uid and not public._is_admin() then
    return 'Only the host can cancel this match.';
  end if;
  if v_status in ('completed', 'cancelled') then
    return 'This match is already ' || v_status || '.';
  end if;
  update public.matches set status = 'cancelled' where id = p_match_id;
  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Match cancelled',
         'The host cancelled this match.', jsonb_build_object('match_id', p_match_id)
    from public.match_players mp
   where mp.match_id = p_match_id and mp.player_id <> v_uid;
  return null;
end $$;
grant execute on function public.cancel_match(uuid) to authenticated;

-- Run the sweep every 10 minutes if pg_cron is available (the client also calls
-- expire_stale_matches on Home load as a fallback).
do $$ begin
  perform cron.schedule('padel-expire-matches', '*/10 * * * *',
    'select public.expire_stale_matches()');
exception when others then
  raise notice 'pg_cron not available — expire_stale_matches runs via the client fallback.';
end $$;

-- The ONE way to discover a match you're not in: band-gatekept, SECURITY DEFINER
-- so it can scan the pool to filter it, but only ever returns rows in the
-- caller's band + city + time window. p_limit null = all (for counting).
-- Signature carries optional [p_from, p_to] so the client can matchmake on a
-- chosen day + time range; drop the older overloads first so calls stay
-- unambiguous (mm_count_candidates depends on it → drop that first).
drop function if exists public.mm_count_candidates();
drop function if exists public.mm_candidates(int);
create or replace function public.mm_candidates(
  p_limit int default null,
  p_from  timestamptz default null,
  p_to    timestamptz default null
)
returns table(
  match_id       uuid,
  scheduled_at   timestamptz,
  match_type     text,
  court_name     text,
  venue_name     text,
  city           text,
  creator_id     uuid,
  creator_name   text,
  creator_rating numeric,
  creator_level  numeric,
  players        int,
  center_rating  numeric,
  level_match_pct int
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_rating    numeric;
  v_city      text;
  v_placement boolean;
  v_window    numeric;
begin
  if v_uid is null then return; end if;

  -- Qualify with the table alias: the RETURNS TABLE column `city` shadows an
  -- unqualified `city` here (42702 ambiguous reference otherwise).
  select coalesce(p.rating, p.level, 2.0)::numeric, p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_placement
    from public.profiles p where p.id = v_uid;

  v_window := coalesce(
    (select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);

  -- ::numeric casts: profiles.level is double precision on the live DB, so the
  -- coalesces would promote to double and mismatch the numeric out-columns (42804).
  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         m.created_by, cp.name,
         coalesce(cp.rating, cp.level, 2.0)::numeric, coalesce(cp.level, cp.rating, 2.0)::numeric,
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)::numeric,
         greatest(0, round((1 - abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) / 3.5) * 100))::int
    from public.matches m
    join public.profiles cp on cp.id = m.created_by
    left join public.courts c on c.id = m.court_id
   where m.status = 'open'
     and m.created_by <> v_uid
     and m.scheduled_at > now() - public.mm_grace()  -- still fillable during grace
     -- Time window: explicit [p_from, p_to] when given, else the rolling window.
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
     -- Casual matches are UNRATED, so neither the rating band nor the
     -- placement/placed split applies — every player sees every open casual
     -- match in their city. Competitive keeps both gates.
     and (
       m.match_type = 'casual'
       or case when v_placement
         then coalesce(cp.placement_played, 0) < 5
         else coalesce(cp.placement_played, 0) >= 5
              and abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0))
                  <= public.mm_band_halfwidth(extract(epoch from (now() - m.created_at)) / 60.0)
       end
     )
     and (v_city is null or coalesce(c.city, cp.city) is null or coalesce(c.city, cp.city) = v_city)
   order by abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) asc,
            m.scheduled_at asc
   limit p_limit;
end $$;

create or replace function public.mm_count_candidates(
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.mm_candidates(null, p_from, p_to);
$$;

grant execute on function public.mm_candidates(int, timestamptz, timestamptz) to authenticated;
grant execute on function public.mm_count_candidates(timestamptz, timestamptz) to authenticated;

-- Accept a surfaced candidate (Phase 2). Race-safe join that RE-VERIFIES the
-- band server-side — a client can pass any match_id, so we never trust it came
-- from mm_candidates. First accepter wins the last slot (row lock).
-- Signature CHANGED (added p_partner_id) → drop the old 1-arg version first.
drop function if exists public.mm_accept(uuid);
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
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at
    into v_status, v_created_by, v_center, v_created_at
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null;
  end if;

  -- Bringing a partner: they must exist and not already be in the match. Their
  -- rating is band-checked below (in the placed branch) so the pair stays fair.
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

  v_need := case when p_partner_id is not null then 2 else 1 end;
  select count(*) into v_count from match_players where match_id = p_match_id;
  if v_count + v_need > 4 then
    return case when v_need = 2
      then 'Not enough room for you and a partner.'
      else 'This match just filled up.' end;
  end if;

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
    -- Keep the pair fair: a brought partner must be in-band too, so a friend of
    -- a very different rating can't be dragged in to skew the settled average.
    if p_partner_id is not null then
      select coalesce(rating, level, 2.0) into v_partner_rating
        from profiles where id = p_partner_id;
      if abs(coalesce(v_partner_rating, 2.0) - v_center) > v_hw then
        return 'Your partner is outside this match''s rating band.';
      end if;
    end if;
  end if;

  select count(*) filter (where team = 'a'), count(*) filter (where team = 'b')
    into v_team_a, v_team_b from match_players where match_id = p_match_id;

  if p_partner_id is not null then
    if 2 - v_team_a >= 2 then v_team := 'a';
    elsif 2 - v_team_b >= 2 then v_team := 'b';
    else return 'No side has room for a pair — join solo instead.'; end if;
  else
    v_team := case when v_team_a <= v_team_b then 'a' else 'b' end;
    if (v_team = 'a' and v_team_a >= 2) or (v_team = 'b' and v_team_b >= 2) then
      v_team := case v_team when 'a' then 'b' else 'a' end;
    end if;
  end if;

  insert into match_players (match_id, player_id, team) values (p_match_id, v_uid, v_team);
  if p_partner_id is not null then
    perform set_config('padel.partner_add', '1', true);
    insert into match_players (match_id, player_id, team) values (p_match_id, p_partner_id, v_team);
  end if;

  if v_count + v_need >= 4 then
    update matches set status = 'full' where id = p_match_id;
  end if;
  return null;
end $$;
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- Phase 3: the post-match result hero + per-player ack. Backfill acks matches
-- already completed so the hero doesn't retro-fire.
update public.match_players mp
   set result_ack = true
  from public.matches m
 where m.id = mp.match_id
   and m.status = 'completed'
   and coalesce(mp.result_ack, false) = false;

create or replace function public.mm_result_hero()
returns table(
  match_id      uuid,
  won           boolean,
  my_team       text,
  score_team_a  text,
  score_team_b  text,
  rating_delta  numeric,
  rating_after  numeric,
  match_type    text
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_mid uuid;
begin
  if v_uid is null then return; end if;

  select mp.match_id into v_mid
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
   where mp.player_id = v_uid
     and m.status = 'completed'
     and m.winner_team is not null
     and coalesce(mp.result_ack, false) = false
   order by m.scheduled_at desc nulls last
   limit 1;
  if v_mid is null then return; end if;

  return query
  select m.id,
         (mp.team = m.winner_team),
         mp.team,
         m.score_team_a,
         m.score_team_b,
         (select rh.delta::numeric from public.ranking_history rh
            where rh.profile_id = v_uid and rh.match_id = m.id
            order by rh.created_at desc limit 1),
         (select rh.rating_after::numeric from public.ranking_history rh
            where rh.profile_id = v_uid and rh.match_id = m.id
            order by rh.created_at desc limit 1),
         m.match_type
    from public.matches m
    join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
   where m.id = v_mid;
end $$;

create or replace function public.mm_ack_result(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.match_players
     set result_ack = true
   where match_id = p_match_id and player_id = auth.uid();
end $$;

grant execute on function public.mm_result_hero() to authenticated;
grant execute on function public.mm_ack_result(uuid) to authenticated;

-- ── Matchmaking Phase 4: background search + notify-to-confirm ──
-- Searching persists as a ticket; a band match while away drops a 'match'
-- notification (no match_id → routes to home, where the radar resumes) that the
-- push-notify Edge Function pushes. No pg_cron: fires on start-search + an
-- AFTER INSERT trigger on matches.
create table if not exists public.matchmaking_tickets (
  player_id              uuid primary key references public.profiles(id) on delete cascade,
  created_at             timestamptz not null default now(),
  last_notified_match_id uuid,
  last_notified_at       timestamptz
);
alter table public.matchmaking_tickets enable row level security;
do $$ begin
  create policy "mm_tickets: read own" on public.matchmaking_tickets
    for select using (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select on public.matchmaking_tickets to authenticated;

create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
  v_type text;
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = p_player;
  if not found then return false; end if;

  select m.status, m.created_by, coalesce(m.mm_center_rating, 2.0), m.created_at,
         m.scheduled_at, m.court_id, m.match_type
    into v_status, v_cby, v_center, v_created, v_sched, v_court, v_type
    from public.matches m where m.id = p_match;
  if not found or v_status <> 'open' or v_cby = p_player then return false; end if;
  if v_sched <= now() - public.mm_grace() then return false; end if;  -- past grace

  v_window := coalesce((select value::numeric from public.app_settings where key = 'mm_time_window_hours'), 12);
  if v_sched >= now() + (v_window * interval '1 hour') then return false; end if;

  select count(*) into v_count from public.match_players where match_id = p_match;
  if v_count >= 4 then return false; end if;
  if exists (select 1 from public.match_players where match_id = p_match and player_id = p_player) then
    return false;
  end if;

  select (coalesce(placement_played, 0) < 5), city into v_cplac, v_ccity
    from public.profiles where id = v_cby;
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

create or replace function public.mm_on_match_created()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ttl numeric;
begin
  if new.status <> 'open' then return new; end if;
  v_ttl := coalesce((select value::numeric from public.app_settings where key = 'mm_ticket_ttl_hours'), 6);

  insert into public.notifications (user_id, type, title, body, data)
  select t.player_id, 'match', 'Match found',
         'We found a match near your level — open Padel Rivals to confirm.',
         jsonb_build_object('kind', 'mm_found')
    from public.matchmaking_tickets t
   where t.created_at > now() - (v_ttl * interval '1 hour')
     and t.last_notified_match_id is distinct from new.id
     and public.mm_player_sees_match(t.player_id, new.id);

  update public.matchmaking_tickets t
     set last_notified_match_id = new.id, last_notified_at = now()
   where t.created_at > now() - (v_ttl * interval '1 hour')
     and t.last_notified_match_id is distinct from new.id
     and public.mm_player_sees_match(t.player_id, new.id);

  return new;
end $$;
drop trigger if exists trg_mm_on_match_created on public.matches;
create trigger trg_mm_on_match_created after insert on public.matches
  for each row execute function public.mm_on_match_created();

create or replace function public.mm_start_search()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_mid uuid;
begin
  if v_uid is null then return; end if;
  insert into public.matchmaking_tickets(player_id) values (v_uid)
    on conflict (player_id) do update
      set created_at = now(), last_notified_match_id = null, last_notified_at = null;

  select match_id into v_mid from public.mm_candidates(1);
  if v_mid is not null then
    insert into public.notifications (user_id, type, title, body, data)
    values (v_uid, 'match', 'Match found',
            'We found a match near your level — open Padel Rivals to confirm.',
            jsonb_build_object('kind', 'mm_found'));
    update public.matchmaking_tickets
       set last_notified_match_id = v_mid, last_notified_at = now()
     where player_id = v_uid;
  end if;
end $$;

create or replace function public.mm_cancel_search()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.matchmaking_tickets where player_id = auth.uid();
end $$;

grant execute on function public.mm_player_sees_match(uuid, uuid) to authenticated;
grant execute on function public.mm_start_search() to authenticated;
grant execute on function public.mm_cancel_search() to authenticated;

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
  using (bucket_id = 'payment-proofs'
         and (public._has_access('payments') or public._has_access('store')));

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
-- Own delete: the client prunes rows past its 30-day retention window.
do $$ begin
  create policy "notifications: own delete" on public.notifications
    for delete using (auth.uid() = user_id);
exception when duplicate_object then null; end $$;
grant select, update, delete on public.notifications to authenticated;

-- Per-user push preferences (mirrored in the Notifications screen). All default
-- ON so existing users keep receiving push. The push-notify Edge Function reads
-- these and skips the FCM send when the relevant toggle is off; the in-app
-- inbox row is inserted regardless.
alter table public.profiles
  add column if not exists notify_push       boolean not null default true,
  add column if not exists notify_match      boolean not null default true,
  add column if not exists notify_tournament boolean not null default true,
  add column if not exists notify_order      boolean not null default true;

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
-- Why an order was rejected/cancelled. Without these the player got the same
-- "was cancelled, contact support" line whether their transfer went missing
-- or the item sold out. Notes: supabase/changes/2026-08-03_order_cancel_reason.sql
alter table public.orders add column if not exists cancel_reason text;
alter table public.orders add column if not exists cancel_note   text;

-- The player-facing sentence for each reason code.
--
-- MIRRORS lib/backend/models/order_cancel_reason.dart (CancelReason.all) —
-- a trigger cannot call into Dart, so the copy lives in both places. Change
-- the wording in one, change it in the other.
create or replace function public._order_cancel_text(p_code text)
returns text language sql immutable as $$
  select case p_code
    when 'payment_not_received'  then 'We could not find your transfer in our account.'
    when 'payment_wrong_amount'  then 'The amount transferred did not match this order''s total.'
    when 'payment_unverifiable'  then 'The screenshot did not show a completed transfer we could match to this order.'
    when 'out_of_stock'          then 'An item in this order sold out before we could confirm it.'
    when 'address_issue'         then 'We could not deliver to the address on this order.'
    when 'duplicate'             then 'This looked like a duplicate of another order you placed.'
    when 'customer_request'      then 'Cancelled at your request.'
    else null
  end;
$$;

-- Reasons where we are holding money that has to go back. Only meaningful
-- for InstaPay orders — nothing is collected up front on cash-on-delivery.
create or replace function public._order_cancel_refunds(p_code text)
returns boolean language sql immutable as $$
  select p_code in ('payment_wrong_amount', 'out_of_stock',
                    'address_issue', 'duplicate', 'customer_request');
$$;

create or replace function public.notify_order_status()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_title text;
  v_body  text;
  v_ref   text := public._order_ref(new.id);
  v_why   text;
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
      -- Reason, then the admin's note, then the refund line where we owe.
      v_why := public._order_cancel_text(new.cancel_reason);
      if new.cancel_note is not null and btrim(new.cancel_note) <> '' then
        v_why := btrim(concat_ws(' ', v_why, btrim(new.cancel_note)));
      end if;
      if public._order_cancel_refunds(new.cancel_reason)
         and new.payment_method = 'instapay' then
        v_why := btrim(concat_ws(' ', v_why,
          'We will transfer your payment back to the InstaPay account you sent it from.'));
      end if;
      -- Falls back to the old wording for rows cancelled without a reason.
      v_body := v_ref || ' was cancelled. ' ||
                coalesce(nullif(v_why, ''), 'Contact support if this is unexpected.');
    when 'refunded' then
      v_title := 'Refund issued';
      v_why   := public._order_cancel_text(new.cancel_reason);
      if new.cancel_note is not null and btrim(new.cancel_note) <> '' then
        v_why := btrim(concat_ws(' ', v_why, btrim(new.cancel_note)));
      end if;
      v_body := v_ref || ' has been refunded.' ||
                coalesce(' ' || nullif(v_why, ''), '');
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

-- ============================================================================
-- Store integrity (2026-07-18): decrement stock on order so the catalog can't
-- oversell, and server-enforce the promo discount so a crafted client can't
-- forge it. (Subtotal/total still trust the client's item prices — acceptable
-- because every order is manually payment-verified by an admin.)
-- ============================================================================
create or replace function public.decrement_stock_on_order()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
    update public.products
       set stock = greatest(0, coalesce(stock, 0) - coalesce((it->>'qty')::int, 0))
     where id = nullif(it->>'product_id', '')::uuid
       and coalesce(made_to_order, false) = false;
  end loop;
  return new;
end $$;
drop trigger if exists trg_decrement_stock on public.orders;
create trigger trg_decrement_stock after insert on public.orders
  for each row execute function public.decrement_stock_on_order();

-- Restore stock + stamp who/when when an order is voided (2026-07-18). The
-- decrement above fires once at insert; without this, cancelling or refunding
-- an order permanently burned that inventory (the catalog could never recover
-- oversold-looking stock). BEFORE UPDATE so it can stamp the row, and guarded
-- to the single transition INTO a void state so re-saving 'refunded' can't
-- double-credit. auth.uid() records the acting admin — the refund/cancel audit.
alter table public.orders add column if not exists voided_at timestamptz;
alter table public.orders
  add column if not exists voided_by uuid references public.profiles(id) on delete set null;

create or replace function public.restock_on_void()
returns trigger language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  if new.status in ('cancelled', 'refunded')
     and old.status not in ('cancelled', 'refunded') then
    for it in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) loop
      update public.products
         set stock = coalesce(stock, 0) + coalesce((it->>'qty')::int, 0)
       where id = nullif(it->>'product_id', '')::uuid
         and coalesce(made_to_order, false) = false;
    end loop;
    new.voided_at := now();
    new.voided_by := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists trg_restock_on_void on public.orders;
create trigger trg_restock_on_void before update on public.orders
  for each row when (old.status is distinct from new.status)
  execute function public.restock_on_void();

create table if not exists public.promo_codes (
  code         text primary key,
  percent      int  not null default 0,
  active       boolean not null default true,
  min_subtotal int  not null default 0,
  created_at   timestamptz not null default now()
);
insert into public.promo_codes (code, percent) values ('PADEL10', 10)
  on conflict (code) do nothing;
alter table public.promo_codes enable row level security;
do $$ begin
  create policy "promo codes readable" on public.promo_codes
    for select to authenticated using (true);
exception when duplicate_object then null; end $$;
grant select on public.promo_codes to authenticated;

-- Discount (currency units) a code yields for a subtotal, or 0 if invalid.
create or replace function public.apply_promo(p_code text, p_subtotal int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((
    select floor(p_subtotal * pc.percent / 100.0)::int
      from public.promo_codes pc
     where upper(pc.code) = upper(btrim(p_code))
       and pc.active and p_subtotal >= pc.min_subtotal
  ), 0);
$$;
grant execute on function public.apply_promo(text, int) to authenticated;

-- Recompute discount + total server-side from the promo code at insert, so the
-- client can't send an arbitrary discount.
create or replace function public.enforce_order_promo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.promo_code is not null and btrim(new.promo_code) <> '' then
    new.discount := public.apply_promo(new.promo_code, coalesce(new.subtotal, 0));
  else
    new.discount := 0;
  end if;
  new.total := greatest(0, coalesce(new.subtotal, 0) + coalesce(new.shipping, 0) - coalesce(new.discount, 0));
  return new;
end $$;
drop trigger if exists trg_enforce_order_promo on public.orders;
create trigger trg_enforce_order_promo before insert on public.orders
  for each row execute function public.enforce_order_promo();

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
  v_fee  int;
begin
  if new.partner_id is null or new.partner_id = new.player_id then
    return new;
  end if;
  select name, coalesce(entry_fee, 0) into v_name, v_fee
    from public.tournaments where id = new.tournament_id;
  -- Paid events: register_for_tournament sends the tailored pay/you're-in message.
  if coalesce(v_fee, 0) > 0 then
    return new;
  end if;
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

-- ============================================================
-- Admin alerts + broadcast push (2026-06-26)
-- ------------------------------------------------------------
-- Four producers that previously had no notification path:
--   1. broadcasts        → one 'broadcast' row per targeted player (real push +
--                           bell badge; the audience segment is finally honored).
--   2. trade_requests    → 'admin_trade' to every admin.
--   3. repair_requests   → 'admin_repair' to every admin.
--   4. tournament_entries→ 'admin_tournament' when an InstaPay entry needs
--                           verifying (status pending + instapay).
-- Every insert lands in `notifications`, so the existing push-notify webhook
-- fans it to the recipient's devices for free. All run as security definer so
-- the inserting user (a player, or the admin updating a row) can write rows
-- owned by other users despite own-row RLS.
-- ============================================================

-- 1. Broadcast fan-out. Replaces the old "players read the broadcasts table
-- directly" path: each targeted player now gets their own notification row
-- (carries read state, badges the bell, triggers push). Segment is enforced
-- HERE — previously every player saw every broadcast regardless of audience.
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
          when 'ranked'   then coalesce(p.placement_played, 0) >= 5
          when 'unranked' then coalesce(p.placement_played, 0) < 5
          when 'specific' then p.id = any(coalesce(new.player_ids, '{}'::uuid[]))
          else true
        end;
  return new;
end $$;

drop trigger if exists trg_fanout_broadcast on public.broadcasts;
create trigger trg_fanout_broadcast
  after insert on public.broadcasts
  for each row
  execute function public.fanout_broadcast();

-- 2. New trade-in request → alert every admin.
create or replace function public.notify_admins_new_trade()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  -- Only when the PLAYER submitted it. A staffer recording a counter trade-in
  -- would otherwise ping every admin about their colleague's data entry, under
  -- a title that misdescribes it. auth.uid() is null for service-role/seed
  -- inserts, which stay quiet too.
  if new.player_id is distinct from auth.uid() then
    return new;
  end if;

  select name into v_name from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_trade',
         'New trade-in request',
         coalesce(v_name, 'A player') || ' · ' ||
           coalesce(new.racket_desc, 'racket'),
         jsonb_build_object('trade_id', new.id, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_trade on public.trade_requests;
create trigger trg_notify_admins_new_trade
  after insert on public.trade_requests
  for each row
  execute function public.notify_admins_new_trade();

-- 3. New repair request → alert every admin.
create or replace function public.notify_admins_new_repair()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_name text;
begin
  select name into v_name from public.profiles where id = new.player_id;
  insert into public.notifications (user_id, type, title, body, data)
  select p.id,
         'admin_repair',
         'New repair request',
         coalesce(v_name, 'A player') || ' · ' ||
           coalesce(new.racket_desc, 'racket'),
         jsonb_build_object('repair_id', new.id, 'admin', true)
  from public.profiles p
  where p.is_admin = true;
  return new;
end $$;

drop trigger if exists trg_notify_admins_new_repair on public.repair_requests;
create trigger trg_notify_admins_new_repair
  after insert on public.repair_requests
  for each row
  execute function public.notify_admins_new_repair();

-- 4. New InstaPay tournament entry awaiting verification → alert every admin.
-- Only fires for entries that actually need a manual check (pending + instapay);
-- free/cash entries don't generate noise.
-- New-entry payment alert goes to the OWNING ORGANIZER (+ admins) and states
-- which option the registrant chose (own share vs the full pair).
create or replace function public.notify_admins_tournament_payment()
returns trigger language plpgsql security definer
set search_path = public as $$
declare v_name text; v_org uuid; v_body text; v_partner text;
begin
  if new.status <> 'pending'
     or coalesce(new.payment_method, '') <> 'instapay' then
    return new;
  end if;
  select name, organizer_id into v_name, v_org
    from public.tournaments where id = new.tournament_id;
  v_partner := coalesce(nullif(btrim(new.partner_name), ''), 'their partner');
  if coalesce(new.fee_mode, 'both') = 'split' then
    v_body := coalesce(new.player_name, 'A player') || ' paid their EGP ' ||
              coalesce(new.paid_amount, 0)::text || ' share for ' ||
              coalesce(v_name, 'a tournament') || ' — ' || v_partner ||
              ' still needs to pay theirs.';
  else
    v_body := coalesce(new.player_name, 'A player') || ' paid the full EGP ' ||
              coalesce(new.paid_amount, 0)::text || ' pair entry for ' ||
              coalesce(v_name, 'a tournament') || ' (covering ' || v_partner || ').';
  end if;
  insert into public.notifications (user_id, type, title, body, data)
  select uid, 'admin_tournament', 'Tournament payment to verify', v_body,
         jsonb_build_object('tournament_id', new.tournament_id,
                            'entry_id', new.id, 'admin', true)
  from (select v_org as uid where v_org is not null
        union select p.id from public.profiles p where p.is_admin = true) r
  where uid is not null;
  return new;
end $$;

drop trigger if exists trg_notify_admins_tournament_payment on public.tournament_entries;
create trigger trg_notify_admins_tournament_payment
  after insert on public.tournament_entries
  for each row
  execute function public.notify_admins_tournament_payment();

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

-- email_login_methods(): which providers are behind an email, so "Forgot
-- password?" can refuse to mail a reset for a Google/Apple-only account (they
-- have no password to reset). Same accepted enumeration trade-off as
-- email_exists() above — if that is ever revisited, revisit both.
create or replace function public.email_login_methods(p_email text)
returns text[]
language sql
security definer
set search_path = auth, public
stable as $$
  select coalesce(array_agg(distinct i.provider order by i.provider), '{}'::text[])
    from auth.users u
    join auth.identities i on i.user_id = u.id
   where lower(u.email) = lower(trim(p_email));
$$;
grant execute on function public.email_login_methods(text) to anon, authenticated;

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

-- (community_chat's realtime publication is added right after that table is
-- created, further down — a fresh top-to-bottom run can't add a table to the
-- publication before the table exists.)

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

-- Tell the host when another player joins their match — and tell a player when
-- they've been ADDED to a match by someone else (create-with-partner or
-- join-with-partner). The adder sets the `padel.partner_add` GUC (transaction-
-- local) right before inserting the partner row, which routes the notification
-- to that partner instead of the host.
create or replace function public.notify_match_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_host        uuid;
  v_joiner      text;
  v_host_name   text;
  v_partner_add boolean;
begin
  select created_by into v_host from public.matches where id = new.match_id;
  if v_host is null then return new; end if;

  v_partner_add := coalesce(current_setting('padel.partner_add', true), '') = '1';

  -- Deliberate partner-add: ping the partner (the newly inserted player), never
  -- the host (they did the adding on purpose).
  if v_partner_add then
    if new.player_id <> v_host then
      select name into v_host_name from public.profiles where id = v_host;
      insert into public.notifications (user_id, type, title, body, data)
      values (new.player_id, 'match', 'You were added to a match',
              coalesce(v_host_name, 'A player') || ' added you to their match.',
              jsonb_build_object('match_id', new.match_id));
    end if;
    return new;
  end if;

  -- Normal join: tell the host. The host themselves joining (creation) sends
  -- nothing.
  if v_host = new.player_id then return new; end if;
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

-- ============================================================
-- Rating engine v2 (2026-07-02) — Playtomic-style: native 0.00–7.00 `rating`
-- is the source of truth (Elo + sigma uncertainty + margin + doubles). Mirrors
-- lib/backend/models/rating_engine.dart (keep in sync). These create-or-replace
-- definitions intentionally OVERRIDE the ELO-era functions defined earlier in
-- this file. `level` is kept as a display mirror of `rating`.
-- Full notes + standalone delta: supabase/changes/2026-07-02_rating_engine_v2.sql
-- ============================================================
alter table public.profiles
  add column if not exists rating       numeric(3,2),
  add column if not exists sigma        numeric not null default 0.85,
  add column if not exists is_anchor    boolean not null default false,
  add column if not exists competitive_matches int not null default 0,
  add column if not exists last_competitive_match_at timestamptz;
alter table public.profiles
  add column if not exists reliability numeric
    generated always as (round((1 - sigma / 1.0) * 100, 0)) stored;
alter table public.profiles
  add column if not exists is_provisional boolean
    generated always as (sigma > 0.40 or competitive_matches < 10) stored;
do $$ begin
  alter table public.profiles
    add constraint profiles_sigma_range check (sigma >= 0.12 and sigma <= 1.0);
exception when duplicate_object then null; end $$;

alter table public.matches
  add column if not exists rating_applied boolean not null default false;

alter table public.ranking_history
  add column if not exists rating_before numeric,
  add column if not exists rating_after  numeric,
  add column if not exists sigma_before  numeric,
  add column if not exists sigma_after   numeric,
  add column if not exists delta         numeric,
  add column if not exists opp_avg_rating numeric,
  add column if not exists games_for      int,
  add column if not exists games_against  int,
  add column if not exists won            boolean;

do $$
begin
  if not exists (select 1 from public.app_settings where key = 'rating_v2_backfilled') then
    update public.profiles p set
      competitive_matches = coalesce((
        select count(*) from public.ranking_history h
         where h.profile_id = p.id and h.match_id is not null), 0);
    update public.profiles p set
      rating = round(coalesce(level, public.level_from_elo(coalesce(elo, 1000)))::numeric, 2),
      last_competitive_match_at = (
        select max(h.created_at) from public.ranking_history h
         where h.profile_id = p.id and h.match_id is not null);
    update public.profiles p set
      sigma = greatest(0.12, round(power(0.92, competitive_matches)::numeric, 4));
    update public.profiles p set
      level = rating, tier = public.tier_from_level(rating)
      where rating is not null;
    insert into public.app_settings(key, value) values ('rating_v2_backfilled', 'true')
      on conflict (key) do nothing;
  end if;
end $$;

create or replace function public._parse_set_games(p_score text)
returns table(a int, b int)
language plpgsql immutable as $$
declare
  v_set text; v_parts text[]; v_a int; v_b int; ta int := 0; tb int := 0;
begin
  a := 0; b := 0;
  if p_score is null or btrim(p_score) = '' then return next; return; end if;
  foreach v_set in array string_to_array(p_score, ',') loop
    v_parts := string_to_array(btrim(v_set), '-');
    if array_length(v_parts, 1) <> 2 then continue; end if;
    if btrim(v_parts[1]) !~ '^\d+$' or btrim(v_parts[2]) !~ '^\d+$' then continue; end if;
    v_a := btrim(v_parts[1])::int;
    v_b := btrim(v_parts[2])::int;
    if v_a >= 10 or v_b >= 10 then
      if v_a > v_b then ta := ta + 1; elsif v_b > v_a then tb := tb + 1; end if;
    else
      ta := ta + v_a; tb := tb + v_b;
    end if;
  end loop;
  a := ta; b := tb; return next;
end $$;

-- Two-claim dispute model: each team's submitted result, kept even after a
-- dispute clears matches.score (so an admin can see both claims side-by-side).
create table if not exists public.match_result_submissions (
  match_id     uuid not null references public.matches(id) on delete cascade,
  team         text not null check (team in ('a','b')),
  submitter_id uuid references public.profiles(id),
  score_team_a text,
  score_team_b text,
  winner       text,
  created_at   timestamptz not null default now(),
  primary key (match_id, team)
);
alter table public.match_result_submissions enable row level security;
do $$ begin
  create policy "mrs: player or admin read" on public.match_result_submissions for select
    using (
      exists (select 1 from public.match_players mp
               where mp.match_id = match_result_submissions.match_id and mp.player_id = auth.uid())
      or public._has_access('matches')
    );
exception when duplicate_object then null; end $$;
grant select on public.match_result_submissions to authenticated;

create or replace function public.submit_match_result(
  p_match_id uuid, p_score_a text, p_score_b text, p_winner text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_type text; v_status text; v_sched timestamptz; v_team text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_winner not in ('a','b') then return 'Invalid winner.'; end if;
  select team into v_team from match_players where match_id = p_match_id and player_id = v_uid;
  if v_team is null then return 'Only players in this match can submit a score.'; end if;
  select match_type, status, scheduled_at into v_type, v_status, v_sched
    from matches where id = p_match_id for update;
  if v_status = 'completed' then return 'Result already confirmed.'; end if;
  if v_sched > now() then return 'Score entry opens after the match time.'; end if;
  update matches set
    score_team_a = p_score_a, score_team_b = p_score_b, winner_team = p_winner,
    result_submitted_by = v_uid, result_submitted_at = now(),
    status = case when v_type = 'ranked' then 'pending_confirm' else 'completed' end
  where id = p_match_id;
  insert into public.match_result_submissions
    (match_id, team, submitter_id, score_team_a, score_team_b, winner)
  values (p_match_id, v_team, v_uid, p_score_a, p_score_b, p_winner)
  on conflict (match_id, team) do update set
    submitter_id = excluded.submitter_id, score_team_a = excluded.score_team_a,
    score_team_b = excluded.score_team_b, winner = excluded.winner, created_at = now();
  return null;
end $$;

-- Backfill a submission from any match that currently has a stored result.
insert into public.match_result_submissions
  (match_id, team, submitter_id, score_team_a, score_team_b, winner)
select m.id,
       coalesce((select mp.team from public.match_players mp
                  where mp.match_id = m.id and mp.player_id = m.result_submitted_by), 'a'),
       m.result_submitted_by, m.score_team_a, m.score_team_b, m.winner_team
  from public.matches m
 where m.result_submitted_by is not null and m.winner_team is not null
on conflict (match_id, team) do nothing;

create or replace function public.confirm_match_result(p_match_id uuid, p_confirm boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_submitter uuid; v_status text; v_sub_team text; v_my_team text;
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
    perform public._settle_rating(p_match_id);
  else
    update matches set status = 'disputed', winner_team = null,
      score_team_a = null, score_team_b = null,
      result_submitted_by = null, result_submitted_at = null
    where id = p_match_id;
  end if;
  return null;
end $$;

create or replace function public.admin_set_player_rating(p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_rating numeric; v_rating numeric;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  v_rating := public.level_from_elo(greatest(800, least(2200, p_elo)));
  select coalesce(rating, coalesce(level, 0)) into v_old_rating
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = v_rating, tier = public.tier_from_level(v_rating),
    elo = greatest(800, least(2200, p_elo)), sigma = 0.30,
    competitive_matches = greatest(coalesce(competitive_matches, 0), 10),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta)
  values (p_player_id, null, v_old_rating, v_rating,
     v_old_rating, v_rating, null, 0.30, round(v_rating - v_old_rating, 2));
  return null;
end $$;

-- Superseded by the V3-F5 definition at the end of this file, and kept in sync
-- with it rather than left as the v2 original: the old body decayed RATINGS on
-- inactivity, and a full copy of that code sitting here — dead only because a
-- later create-or-replace wins — is a landmine for anyone reading or
-- reordering the file. Inactivity widens uncertainty and nothing else.
create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  update public.profiles p
     set sigma = greatest(p.sigma, least(0.60, p.sigma + 0.01))
  where coalesce(p.is_admin, false) = false and p.sigma < 0.60
    and (p.last_competitive_match_at is null
         or p.last_competitive_match_at < now() - interval '14 days');
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Grants for the rating-engine-v2 RPCs (their v1 defs + early grants were removed).
grant execute on function public.submit_match_result(uuid, text, text, text) to authenticated;
grant execute on function public.confirm_match_result(uuid, boolean) to authenticated;
grant execute on function public.admin_set_player_rating(uuid, int) to authenticated;

-- Admin rating controls (2026-07-03) — hand-set a 0..7 rating with an explicit
-- sigma + anchor flag; logs to ranking_history + audit_log. Two console actions:
-- Mark anchor (is_anchor, sigma 0.30) and Leveling session (sigma 0.50).
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
  v_rating := round(greatest(0.0, least(7.0, p_rating)), 2);
  v_sigma  := round(greatest(0.12, least(1.0, p_sigma)), 4);
  select coalesce(rating, coalesce(level, 0)), coalesce(sigma, 0.85), coalesce(is_anchor, false)
    into v_old_rating, v_old_sigma, v_old_anchor
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = v_rating, tier = public.tier_from_level(v_rating),
    elo = greatest(800, least(2200, (800 + v_rating * 200)::int)),
    sigma = v_sigma, is_anchor = coalesce(p_is_anchor, false),
    competitive_matches = greatest(coalesce(competitive_matches, 0), 10),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta)
  values (p_player_id, null, v_old_rating, v_rating,
     v_old_rating, v_rating, v_old_sigma, v_sigma, round(v_rating - v_old_rating, 2));
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
grant execute on function public.admin_set_rating(uuid, numeric, numeric, boolean, text) to authenticated;

-- Ban / unban / flag a player (RBAC, 2026-07-18). profiles.status is service-
-- role-only (the profiles_update_own policy + column grant let a player touch
-- only their own id/username), so the console's direct `update profiles set
-- status` matched 0 rows and silently failed. This SECURITY DEFINER RPC does
-- the write, refuses to touch an admin account, and logs to audit_log.
-- Gated to super admins + Support · Moderator (_can_moderate()).
create or replace function public.admin_set_status(p_player_id uuid, p_status text)
returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old text; v_target_admin boolean;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  if p_status not in ('active','banned','flagged') then return 'Invalid status.'; end if;
  select coalesce(status, 'active'), coalesce(is_admin, false)
    into v_old, v_target_admin
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  if v_target_admin then return 'Cannot change an admin account.'; end if;
  update public.profiles set status = p_status where id = p_player_id;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'set_player_status', 'profile', p_player_id,
          jsonb_build_object('status', v_old),
          jsonb_build_object('status', p_status), null);
  return null;
end $$;
grant execute on function public.admin_set_status(uuid, text) to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- RBAC — role-based console access (Phase 1 of Roles/Organizer/Community).
-- Full notes: supabase/changes/2026-07-10_rbac_roles.sql. Adds a finer role on
-- top of `is_admin` WITHOUT weakening security: only super admins keep
-- is_admin=true (full DB access); organizer/support/analyst are is_admin=false,
-- so every existing _is_admin()-gated table stays locked at the database.
-- ════════════════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists admin_role   text;
alter table public.profiles add column if not exists admin_access jsonb;
alter table public.profiles add column if not exists admin_scope  text;
alter table public.profiles add column if not exists is_owner     boolean not null default false;

do $$ begin
  alter table public.profiles
    add constraint profiles_admin_role_chk
    check (admin_role is null or admin_role in ('super_admin','organizer','support','analyst'));
exception when duplicate_object then null; end $$;

create index if not exists idx_profiles_admin_role
  on public.profiles (admin_role) where admin_role is not null;

-- One-time backfill: existing admins become super_admins (guarded so re-runs
-- never clobber roles assigned later). Oldest admin becomes the locked owner.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'rbac_backfilled') then
    update public.profiles
       set admin_role = 'super_admin'
     where coalesce(is_admin, false) = true
       and admin_role is null;
    if not exists (select 1 from public.profiles where is_owner = true) then
      update public.profiles set is_owner = true
       where id = (select id from public.profiles
                    where coalesce(is_admin, false) = true
                    order by created_at nulls last, id
                    limit 1);
    end if;
    insert into public.app_settings (key, value)
    values ('rbac_backfilled', 'true')
    on conflict (key) do nothing;
  end if;
end $$;

create or replace function public.admin_grant_role(
  p_user   uuid,
  p_role   text,
  p_access jsonb default null,
  p_scope  text  default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_old_access jsonb; v_old_scope text; v_owner boolean;
  v_wanted text[]; v_bad text;
begin
  if not public._can_edit('team') then return 'Not authorised.'; end if;
  if p_role not in ('super_admin','organizer','support','analyst') then
    return 'Unknown role.';
  end if;
  select admin_role, admin_access, admin_scope, coalesce(is_owner, false)
    into v_old_role, v_old_access, v_old_scope, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner always has full access and can''t be changed.'; end if;
  -- The Team section is grantable, so a non-super-admin can reach this. They
  -- must not be able to escalate: no minting/editing super admins, and no
  -- handing out a section they don't hold themselves.
  if not public._is_admin() then
    if p_role = 'super_admin' or v_old_role = 'super_admin' then
      return 'Only a super admin can manage super admins.';
    end if;
    v_wanted := case
      when jsonb_typeof(p_access) = 'array' and jsonb_array_length(p_access) > 0
        then (select array(select jsonb_array_elements_text(p_access)))
      else public._role_default(p_role)
    end;
    select t.sec into v_bad from unnest(v_wanted) as t(sec)
     where not public._has_access(t.sec) limit 1;
    if v_bad is not null then
      return 'You can only grant access you have yourself (' || v_bad || ').';
    end if;
  end if;
  update public.profiles set
    admin_role   = p_role,
    admin_access = p_access,
    admin_scope  = nullif(btrim(coalesce(p_scope, '')), ''),
    is_admin     = (p_role = 'super_admin')
  where id = p_user;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'grant_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role, 'access', v_old_access, 'scope', v_old_scope),
    jsonb_build_object('role', p_role,     'access', p_access,     'scope', p_scope),
    null);
  return null;
end $$;
grant execute on function public.admin_grant_role(uuid, text, jsonb, text) to authenticated;

create or replace function public.admin_revoke_role(p_user uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_old_role text; v_owner boolean;
begin
  if not public._can_edit('team') then return 'Not authorised.'; end if;
  select admin_role, coalesce(is_owner, false) into v_old_role, v_owner
    from public.profiles where id = p_user;
  if not found then return 'User not found.'; end if;
  if v_owner then return 'The owner can''t be removed.'; end if;
  if v_old_role = 'super_admin' and not public._is_admin() then
    return 'Only a super admin can manage super admins.';
  end if;
  update public.profiles set
    admin_role = null, admin_access = null, admin_scope = null, is_admin = false
  where id = p_user;
  insert into public.audit_log
    (admin_id, action, target_type, target_id, old_value, new_value, notes)
  values (v_uid, 'revoke_role', 'profile', p_user,
    jsonb_build_object('role', v_old_role), jsonb_build_object('role', null), null);
  return null;
end $$;
grant execute on function public.admin_revoke_role(uuid) to authenticated;

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
           coalesce(p.is_owner, false), p.avatar_url, p.level::numeric
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is not null
     order by coalesce(p.is_owner, false) desc, p.name nulls last;
end $$;
grant execute on function public.admin_list_staff() to authenticated;

create or replace function public.admin_search_users(p_term text)
returns table (id uuid, name text, email text, level numeric, avatar_url text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._has_access('team') then return; end if;
  if length(btrim(coalesce(p_term, ''))) < 2 then return; end if;
  return query
    select p.id, p.name, u.email::text, p.level::numeric, p.avatar_url
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.admin_role is null
       and (p.name ilike '%' || p_term || '%' or u.email ilike '%' || p_term || '%')
     order by p.name nulls last
     limit 8;
end $$;
grant execute on function public.admin_search_users(text) to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- Organizer role — Phase 2 of Roles/Organizer/Community.
-- Full notes: supabase/changes/2026-07-10_organizer.sql. Organizers run their
-- own tournaments; the two bracket RPC gates above were switched from
-- _is_admin() to owns_tournament() (defined here — plpgsql resolves it at call
-- time, so the forward reference is fine on a full re-run).
-- ════════════════════════════════════════════════════════════════════════════
alter table public.tournaments
  add column if not exists organizer_id uuid references public.profiles(id) on delete set null;
create index if not exists idx_tournaments_organizer
  on public.tournaments (organizer_id) where organizer_id is not null;

create or replace function public.current_admin_role()
returns text language sql stable security definer set search_path = public as $$
  select admin_role from public.profiles where id = auth.uid();
$$;
grant execute on function public.current_admin_role() to authenticated;

-- Organizers stay scoped to their OWN events; any other staffer holding the
-- Tournaments (or Format Builder) section manages all of them, like an admin.
create or replace function public.owns_tournament(p_tid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public._is_admin()
      or (
        (public._can_edit('tournaments') or public._can_edit('formats'))
        and (
          coalesce(public.current_admin_role(), '') <> 'organizer'
          or exists (select 1 from public.tournaments t
                      where t.id = p_tid and t.organizer_id = auth.uid())
        )
      );
$$;
grant execute on function public.owns_tournament(uuid) to authenticated;

create or replace function public.set_tournament_organizer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.organizer_id is null and public.current_admin_role() = 'organizer' then
    -- Organizers must set up their community before publishing a tournament.
    -- (Super admins skip this — their role isn't 'organizer'.)
    if not exists (select 1 from public.communities where organizer_id = auth.uid()) then
      raise exception 'Create your community before publishing a tournament.'
        using errcode = 'check_violation';
    end if;
    new.organizer_id := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists trg_tournaments_set_organizer on public.tournaments;
create trigger trg_tournaments_set_organizer
  before insert on public.tournaments
  for each row execute function public.set_tournament_organizer();

do $$ begin
  create policy "tournaments: organizer write own" on public.tournaments for all
    using (organizer_id = auth.uid() and public.current_admin_role() = 'organizer')
    with check (organizer_id = auth.uid() and public.current_admin_role() = 'organizer');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "entries: organizer write own" on public.tournament_entries for update
    using (public.owns_tournament(tournament_id))
    with check (public.owns_tournament(tournament_id));
exception when duplicate_object then null; end $$;

create or replace function public.organizer_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return json_build_object('error', 'not_organizer');
  end if;
  return json_build_object(
    'tournaments', (select count(*) from tournaments where organizer_id = v_uid),
    'accepting',   (select count(*) from tournaments
                     where organizer_id = v_uid and status in ('open','upcoming')),
    'entrants',    (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status not in ('withdrawn','cancelled')),
    'reach',       (select count(distinct pid) from (
                       select te.player_id pid from tournament_entries te
                        where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                          and te.status not in ('withdrawn','cancelled')
                       union
                       select cm.player_id from community_members cm
                        where cm.community_id in (select id from communities where organizer_id = v_uid)) u),
    'fees',        (select coalesce(sum(coalesce(paid_amount,0)),0) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'paid'),
    'to_verify',   (select count(*) from tournament_entries te
                     where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                       and te.status = 'pending'),
    'largest_event', (select coalesce(max(cnt), 0) from (
                       select te.tournament_id, count(*) cnt from tournament_entries te
                        where te.tournament_id in (select id from tournaments where organizer_id = v_uid)
                          and te.status not in ('withdrawn','cancelled')
                        group by te.tournament_id) x),
    'open_rate',   (select case when count(*) = 0 then 0
                       else round(100.0 * count(*) filter (where n.read) / count(*)) end
                     from notifications n
                    where n.type = 'community'
                      and n.data->>'community_id' in
                          (select id::text from communities where organizer_id = v_uid))
  );
end $$;
grant execute on function public.organizer_overview() to authenticated;

create table if not exists public.organizer_broadcasts (
  id            uuid primary key default gen_random_uuid(),
  organizer_id  uuid not null references public.profiles(id) on delete cascade,
  tournament_id uuid references public.tournaments(id) on delete set null,
  title         text not null,
  body          text,
  recipients    int not null default 0,
  created_at    timestamptz not null default now()
);
-- Broadcasts double as social posts: an optional image + a link to the mirrored
-- community feed post (where members like/comment). announcement_id is a plain
-- uuid (no FK) because community_announcements is created later in this file.
-- See 2026-07-29_broadcast_media.sql.
alter table public.organizer_broadcasts add column if not exists image_url text;
alter table public.organizer_broadcasts add column if not exists announcement_id uuid;
create index if not exists idx_org_broadcasts_owner on public.organizer_broadcasts (organizer_id, created_at desc);
alter table public.organizer_broadcasts enable row level security;
do $$ begin
  create policy "org_broadcasts: owner read" on public.organizer_broadcasts for select
    using (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

-- A broadcast is BOTH a push blast (to entrants ∪ community members) AND, when
-- the organizer has a community, a likeable/commentable community feed post with
-- an optional image. One compose action → notification + social post.
drop function if exists public.organizer_broadcast(text, text, uuid);
create or replace function public.organizer_broadcast(
  p_title text, p_body text, p_tournament_id uuid default null, p_image_url text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ids uuid[]; v_n int; v_cid uuid; v_aid uuid;
begin
  if not public._can_edit('broadcasts') then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  if p_tournament_id is not null and not public.owns_tournament(p_tournament_id) then
    return 'Not your tournament.';
  end if;
  select array_agg(distinct pid) into v_ids from (
    select te.player_id pid
      from public.tournament_entries te
     where te.status not in ('withdrawn','cancelled')
       and te.tournament_id in (
         select id from public.tournaments
          where organizer_id = v_uid
            and (p_tournament_id is null or id = p_tournament_id))
    union
    select cm.player_id
      from public.community_members cm
     where p_tournament_id is null
       and cm.community_id in (select id from public.communities where organizer_id = v_uid)
  ) u where pid is not null;
  v_n := coalesce(array_length(v_ids, 1), 0);

  -- Mirror as a community feed post (with the optional image) so members can
  -- like + comment. Not tournament-scoped broadcasts only? We still post to the
  -- organizer's single community whenever one exists.
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is not null then
    insert into public.community_announcements (community_id, title, body, image_url)
    values (v_cid, p_title, nullif(btrim(coalesce(p_body,'')),''),
            nullif(btrim(coalesce(p_image_url,'')),''))
    returning id into v_aid;
  end if;

  if v_n = 0 and v_aid is null then
    return 'No one to reach yet — get community members or event entrants first.';
  end if;

  if v_n > 0 then
    insert into public.notifications (user_id, type, title, body, data)
    select uid, 'broadcast', p_title, nullif(btrim(p_body), ''),
           jsonb_build_object('from', 'organizer', 'community_id', v_cid,
                              'announcement_id', v_aid)
      from unnest(v_ids) as uid;
  end if;
  insert into public.organizer_broadcasts
    (organizer_id, tournament_id, title, body, recipients, image_url, announcement_id)
  values (v_uid, p_tournament_id, p_title, nullif(btrim(p_body), ''), v_n,
          nullif(btrim(coalesce(p_image_url,'')),''), v_aid);
  return null;
end $$;
grant execute on function public.organizer_broadcast(text, text, uuid, text) to authenticated;

-- ── Organizer InstaPay payout (username + link) ──────────────────────────────
-- Each organizer sets their own InstaPay username and/or payment link in the
-- console; players registering for a PAID tournament transfer to the *owning
-- organizer's* details (falling back to the platform app_settings handle, then
-- a hard default). Full notes: supabase/changes/2026-07-29_organizer_instapay.sql
alter table public.profiles add column if not exists instapay_handle text;
alter table public.profiles add column if not exists instapay_link   text;

-- Organizer (or admin) sets their own payout username + link; applies to every
-- event they own. Returns null on success, or an error string.
drop function if exists public.set_my_instapay_handle(text);
create or replace function public.set_my_instapay(p_handle text, p_link text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  update public.profiles
     set instapay_handle = nullif(btrim(p_handle), ''),
         instapay_link   = nullif(btrim(p_link), '')
   where id = auth.uid();
  return null;
end $$;
grant execute on function public.set_my_instapay(text, text) to authenticated;

-- The InstaPay details a player transfers to for a given tournament: the owning
-- organizer's handle/link if set, else the platform-wide app_settings handle,
-- else a hard default. SECURITY DEFINER so it reads across profiles/app_settings.
drop function if exists public.tournament_pay_handle(uuid);
create or replace function public.tournament_pay_info(p_tournament_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'handle', coalesce(
      nullif(btrim(p.instapay_handle), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_handle')), ''),
      'padelpro@instapay'),
    -- The link resolves the same way as the handle: organizer, then platform.
    'link', coalesce(
      nullif(btrim(p.instapay_link), ''),
      nullif(btrim((select value from public.app_settings where key = 'instapay_link')), '')))
    from public.tournaments t
    left join public.profiles p on p.id = t.organizer_id
   where t.id = p_tournament_id;
$$;
grant execute on function public.tournament_pay_info(uuid) to authenticated, anon;

-- ════════════════════════════════════════════════════════════════════════════
-- Community — Phase 3 of Roles/Organizer/Community.
-- Full notes: supabase/changes/2026-07-10_community.sql. One community per
-- organizer; players join, RSVP, and message the organizer. Because organizers
-- are console-only, member↔organizer chat lives in community_messages (read in
-- the console inbox), NOT the player DM system.
-- ════════════════════════════════════════════════════════════════════════════
create table if not exists public.communities (
  id           uuid primary key default gen_random_uuid(),
  organizer_id uuid not null unique references public.profiles(id) on delete cascade,
  name         text not null,
  handle       text,
  city         text,
  about        text,
  verified     boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists communities_handle_key
  on public.communities (lower(handle)) where handle is not null;

create table if not exists public.community_members (
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  joined_at    timestamptz not null default now(),
  primary key (community_id, player_id)
);
create index if not exists idx_community_members_player
  on public.community_members (player_id);

create table if not exists public.community_announcements (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  title        text not null,
  body         text,
  pinned       boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_ann_community
  on public.community_announcements (community_id, created_at desc);

create table if not exists public.announcement_rsvps (
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  primary key (announcement_id, player_id)
);

create table if not exists public.community_messages (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  member_id    uuid not null references public.profiles(id) on delete cascade,
  sender_role  text not null check (sender_role in ('member','organizer')),
  body         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_messages_thread
  on public.community_messages (community_id, member_id, created_at);

alter table public.communities             enable row level security;
alter table public.community_members       enable row level security;
alter table public.community_announcements enable row level security;
alter table public.announcement_rsvps      enable row level security;
alter table public.community_messages      enable row level security;

do $$ begin
  create policy "communities: read all" on public.communities for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "communities: organizer write own" on public.communities for all
    using (organizer_id = auth.uid() or public._is_admin())
    with check (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "members: read all" on public.community_members for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "members: join self" on public.community_members for insert
    with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "members: leave self" on public.community_members for delete
    using (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "announcements: read all" on public.community_announcements for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "announcements: organizer write" on public.community_announcements for all
    using (exists (select 1 from public.communities c
                    where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())))
    with check (exists (select 1 from public.communities c
                    where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "rsvps: read all" on public.announcement_rsvps for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "rsvps: own write" on public.announcement_rsvps for all
    using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "messages: member or organizer read" on public.community_messages for select
    using (member_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;

-- Community group chat (the hub "Chat" tab): any member/organizer posts, all
-- members + organizer/admin read. Distinct from the 1:1 community_messages thread.
create table if not exists public.community_chat (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  sender_id    uuid not null references public.profiles(id) on delete cascade,
  body         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_community_chat
  on public.community_chat (community_id, created_at);
-- Realtime so open clients see new channel posts live (RLS still scopes
-- delivery to community members). Placed here — after the table exists.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'community_chat'
  ) then
    alter publication supabase_realtime add table public.community_chat;
  end if;
end $$;
alter table public.community_chat enable row level security;
do $$ begin
  create policy "community_chat: member read" on public.community_chat for select
    using (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    );
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "community_chat: member write" on public.community_chat for insert
    with check (
      sender_id = auth.uid()
      and (
        exists (select 1 from public.community_members m
                 where m.community_id = community_chat.community_id and m.player_id = auth.uid())
        or exists (select 1 from public.communities c
                    where c.id = community_chat.community_id and c.organizer_id = auth.uid())
      )
    );
exception when duplicate_object then null; end $$;
grant select, insert on public.community_chat to authenticated;

-- ── Community channels (Phase 1): named channels over community_chat ──
create table if not exists public.community_channels (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  name         text not null,
  post         text not null default 'all' check (post in ('all','registered','org')),
  is_custom    boolean not null default false,
  sort         int not null default 0,
  created_at   timestamptz not null default now(),
  unique (community_id, name)
);
create index if not exists idx_community_channels
  on public.community_channels (community_id, sort, created_at);
alter table public.community_channels enable row level security;
do $$ begin
  create policy "community_channels: member read" on public.community_channels for select
    using (
      exists (select 1 from public.community_members m
               where m.community_id = community_channels.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_channels.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    );
exception when duplicate_object then null; end $$;
grant select on public.community_channels to authenticated;

create or replace function public.seed_default_channels(p_community_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.community_channels (community_id, name, post, sort) values
    (p_community_id, 'general',         'all', 0),
    (p_community_id, 'looking-for-4th', 'all', 1),
    (p_community_id, 'off-topic',       'all', 2)
  on conflict (community_id, name) do nothing;
end $$;

create or replace function public.tg_seed_channels()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_default_channels(new.id);
  return new;
end $$;
drop trigger if exists trg_seed_channels on public.communities;
create trigger trg_seed_channels after insert on public.communities
  for each row execute function public.tg_seed_channels();

do $$ declare r record; begin
  for r in select id from public.communities loop
    perform public.seed_default_channels(r.id);
  end loop;
end $$;

alter table public.community_chat
  add column if not exists channel_id uuid references public.community_channels(id) on delete cascade;
create index if not exists idx_community_chat_channel
  on public.community_chat (channel_id, created_at);
update public.community_chat cc
   set channel_id = ch.id
  from public.community_channels ch
 where ch.community_id = cc.community_id and ch.name = 'general' and cc.channel_id is null;

-- Superseded twice below (event channels, then can_post). Drop first so a
-- re-run against a DB that already has the wider shape doesn't error on the
-- return-type change ("cannot change return type of existing function").
drop function if exists public.community_channel_list(uuid);
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, preview text, last_at timestamptz
)
language sql stable set search_path = public as $$
  select ch.id, ch.name, ch.post, ch.is_custom, lm.body, lm.created_at
    from public.community_channels ch
    left join lateral (
      select body, created_at from public.community_chat cc
       where cc.channel_id = ch.id order by cc.created_at desc limit 1
    ) lm on true
   where ch.community_id = p_community_id
   order by ch.sort, ch.created_at;
$$;
grant execute on function public.community_channel_list(uuid) to authenticated;

-- ── Community channels Phase 2: auto event channels + lifecycle ──
-- Tournaments auto-spawn an event channel; state (active/grace/archived) is
-- derived from ends_at (no cron needed to display). pg_cron only purges 30 days
-- after archiving.
alter table public.community_channels add column if not exists kind    text not null default 'community';
alter table public.community_channels add column if not exists event_id uuid;
alter table public.community_channels add column if not exists ends_at  timestamptz;
create unique index if not exists uq_community_channels_event
  on public.community_channels (community_id, event_id);

create or replace function public.tg_event_channel()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cid uuid; v_name text; v_ends timestamptz;
begin
  if new.organizer_id is null then return new; end if;
  select id into v_cid from public.communities where organizer_id = new.organizer_id limit 1;
  if v_cid is null then return new; end if;
  v_name := trim(both '-' from lower(regexp_replace(coalesce(new.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then v_name := 'event-' || left(new.id::text, 8); end if;
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    v_name := v_name || '-' || left(new.id::text, 4);
  end if;
  v_ends := (coalesce(new.end_date, new.start_date))::timestamptz + interval '1 day';
  insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
  values (v_cid, v_name, 'tournament', new.id, v_ends, 'all', 100)
  on conflict (community_id, event_id) do nothing;
  return new;
end $$;
drop trigger if exists trg_event_channel on public.tournaments;
create trigger trg_event_channel after insert on public.tournaments
  for each row execute function public.tg_event_channel();

do $$
declare r record; v_cid uuid; v_name text; v_ends timestamptz;
begin
  for r in select id, organizer_id, name, start_date, end_date
             from public.tournaments where organizer_id is not null loop
    select id into v_cid from public.communities where organizer_id = r.organizer_id limit 1;
    if v_cid is null then continue; end if;
    if exists (select 1 from public.community_channels where community_id = v_cid and event_id = r.id) then
      continue;
    end if;
    v_name := trim(both '-' from lower(regexp_replace(coalesce(r.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
    if v_name = '' then v_name := 'event-' || left(r.id::text, 8); end if;
    if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
      v_name := v_name || '-' || left(r.id::text, 4);
    end if;
    v_ends := (coalesce(r.end_date, r.start_date))::timestamptz + interval '1 day';
    insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
    values (v_cid, v_name, 'tournament', r.id, v_ends, 'all', 100)
    on conflict (community_id, event_id) do nothing;
  end loop;
end $$;

drop policy if exists "community_chat: member write" on public.community_chat;
create policy "community_chat: member write" on public.community_chat for insert
  with check (
    sender_id = auth.uid()
    and (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id and c.organizer_id = auth.uid())
    )
    and not exists (
      select 1 from public.community_channels ch
       where ch.id = community_chat.channel_id
         and ch.kind <> 'community'
         and ch.ends_at is not null
         and now() >= ch.ends_at + interval '24 hours'
    )
  );

drop function if exists public.community_channel_list(uuid);
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, kind text, state text,
  event_id uuid, going int, preview text, last_at timestamptz
)
language sql stable set search_path = public as $$
  select ch.id, ch.name, ch.post, ch.is_custom, ch.kind,
         case when ch.kind = 'community' or ch.ends_at is null then 'active'
              when now() < ch.ends_at then 'active'
              when now() < ch.ends_at + interval '24 hours' then 'grace'
              else 'archived' end as state,
         ch.event_id,
         coalesce((select count(*)::int from public.tournament_entries te
                    where te.tournament_id = ch.event_id and te.status <> 'withdrawn'), 0) as going,
         lm.body, lm.created_at
    from public.community_channels ch
    left join lateral (
      select body, created_at from public.community_chat cc
       where cc.channel_id = ch.id order by cc.created_at desc limit 1
    ) lm on true
   where ch.community_id = p_community_id
   order by
     case ch.kind when 'community' then 0 else 1 end,
     case when ch.kind = 'community' or ch.ends_at is null then 0
          when now() < ch.ends_at + interval '24 hours' then 0 else 1 end,
     ch.sort, ch.created_at;
$$;
grant execute on function public.community_channel_list(uuid) to authenticated;

create or replace function public.purge_archived_channels()
returns void language sql security definer set search_path = public as $$
  delete from public.community_channels
   where kind <> 'community' and ends_at is not null
     and now() >= ends_at + interval '24 hours' + interval '30 days';
$$;
do $$ begin
  perform cron.schedule('padel-purge-channels', '0 4 * * *', 'select public.purge_archived_channels()');
exception when others then
  raise notice 'pg_cron not available for channel purge — archived channels linger harmlessly.';
end $$;

-- ── Community channels Phase 3: post permissions + organizer console ──
alter table public.communities
  add column if not exists channel_event_post text not null default 'registered'
    check (channel_event_post in ('all','registered','org'));
alter table public.communities
  add column if not exists channel_casual_auto boolean not null default false;

create or replace function public.tg_event_channel()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cid uuid; v_name text; v_ends timestamptz; v_post text;
begin
  if new.organizer_id is null then return new; end if;
  select id, coalesce(channel_event_post, 'registered') into v_cid, v_post
    from public.communities where organizer_id = new.organizer_id limit 1;
  if v_cid is null then return new; end if;
  v_name := trim(both '-' from lower(regexp_replace(coalesce(new.name, 'event'), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then v_name := 'event-' || left(new.id::text, 8); end if;
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    v_name := v_name || '-' || left(new.id::text, 4);
  end if;
  v_ends := (coalesce(new.end_date, new.start_date))::timestamptz + interval '1 day';
  insert into public.community_channels (community_id, name, kind, event_id, ends_at, post, sort)
  values (v_cid, v_name, 'tournament', new.id, v_ends, v_post, 100)
  on conflict (community_id, event_id) do nothing;
  return new;
end $$;

create or replace function public.mm_can_post_channel(p_channel_id uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_uid is null then false
    else exists (
      select 1 from public.community_channels ch
       where ch.id = p_channel_id
         and not (ch.kind <> 'community' and ch.ends_at is not null
                  and now() >= ch.ends_at + interval '24 hours')
         and (
           exists (select 1 from public.communities c
                    where c.id = ch.community_id and (c.organizer_id = p_uid or public._is_admin()))
           or (
             exists (select 1 from public.community_members m
                      where m.community_id = ch.community_id and m.player_id = p_uid)
             and (
               ch.post = 'all'
               or (ch.post = 'registered' and (
                     ch.event_id is null
                     or exists (select 1 from public.tournament_entries te
                                 where te.tournament_id = ch.event_id and te.player_id = p_uid
                                   and te.status <> 'withdrawn'))
               )
             )
           )
         )
    )
  end;
$$;
grant execute on function public.mm_can_post_channel(uuid, uuid) to authenticated;

drop policy if exists "community_chat: member write" on public.community_chat;
create policy "community_chat: member write" on public.community_chat for insert
  with check (
    sender_id = auth.uid()
    and public.mm_can_post_channel(channel_id, auth.uid())
  );

drop function if exists public.community_channel_list(uuid);
create or replace function public.community_channel_list(p_community_id uuid)
returns table(
  id uuid, name text, post text, is_custom boolean, kind text, state text,
  event_id uuid, going int, can_post boolean, preview text, last_at timestamptz
)
language sql stable set search_path = public as $$
  select ch.id, ch.name, ch.post, ch.is_custom, ch.kind,
         case when ch.kind = 'community' or ch.ends_at is null then 'active'
              when now() < ch.ends_at then 'active'
              when now() < ch.ends_at + interval '24 hours' then 'grace'
              else 'archived' end as state,
         ch.event_id,
         coalesce((select count(*)::int from public.tournament_entries te
                    where te.tournament_id = ch.event_id and te.status <> 'withdrawn'), 0) as going,
         public.mm_can_post_channel(ch.id, auth.uid()) as can_post,
         lm.body, lm.created_at
    from public.community_channels ch
    left join lateral (
      select body, created_at from public.community_chat cc
       where cc.channel_id = ch.id order by cc.created_at desc limit 1
    ) lm on true
   where ch.community_id = p_community_id
   order by
     case ch.kind when 'community' then 0 else 1 end,
     case when ch.kind = 'community' or ch.ends_at is null then 0
          when now() < ch.ends_at + interval '24 hours' then 0 else 1 end,
     ch.sort, ch.created_at;
$$;
grant execute on function public.community_channel_list(uuid) to authenticated;

create or replace function public.create_community_channel(p_name text, p_post text default 'all')
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid; v_name text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid limit 1;
  if v_cid is null then return 'You do not run a community.'; end if;
  v_name := trim(both '-' from lower(regexp_replace(coalesce(p_name, ''), '[^a-zA-Z0-9]+', '-', 'g')));
  if v_name = '' then return 'Enter a channel name.'; end if;
  if exists (select 1 from public.community_channels where community_id = v_cid and name = v_name) then
    return 'A channel with that name already exists.';
  end if;
  insert into public.community_channels (community_id, name, post, is_custom, sort)
  values (v_cid, v_name, p_post, true, 50);
  return null;
end $$;

create or replace function public.set_channel_post(p_channel_id uuid, p_post text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if p_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  update public.community_channels ch set post = p_post
   where ch.id = p_channel_id
     and exists (select 1 from public.communities c
                  where c.id = ch.community_id and c.organizer_id = v_uid);
  if not found then return 'Not allowed.'; end if;
  return null;
end $$;

create or replace function public.delete_community_channel(p_channel_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  delete from public.community_channels ch
   where ch.id = p_channel_id and ch.is_custom = true and ch.kind = 'community'
     and exists (select 1 from public.communities c
                  where c.id = ch.community_id and c.organizer_id = v_uid);
  if not found then return 'Only your custom channels can be deleted.'; end if;
  return null;
end $$;

create or replace function public.set_channel_settings(p_event_post text, p_casual_auto boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if p_event_post not in ('all','registered','org') then return 'Invalid permission.'; end if;
  update public.communities
     set channel_event_post = p_event_post,
         channel_casual_auto = coalesce(p_casual_auto, false)
   where organizer_id = v_uid;
  if not found then return 'You do not run a community.'; end if;
  return null;
end $$;

grant execute on function public.create_community_channel(text, text) to authenticated;
grant execute on function public.set_channel_post(uuid, text) to authenticated;
grant execute on function public.delete_community_channel(uuid) to authenticated;
grant execute on function public.set_channel_settings(text, boolean) to authenticated;

create or replace function public.upsert_my_community(
  p_name text, p_handle text default null, p_city text default null, p_about text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_name, '')) = '' then return 'Name required.'; end if;
  insert into public.communities (organizer_id, name, handle, city, about, updated_at)
  values (v_uid, p_name, nullif(btrim(coalesce(p_handle,'')),''),
          nullif(btrim(coalesce(p_city,'')),''), nullif(btrim(coalesce(p_about,'')),''), now())
  on conflict (organizer_id) do update set
    name = excluded.name, handle = excluded.handle,
    city = excluded.city, about = excluded.about, updated_at = now();
  return null;
end $$;
grant execute on function public.upsert_my_community(text, text, text, text) to authenticated;

-- ── Community requests: join-approval + match requests + typed inbox ───────
alter table public.communities add column if not exists approval_required boolean not null default false;

create table if not exists public.community_join_requests (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at   timestamptz not null default now(),
  unique (community_id, player_id)
);
create table if not exists public.community_match_requests (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  note         text,
  status       text not null default 'open' check (status in ('open','resolved')),
  created_at   timestamptz not null default now()
);
create index if not exists idx_join_req_comm on public.community_join_requests (community_id, status);
create index if not exists idx_match_req_comm on public.community_match_requests (community_id, status);
alter table public.community_join_requests  enable row level security;
alter table public.community_match_requests enable row level security;
do $$ begin
  create policy "join_req: member or organizer read" on public.community_join_requests for select
    using (player_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "match_req: member or organizer read" on public.community_match_requests for select
    using (player_id = auth.uid()
           or exists (select 1 from public.communities c
                       where c.id = community_id and (c.organizer_id = auth.uid() or public._is_admin())));
exception when duplicate_object then null; end $$;

create or replace function public.join_community(p_community_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_needs boolean;
begin
  if exists (select 1 from public.community_members
              where community_id = p_community_id and player_id = v_uid) then
    return null;
  end if;
  select approval_required into v_needs from public.communities where id = p_community_id;
  if coalesce(v_needs, false) then
    insert into public.community_join_requests (community_id, player_id, status)
    values (p_community_id, v_uid, 'pending')
    on conflict (community_id, player_id) do update set status = 'pending';
    insert into public.notifications (user_id, type, title, body, data)
    select c.organizer_id, 'admin_community', 'New join request', null,
           jsonb_build_object('community_id', p_community_id, 'member_id', v_uid)
      from public.communities c where c.id = p_community_id;
    return 'requested';
  end if;
  insert into public.community_members (community_id, player_id)
  values (p_community_id, v_uid) on conflict do nothing;
  return null;
end $$;
grant execute on function public.join_community(uuid) to authenticated;

create or replace function public.approve_join_request(p_id uuid, p_approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select jr.*, c.organizer_id into r
    from public.community_join_requests jr
    join public.communities c on c.id = jr.community_id
   where jr.id = p_id;
  if not found then return 'Request not found.'; end if;
  if r.organizer_id <> auth.uid() and not public._is_admin() then return 'Not authorised.'; end if;
  if p_approve then
    insert into public.community_members (community_id, player_id)
    values (r.community_id, r.player_id) on conflict do nothing;
    update public.community_join_requests set status = 'approved' where id = p_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (r.player_id, 'community', 'You''re in!', 'Your join request was approved.',
            jsonb_build_object('community_id', r.community_id));
  else
    update public.community_join_requests set status = 'declined' where id = p_id;
  end if;
  return null;
end $$;
grant execute on function public.approve_join_request(uuid, boolean) to authenticated;

create or replace function public.create_match_request(p_community_id uuid, p_note text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.community_members
                  where community_id = p_community_id and player_id = auth.uid()) then
    return 'Join the community first.';
  end if;
  insert into public.community_match_requests (community_id, player_id, note)
  values (p_community_id, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''));
  insert into public.notifications (user_id, type, title, body, data)
  select c.organizer_id, 'admin_community', 'New match request', left(btrim(coalesce(p_note, '')), 80),
         jsonb_build_object('community_id', p_community_id, 'member_id', auth.uid())
    from public.communities c where c.id = p_community_id;
  return null;
end $$;
grant execute on function public.create_match_request(uuid, text) to authenticated;

create or replace function public.resolve_match_request(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select mr.*, c.organizer_id into r
    from public.community_match_requests mr
    join public.communities c on c.id = mr.community_id
   where mr.id = p_id;
  if not found then return 'Request not found.'; end if;
  if r.organizer_id <> auth.uid() and not public._is_admin() then return 'Not authorised.'; end if;
  update public.community_match_requests set status = 'resolved' where id = p_id;
  insert into public.notifications (user_id, type, title, body, data)
  values (r.player_id, 'community', 'Your organizer is on it',
          'Your match request is being sorted.', jsonb_build_object('community_id', r.community_id));
  return null;
end $$;
grant execute on function public.resolve_match_request(uuid) to authenticated;

create or replace function public.set_community_approval(p_on boolean)
returns text language plpgsql security definer set search_path = public as $$
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  update public.communities set approval_required = coalesce(p_on, false)
   where organizer_id = auth.uid();
  return null;
end $$;
grant execute on function public.set_community_approval(boolean) to authenticated;

create or replace function public.community_inbox_typed()
returns table (kind text, id uuid, member_id uuid, member_name text, avatar_url text,
               preview text, created_at timestamptz, actionable boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then return; end if;
  select id into v_cid from public.communities where organizer_id = auth.uid();
  if v_cid is null then return; end if;
  return query
    select 'match'::text, mr.id, mr.player_id, p.name, p.avatar_url,
           coalesce(mr.note, 'Looking for a match'), mr.created_at, true
      from public.community_match_requests mr join public.profiles p on p.id = mr.player_id
     where mr.community_id = v_cid and mr.status = 'open'
    union all
    select 'join'::text, jr.id, jr.player_id, p.name, p.avatar_url,
           'Wants to join the community', jr.created_at, true
      from public.community_join_requests jr join public.profiles p on p.id = jr.player_id
     where jr.community_id = v_cid and jr.status = 'pending'
    union all
    select 'message'::text, null::uuid, m.member_id, p.name, p.avatar_url,
           last.body, last.created_at, false
      from (select distinct member_id from public.community_messages where community_id = v_cid) m
      join public.profiles p on p.id = m.member_id
      join lateral (
        select body, created_at, sender_role from public.community_messages cm
         where cm.community_id = v_cid and cm.member_id = m.member_id
         order by cm.created_at desc limit 1
      ) last on true
    order by created_at desc;
end $$;
grant execute on function public.community_inbox_typed() to authenticated;

-- Join by handle/code (organizer shares the handle). Case-insensitive, strips a
-- leading "@"; returns {ok, community_id} or {ok:false, error}.
create or replace function public.join_community_by_handle(p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_h text; v_cid uuid;
begin
  v_h := lower(btrim(regexp_replace(coalesce(p_handle, ''), '^@', '')));
  if v_h = '' then
    return jsonb_build_object('ok', false, 'error', 'Enter a community code.');
  end if;
  select id into v_cid
    from public.communities
   where handle is not null and lower(handle) = v_h
   limit 1;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error', 'No community found for that code.');
  end if;
  insert into public.community_members (community_id, player_id)
  values (v_cid, auth.uid())
  on conflict do nothing;
  return jsonb_build_object('ok', true, 'community_id', v_cid);
end $$;
grant execute on function public.join_community_by_handle(text) to authenticated;

create or replace function public.leave_community(p_community_id uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  delete from public.community_members
   where community_id = p_community_id and player_id = auth.uid();
  return null;
end $$;
grant execute on function public.leave_community(uuid) to authenticated;

create or replace function public.toggle_rsvp(p_announcement_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_exists boolean;
begin
  select exists (select 1 from public.announcement_rsvps
                  where announcement_id = p_announcement_id and player_id = auth.uid())
    into v_exists;
  if v_exists then
    delete from public.announcement_rsvps
     where announcement_id = p_announcement_id and player_id = auth.uid();
    return false;
  else
    insert into public.announcement_rsvps (announcement_id, player_id)
    values (p_announcement_id, auth.uid()) on conflict do nothing;
    return true;
  end if;
end $$;
grant execute on function public.toggle_rsvp(uuid) to authenticated;

-- Community post media (Instagram-style feed post): an optional image on each
-- announcement. Public bucket; each user writes only inside their own <uid>/
-- folder. Full notes: supabase/changes/2026-07-29_community_post_media.sql
alter table public.community_announcements add column if not exists image_url text;
insert into storage.buckets (id, name, public)
  values ('community-media', 'community-media', true)
  on conflict (id) do update set public = true;
drop policy if exists "community-media owner write" on storage.objects;
create policy "community-media owner write" on storage.objects
  for all to authenticated
  using (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'community-media' and (storage.foldername(name))[1] = auth.uid()::text);

drop function if exists public.post_announcement(text, text, boolean);
create or replace function public.post_announcement(
  p_title text, p_body text default null, p_pinned boolean default false,
  p_image_url text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_title, '')) = '' then return 'Title required.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return 'Create your community first.'; end if;
  insert into public.community_announcements (community_id, title, body, pinned, image_url)
  values (v_cid, p_title, nullif(btrim(coalesce(p_body,'')),''), coalesce(p_pinned, false),
          nullif(btrim(coalesce(p_image_url,'')),''));
  insert into public.notifications (user_id, type, title, body, data)
  select cm.player_id, 'community', p_title, nullif(btrim(coalesce(p_body,'')),''),
         jsonb_build_object('community_id', v_cid)
    from public.community_members cm where cm.community_id = v_cid;
  return null;
end $$;
grant execute on function public.post_announcement(text, text, boolean, text) to authenticated;

create or replace function public.send_community_message(p_community_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if btrim(coalesce(p_body, '')) = '' then return 'Message required.'; end if;
  if not exists (select 1 from public.community_members
                  where community_id = p_community_id and player_id = auth.uid()) then
    return 'Join the community first.';
  end if;
  insert into public.community_messages (community_id, member_id, sender_role, body)
  values (p_community_id, auth.uid(), 'member', btrim(p_body));
  insert into public.notifications (user_id, type, title, body, data)
  select c.organizer_id, 'admin_community', 'New community message', left(btrim(p_body), 80),
         jsonb_build_object('community_id', p_community_id, 'member_id', auth.uid())
    from public.communities c where c.id = p_community_id;
  return null;
end $$;
grant execute on function public.send_community_message(uuid, text) to authenticated;

create or replace function public.reply_community_message(p_member_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then
    return 'Organizers only.';
  end if;
  if btrim(coalesce(p_body, '')) = '' then return 'Message required.'; end if;
  select id into v_cid from public.communities where organizer_id = v_uid;
  if v_cid is null then return 'No community.'; end if;
  insert into public.community_messages (community_id, member_id, sender_role, body)
  values (v_cid, p_member_id, 'organizer', btrim(p_body));
  insert into public.notifications (user_id, type, title, body, data)
  values (p_member_id, 'community', 'Reply from your organizer', left(btrim(p_body), 80),
          jsonb_build_object('community_id', v_cid));
  return null;
end $$;
grant execute on function public.reply_community_message(uuid, text) to authenticated;

-- ── Announcement likes + comments (2026-07-12) ─────────────────────────────
create table if not exists public.announcement_likes (
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (announcement_id, player_id)
);
create table if not exists public.announcement_comments (
  id              uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.community_announcements(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  body            text not null,
  created_at      timestamptz not null default now()
);
create index if not exists idx_ann_comments on public.announcement_comments (announcement_id, created_at);
alter table public.announcement_likes    enable row level security;
alter table public.announcement_comments enable row level security;
do $$ begin
  create policy "ann_likes: read all" on public.announcement_likes for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_likes: own write" on public.announcement_likes for all
    using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_comments: read all" on public.announcement_comments for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "ann_comments: own insert" on public.announcement_comments for insert
    with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;

create or replace function public.toggle_announcement_like(p_announcement_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_exists boolean;
begin
  select exists (select 1 from public.announcement_likes
                  where announcement_id = p_announcement_id and player_id = auth.uid())
    into v_exists;
  if v_exists then
    delete from public.announcement_likes
     where announcement_id = p_announcement_id and player_id = auth.uid();
    return false;
  else
    insert into public.announcement_likes (announcement_id, player_id)
    values (p_announcement_id, auth.uid()) on conflict do nothing;
    return true;
  end if;
end $$;
grant execute on function public.toggle_announcement_like(uuid) to authenticated;

create or replace function public.add_announcement_comment(p_announcement_id uuid, p_body text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if btrim(coalesce(p_body, '')) = '' then return 'Comment required.'; end if;
  insert into public.announcement_comments (announcement_id, player_id, body)
  values (p_announcement_id, auth.uid(), btrim(p_body));
  return null;
end $$;
grant execute on function public.add_announcement_comment(uuid, text) to authenticated;

create or replace function public.announcement_comments(p_announcement_id uuid)
returns table (id uuid, player_id uuid, name text, avatar_url text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.player_id, p.name, p.avatar_url, c.body, c.created_at
    from public.announcement_comments c
    join public.profiles p on p.id = c.player_id
   where c.announcement_id = p_announcement_id
   order by c.created_at;
$$;
grant execute on function public.announcement_comments(uuid) to authenticated;

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
       where cmb.community_id = v_cid and coalesce(p.level, 0) < 3.5),
    'tier_gold', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce(p.level, 0) >= 3.5 and coalesce(p.level, 0) < 5.0),
    'tier_elite', (
      select count(*) from public.community_members cmb
       join public.profiles p on p.id = cmb.player_id
       where cmb.community_id = v_cid and coalesce(p.level, 0) >= 5.0)
  ) into v_res;
  return v_res;
end $$;
grant execute on function public.organizer_community_stats() to authenticated;

drop function if exists public.community_feed(uuid);
create or replace function public.community_feed(p_community_id uuid)
returns table (id uuid, title text, body text, image_url text, pinned boolean, created_at timestamptz,
               going int, i_going boolean, likes int, i_liked boolean, comments int)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.image_url, a.pinned, a.created_at,
         (select count(*)::int from public.announcement_rsvps r where r.announcement_id = a.id) as going,
         exists (select 1 from public.announcement_rsvps r
                  where r.announcement_id = a.id and r.player_id = auth.uid()) as i_going,
         (select count(*)::int from public.announcement_likes l where l.announcement_id = a.id) as likes,
         exists (select 1 from public.announcement_likes l
                  where l.announcement_id = a.id and l.player_id = auth.uid()) as i_liked,
         (select count(*)::int from public.announcement_comments c where c.announcement_id = a.id) as comments
    from public.community_announcements a
   where a.community_id = p_community_id
   order by a.pinned desc, a.created_at desc;
$$;
grant execute on function public.community_feed(uuid) to authenticated;

-- Mini profile card for one community member: profile fields + played/wins from
-- settled matches + community rank (by rating). Used by the player Members tab.
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
    'elo', p.elo, 'level', p.level, 'city', p.city,
    'hand', p.preferred_hand, 'side', p.preferred_court_side,
    'joined', v_joined, 'played', coalesce(v_played, 0),
    'wins', coalesce(v_wins, 0), 'rank', v_rank)
    into v_res from public.profiles p where p.id = p_player_id;
  return v_res;
end $$;
grant execute on function public.community_member_card(uuid, uuid) to authenticated;

create or replace function public.community_inbox()
returns table (member_id uuid, member_name text, avatar_url text,
               last_body text, last_at timestamptz, last_role text, unanswered boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_cid uuid;
begin
  if public.current_admin_role() <> 'organizer' and not public._is_admin() then return; end if;
  select id into v_cid from public.communities where organizer_id = auth.uid();
  if v_cid is null then return; end if;
  return query
    select m.member_id, p.name, p.avatar_url, last.body, last.created_at, last.sender_role,
           (last.sender_role = 'member')
      from (select distinct member_id from public.community_messages where community_id = v_cid) m
      join public.profiles p on p.id = m.member_id
      join lateral (
        select body, created_at, sender_role from public.community_messages cm
         where cm.community_id = v_cid and cm.member_id = m.member_id
         order by cm.created_at desc limit 1
      ) last on true
     order by last.created_at desc;
end $$;
grant execute on function public.community_inbox() to authenticated;

-- ── Organizer provisioning + court ownership (2026-07-11) ───────────────────
-- Admin-provisioned organizers must reset their temp password on first login.
alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create or replace function public.clear_must_change_password()
returns void language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid();
$$;
grant execute on function public.clear_must_change_password() to authenticated;

-- Courts get an owner + a public flag. Organizer courts (owner set, is_public
-- false) show only to his community; the admin can flip is_public = true to
-- publish to all players. Existing courts default is_public = true.
alter table public.courts
  add column if not exists owner_id uuid references public.profiles(id) on delete set null;
alter table public.courts
  add column if not exists is_public boolean not null default true;
alter table public.courts add column if not exists city text;
create index if not exists idx_courts_owner on public.courts(owner_id);

-- Padel courts are all the same surface — drop the unused, over-constrained
-- surface column (was NOT NULL + a restrictive enum check).
alter table public.courts drop constraint if exists courts_surface_chk;
alter table public.courts drop column if exists surface;

-- Organizers (is_admin = false) can't write to courts directly under RLS, so
-- they manage their own courts through these SECURITY DEFINER helpers.
drop function if exists public.organizer_save_court(uuid, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, text, numeric, boolean);
-- Court location (for Directions via the maps app). Match the live column names.
alter table public.courts add column if not exists lat double precision;
alter table public.courts add column if not exists lng double precision;
alter table public.courts add column if not exists address text;

-- Courts are listed for discovery only — the app never handles court booking or
-- payment, so the hourly price was noise. Dropped 2026-08-02.
-- Signature changed several times (surface, then location, then price) — drop
-- every historical overload so a re-run never leaves a stale one behind.
drop function if exists public.organizer_save_court(uuid, text, text, text, text, numeric, boolean, numeric, numeric, text);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, text, text, numeric, boolean);
drop function if exists public.organizer_save_court(uuid, text, text, text, numeric, boolean);
alter table public.courts drop column if exists price_per_hour;

-- Signature CHANGED (dropped p_price) → the older versions are dropped above.
create or replace function public.organizer_save_court(
  p_id uuid, p_venue text, p_name text, p_area text, p_city text,
  p_indoor boolean,
  p_lat numeric default null, p_lng numeric default null, p_address text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if not public._can_edit('courts') then
    raise exception 'Organizers only';
  end if;
  if p_id is null then
    insert into public.courts (venue_name, name, area, city,
                               indoor, lat, lng, address,
                               is_active, in_maintenance, owner_id, is_public)
    values (p_venue, coalesce(nullif(btrim(p_name), ''), 'Court'), p_area,
            nullif(btrim(coalesce(p_city, '')), ''),
            coalesce(p_indoor, false), p_lat, p_lng,
            nullif(btrim(coalesce(p_address, '')), ''),
            true, false, v_uid, false)
    returning id into v_id;
    return v_id;
  else
    update public.courts set
      venue_name = p_venue,
      name = coalesce(nullif(btrim(p_name), ''), 'Court'),
      area = p_area,
      city = nullif(btrim(coalesce(p_city, '')), ''),
      indoor = coalesce(p_indoor, false),
      lat = p_lat, lng = p_lng, address = nullif(btrim(coalesce(p_address, '')), '')
    where id = p_id and (owner_id = v_uid or public._is_admin());
    return p_id;
  end if;
end $$;
grant execute on function public.organizer_save_court(uuid, text, text, text, text, boolean, numeric, numeric, text) to authenticated;

create or replace function public.organizer_delete_court(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._can_edit('courts') then
    raise exception 'Organizers only';
  end if;
  delete from public.courts
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_delete_court(uuid) to authenticated;

create or replace function public.organizer_set_court_maintenance(p_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._can_edit('courts') then
    raise exception 'Organizers only';
  end if;
  update public.courts set in_maintenance = coalesce(p_on, false)
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_set_court_maintenance(uuid, boolean) to authenticated;

create or replace function public.organizer_set_court_active(p_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._can_edit('courts') then
    raise exception 'Organizers only';
  end if;
  update public.courts set is_active = coalesce(p_on, true)
   where id = p_id and (owner_id = auth.uid() or public._is_admin());
end $$;
grant execute on function public.organizer_set_court_active(uuid, boolean) to authenticated;

-- courts RLS only shows active courts to non-admins, so an organizer's direct
-- select can miss their own (e.g. inactive) courts. Return them via a
-- SECURITY DEFINER RPC + an owner-read policy.
create or replace function public.organizer_courts()
returns setof public.courts
language sql stable security definer set search_path = public as $$
  select * from public.courts
   where owner_id = auth.uid()
   order by created_at desc;
$$;
grant execute on function public.organizer_courts() to authenticated;
do $$ begin
  create policy "courts: owner read own" on public.courts
    for select using (owner_id = auth.uid());
exception when duplicate_object then null; end $$;

-- ── Format Builder + live draw generator (2026-07-12) ──────────────────────
alter table public.tournaments add column if not exists format_spec jsonb;

create table if not exists public.saved_formats (
  id           uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references public.profiles(id) on delete cascade,
  name         text not null,
  spec         jsonb not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_saved_formats_owner on public.saved_formats(organizer_id);
alter table public.saved_formats enable row level security;
do $$ begin
  create policy "saved_formats: owner all" on public.saved_formats for all
    using (organizer_id = auth.uid() or public._is_admin())
    with check (organizer_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

create or replace function public.save_tournament_format(p_tournament_id uuid, p_spec jsonb)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  update public.tournaments
     set format = 'custom', format_spec = p_spec
   where id = p_tournament_id;
  return null;
end $$;
grant execute on function public.save_tournament_format(uuid, jsonb) to authenticated;

alter table public.tournament_matches add column if not exists stage int not null default 0;

create or replace function public._ko_round_name(p_size int)
returns text language sql immutable as $$
  select case p_size when 2 then 'Final' when 4 then 'Semifinal'
                     when 8 then 'Quarterfinal' else 'Round of ' || p_size end;
$$;

create or replace function public._build_ko_round(p_tid uuid, p_stage int, p_round int, p_pairs uuid[])
returns void language plpgsql as $$
declare n int := coalesce(array_length(p_pairs, 1), 0); v_size int := 2; v_slots int;
        i int; e1 uuid; e2 uuid; v_label text;
begin
  if n < 2 then return; end if;
  while v_size < n loop v_size := v_size * 2; end loop;
  v_slots := v_size / 2;
  v_label := public._ko_round_name(v_size);
  for i in 0 .. v_slots - 1 loop
    e1 := p_pairs[i + 1];
    e2 := case when (v_size - i) <= n then p_pairs[v_size - i] else null end;
    insert into public.tournament_matches (tournament_id, bracket, round, slot, entry1, entry2, winner_entry, stage)
    values (p_tid, v_label, p_round, i, e1, e2, case when e2 is null then e1 else null end, p_stage);
  end loop;
end $$;

-- p_random added → drop the old 1-arg version first so the named-arg call isn't
-- ambiguous. p_random true = shuffle the field; false = seed by level (default).
drop function if exists public.generate_from_format(uuid);
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
           ((coalesce(p1.level, 0) + coalesce(p2.level, p1.level, 0)) / 2.0)::float8 as lvl
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
grant execute on function public.generate_from_format(uuid, boolean) to authenticated;

create or replace function public.advance_stage(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_spec jsonb; v_stages jsonb; v_cur_stage int; v_cur_round int; v_kind text;
  v_adv int; quals uuid[]; wins uuid[];
begin
  if not public.owns_tournament(p_tournament_id) then return 'Not authorised.'; end if;
  select format_spec into v_spec from public.tournaments where id = p_tournament_id;
  v_stages := coalesce(v_spec->'stages', '[]'::jsonb);
  select max(stage) into v_cur_stage from public.tournament_matches where tournament_id = p_tournament_id;
  if v_cur_stage is null then return 'Generate the first stage first.'; end if;
  select max(round) into v_cur_round from public.tournament_matches
    where tournament_id = p_tournament_id and stage = v_cur_stage;
  if exists (select 1 from public.tournament_matches
              where tournament_id = p_tournament_id and stage = v_cur_stage
                and round = v_cur_round and winner_entry is null) then
    return 'Finish all matches in the current round first.';
  end if;
  v_kind := v_stages->v_cur_stage->>'kind';

  if v_kind = 'groups' then
    v_adv := coalesce((v_stages->v_cur_stage->'cfg'->>'advance')::int, 2);
    quals := array(
      select pid from (
        select bracket, pid, row_number() over (partition by bracket order by wins desc) rn
          from (
            select bracket, pid, count(*) filter (where won) wins from (
              select bracket, entry1 pid, (winner_entry = entry1) won
                from public.tournament_matches
               where tournament_id = p_tournament_id and stage = v_cur_stage and entry1 is not null
              union all
              select bracket, entry2 pid, (winner_entry = entry2) won
                from public.tournament_matches
               where tournament_id = p_tournament_id and stage = v_cur_stage and entry2 is not null
            ) u group by bracket, pid
          ) s
      ) r where rn <= v_adv order by rn, bracket);
    if v_cur_stage + 1 >= jsonb_array_length(v_stages) then
      return 'Groups done — add a knockout stage to the format to continue.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage + 1, 1, quals);
    return null;

  elsif v_kind in ('roundRobin', 'swiss') then
    v_adv := coalesce((v_stages->v_cur_stage->'cfg'->>'advance')::int, 4);
    quals := array(
      select pid from (
        select pid, count(*) filter (where won) wins from (
          select entry1 pid, (winner_entry = entry1) won from public.tournament_matches
           where tournament_id = p_tournament_id and stage = v_cur_stage and entry1 is not null
          union all
          select entry2 pid, (winner_entry = entry2) won from public.tournament_matches
           where tournament_id = p_tournament_id and stage = v_cur_stage and entry2 is not null
        ) u group by pid order by wins desc
      ) s limit v_adv);
    if v_cur_stage + 1 >= jsonb_array_length(v_stages) then
      return 'Stage done — add a knockout stage to the format to continue.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage + 1, 1, quals);
    return null;

  else
    select array_agg(winner_entry order by slot) into wins
      from public.tournament_matches
     where tournament_id = p_tournament_id and stage = v_cur_stage
       and round = v_cur_round and winner_entry is not null;
    if coalesce(array_length(wins, 1), 0) <= 1 then
      return 'Champion decided — no more rounds.';
    end if;
    perform public._build_ko_round(p_tournament_id, v_cur_stage, v_cur_round + 1, wins);
    return null;
  end if;
end $$;
grant execute on function public.advance_stage(uuid) to authenticated;

-- ============================================================================
-- Tournament results → rating engine (2026-07-17). Tournaments are rated by
-- default (per-event `rated` toggle). finalize_tournament materializes each
-- decided 2v2 match into a completed matches+match_players row and settles it
-- via _settle_rating — same 0–7 engine as normal matches. Idempotent via
-- matches.tournament_match_id (unique) + tournaments.rating_applied.
-- ============================================================================
alter table public.tournaments add column if not exists rated boolean not null default true;
alter table public.tournaments add column if not exists rating_applied boolean not null default false;
alter table public.matches
  add column if not exists tournament_match_id uuid references public.tournament_matches(id) on delete set null;
create unique index if not exists matches_tournament_match_id_key
  on public.matches (tournament_match_id) where tournament_match_id is not null;

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
      (status, match_type, scheduled_at, created_by, is_private, min_elo,
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

  update public.tournaments set rating_applied = true, status = 'completed'
   where id = p_tournament_id;
  return v_n || ' match' || (case when v_n = 1 then '' else 'es' end) || ' rated.';
end $$;
grant execute on function public.finalize_tournament(uuid) to authenticated;

-- Keep the placement counter in step with settled competitive matches (fixes
-- players stuck at 0/5 before _settle_rating incremented placement_played).
update public.profiles
   set placement_played = least(coalesce(competitive_matches, 0), 5)
 where coalesce(placement_played, 0) < least(coalesce(competitive_matches, 0), 5);

-- ============================================================
-- Self-service account deletion (Google Play requirement).
-- A signed-in user permanently deletes their own account + data. Runs as the
-- definer so it can remove the auth.users row (which cascades profiles and
-- everything that cascades from profiles). Because the live schema has several
-- NOT NULL foreign keys straight to auth.users (matches.created_by,
-- match_players.player_id, orders.player_id, tournament_entries.player_id),
-- those are cleared first, in dependency order, or the auth delete is blocked.
-- Tournaments / courts the user owns are ON DELETE SET NULL (kept, de-identified).
-- ============================================================
-- delete_account_self now lives in the privacy/retention block appended at
-- the end of this file (2026-08-01): orders are anonymised, not deleted.

-- ── Messages inbox + community channel unread (2026-07-30) ───────────────
-- dm_inbox(): every conversation the caller is in that has a message, with the
-- other player, last message, and an unread count off the type='message'
-- notifications. Drives the standalone Messages inbox.
-- NOTE: superseded further down (2026-08-11 dm avatars), which ADDS an
-- other_avatar column. The drop is what keeps this file re-runnable:
-- create or replace cannot change a return type (42P13).
drop function if exists public.dm_inbox();
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
         lm.text,
         lm.sent_at,
         coalesce((
           select count(*)::int from public.notifications n
            where n.user_id = auth.uid()
              and n.type = 'message'
              and n.read = false
              and n.data->>'conversation_id' = c.id::text), 0)
    from public.conversations c
    join public.profiles other
      on other.id = case when c.player_a = auth.uid() then c.player_b else c.player_a end
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- ============================================================================
-- Match tickets (2026-08-03): an automatic group thread per match — the four
-- players, their phone numbers, one place to sort the ride and the balls.
--
-- Membership derives from match_players and open/closed derives from the
-- match, so nothing is stored twice, join_match/leave_match are untouched and
-- no cron job is needed. Phone numbers are served only by ticket_roster(),
-- only to members, only while the ticket is open.
-- Full notes: supabase/changes/2026-08-03_match_tickets.sql
-- ============================================================================

-- ── tables ────────────────────────────────────────────────────────────────

create table if not exists public.match_tickets (
  id         uuid primary key default gen_random_uuid(),
  match_id   uuid not null unique references public.matches(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.ticket_messages (
  id        uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.match_tickets(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  text      text not null,
  sent_at   timestamptz not null default now()
);
create index if not exists idx_ticket_messages
  on public.ticket_messages (ticket_id, sent_at);

-- Read cursor per player, same pattern as channel_reads.
create table if not exists public.ticket_reads (
  ticket_id    uuid not null references public.match_tickets(id) on delete cascade,
  player_id    uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (ticket_id, player_id)
);

-- ── membership + lifecycle helpers ────────────────────────────────────────

-- SECURITY DEFINER: these are called from RLS policies, so they must see
-- match_players regardless of the caller's own row-level visibility.
create or replace function public._ticket_member(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1
      from public.match_tickets t
      join public.match_players mp on mp.match_id = t.match_id
     where t.id = p_ticket
       and mp.player_id = auth.uid());
$$;

-- Open until 24h after the scheduled start; a cancelled match closes at once.
create or replace function public._ticket_open(p_ticket uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1
      from public.match_tickets t
      join public.matches m on m.id = t.match_id
     where t.id = p_ticket
       and m.status <> 'cancelled'
       and now() < m.scheduled_at + interval '24 hours');
$$;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.match_tickets enable row level security;
drop policy if exists "ticket: member read" on public.match_tickets;
create policy "ticket: member read" on public.match_tickets
  for select using (public._ticket_member(id));
grant select on public.match_tickets to authenticated;

alter table public.ticket_messages enable row level security;
drop policy if exists "ticket msg: member read" on public.ticket_messages;
create policy "ticket msg: member read" on public.ticket_messages
  for select using (public._ticket_member(ticket_id));
-- Posting needs an OPEN ticket: a closed thread is read-only, not gone.
drop policy if exists "ticket msg: member send" on public.ticket_messages;
create policy "ticket msg: member send" on public.ticket_messages
  for insert with check (
    sender_id = auth.uid()
    and public._ticket_member(ticket_id)
    and public._ticket_open(ticket_id));
grant select, insert on public.ticket_messages to authenticated;

alter table public.ticket_reads enable row level security;
drop policy if exists "ticket reads: own" on public.ticket_reads;
create policy "ticket reads: own" on public.ticket_reads
  for all using (player_id = auth.uid()) with check (player_id = auth.uid());
grant select, insert, update on public.ticket_reads to authenticated;

-- ── the ticket opens itself ───────────────────────────────────────────────

create or replace function public.open_match_ticket()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.match_tickets (match_id)
  values (new.id)
  on conflict (match_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_open_match_ticket on public.matches;
create trigger trg_open_match_ticket
  after insert on public.matches
  for each row
  execute function public.open_match_ticket();

-- Backfill: every match that still has a live ticket window gets one, so the
-- feature is not empty for people with matches already booked.
insert into public.match_tickets (match_id)
select m.id from public.matches m
 where m.status <> 'cancelled'
   and now() < m.scheduled_at + interval '24 hours'
on conflict (match_id) do nothing;

-- ── inbox ─────────────────────────────────────────────────────────────────

-- Every ticket the caller is in: the match line, the last message, and how
-- many they have not read. Newest activity first.
create or replace function public.ticket_inbox()
returns table (
  ticket_id    uuid,
  match_id     uuid,
  is_open      boolean,
  match_type   text,
  scheduled_at timestamptz,
  venue        text,
  court        text,
  last_text    text,
  last_at      timestamptz,
  last_sender  text,
  unread       int
)
language sql stable security definer set search_path = public as $$
  select
    t.id,
    m.id,
    (m.status <> 'cancelled' and now() < m.scheduled_at + interval '24 hours'),
    m.match_type,
    m.scheduled_at,
    c.venue_name,
    c.name,
    lm.text,
    lm.sent_at,
    lp.name,
    (select count(*)::int
       from public.ticket_messages x
      where x.ticket_id = t.id
        and x.sender_id <> auth.uid()
        and x.sent_at > coalesce(r.last_read_at, 'epoch'::timestamptz))
  from public.match_tickets t
  join public.matches m       on m.id = t.match_id
  join public.match_players me on me.match_id = m.id and me.player_id = auth.uid()
  left join public.courts c   on c.id = m.court_id
  left join public.ticket_reads r
         on r.ticket_id = t.id and r.player_id = auth.uid()
  left join lateral (
    select x.text, x.sent_at, x.sender_id
      from public.ticket_messages x
     where x.ticket_id = t.id
     order by x.sent_at desc
     limit 1
  ) lm on true
  left join public.profiles lp on lp.id = lm.sender_id
  order by coalesce(lm.sent_at, t.created_at) desc;
$$;
grant execute on function public.ticket_inbox() to authenticated;

-- ── roster (the phone-number boundary) ────────────────────────────────────

-- The four players. Phone numbers are returned ONLY to a member of the
-- ticket, and ONLY while it is open — a closed ticket hides them again, which
-- is what the thread promises its members.
--
-- SUPERSEDED further down (2026-08-10 number requests), which adds a
-- share_state column. The drop is what makes this file re-runnable once that
-- version is live: `create or replace` cannot change a function's return type,
-- so without it a second run dies here with 42P13.
drop function if exists public.ticket_roster(uuid);
create or replace function public.ticket_roster(p_ticket uuid)
returns table (
  player_id  uuid,
  name       text,
  username   text,
  avatar_url text,
  team       text,
  level      numeric,
  is_host    boolean,
  is_me      boolean,
  phone      text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_open boolean;
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
    p.level,
    (m.created_by = p.id),
    (p.id = auth.uid()),
    case when v_open then p.phone else null end
  from public.match_tickets t
  join public.matches m        on m.id = t.match_id
  join public.match_players mp on mp.match_id = m.id
  join public.profiles p       on p.id = mp.player_id
  where t.id = p_ticket
  order by mp.team, (m.created_by = p.id) desc, p.name;
end $$;
grant execute on function public.ticket_roster(uuid) to authenticated;

-- ── read cursor ───────────────────────────────────────────────────────────

create or replace function public.mark_ticket_read(p_ticket uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if not public._ticket_member(p_ticket) then
    return;
  end if;
  insert into public.ticket_reads (ticket_id, player_id, last_read_at)
  values (p_ticket, auth.uid(), now())
  on conflict (ticket_id, player_id)
  do update set last_read_at = now();
end $$;
grant execute on function public.mark_ticket_read(uuid) to authenticated;

-- Total unread across every ticket — feeds the Home chat badge alongside the
-- existing DM count.
create or replace function public.ticket_unread_total()
returns int language sql stable security definer
set search_path = public as $$
  select coalesce(sum(u.unread), 0)::int from public.ticket_inbox() u;
$$;
grant execute on function public.ticket_unread_total() to authenticated;

-- ── realtime ──────────────────────────────────────────────────────────────
-- Live messages in the thread, same as direct_messages.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'ticket_messages'
  ) then
    alter publication supabase_realtime add table public.ticket_messages;
  end if;
end $$;

-- Per (player, community) last-read cursor for the community channels, so the
-- Home community card can flag unread group-chat activity.
create table if not exists public.community_reads (
  player_id    uuid not null references public.profiles(id)    on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (player_id, community_id)
);
alter table public.community_reads enable row level security;
do $$ begin
  create policy "community_reads: self" on public.community_reads
    for all using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select, insert, update on public.community_reads to authenticated;

create or replace function public.mark_community_read(p_community_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.community_reads (player_id, community_id, last_read_at)
  values (auth.uid(), p_community_id, now())
  on conflict (player_id, community_id)
  do update set last_read_at = excluded.last_read_at;
$$;
grant execute on function public.mark_community_read(uuid) to authenticated;

-- Per-CHANNEL read cursor (supersedes the community-level badge math above).
-- community_reads / mark_community_read stay defined but are vestigial;
-- community_unread_count is redefined below to aggregate per-channel cursors.
create or replace function public.mark_community_read(p_community_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.community_reads (player_id, community_id, last_read_at)
  values (auth.uid(), p_community_id, now())
  on conflict (player_id, community_id)
  do update set last_read_at = excluded.last_read_at;
$$;
grant execute on function public.mark_community_read(uuid) to authenticated;

create table if not exists public.channel_reads (
  player_id    uuid not null references public.profiles(id)          on delete cascade,
  channel_id   uuid not null references public.community_channels(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (player_id, channel_id)
);
alter table public.channel_reads enable row level security;
do $$ begin
  create policy "channel_reads: self" on public.channel_reads
    for all using (player_id = auth.uid()) with check (player_id = auth.uid());
exception when duplicate_object then null; end $$;
grant select, insert, update on public.channel_reads to authenticated;

create or replace function public.mark_channel_read(p_channel_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.channel_reads (player_id, channel_id, last_read_at)
  values (auth.uid(), p_channel_id, now())
  on conflict (player_id, channel_id)
  do update set last_read_at = excluded.last_read_at;
$$;
grant execute on function public.mark_channel_read(uuid) to authenticated;

create or replace function public.community_channel_unreads(p_community_id uuid)
returns table (channel_id uuid, unread int)
language sql stable security definer set search_path = public as $$
  select ch.id,
         (select count(*)::int
            from public.community_chat cc
           where cc.channel_id = ch.id
             and cc.sender_id is distinct from auth.uid()
             and cc.created_at > coalesce(
               (select r.last_read_at from public.channel_reads r
                 where r.player_id = auth.uid() and r.channel_id = ch.id),
               (select m.joined_at from public.community_members m
                 where m.player_id = auth.uid() and m.community_id = p_community_id),
               now()))
    from public.community_channels ch
   where ch.community_id = p_community_id;
$$;
grant execute on function public.community_channel_unreads(uuid) to authenticated;

create or replace function public.community_unread_count(p_community_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(u.unread), 0)::int
    from public.community_channel_unreads(p_community_id) u;
$$;
grant execute on function public.community_unread_count(uuid) to authenticated;

-- Reload PostgREST schema cache so new FK constraints are visible immediately.
notify pgrst, 'reload schema';


-- ============================================================================
-- SEASONAL LEADERBOARDS + REWARDS  (2026-08-01)
--
-- An app-wide season with its own points engine, reward brackets and standings.
-- Season points are EARNED SERVER-SIDE only:
--   • every settled ranked match  → _award_season_points (win / loss / streak /
--     upset), called from _settle_rating so it is idempotent per match;
--   • every finalized tournament  → title / podium points, idempotent per event;
--   • a super admin may add a manual adjustment (audit trail + player notice).
-- Rating is untouched — this is a parallel, cosmetic-but-rewarded ladder.
--
-- Season ownership is SUPER ADMIN only (every admin_* RPC below guards on
-- _is_admin()). Club/community ladders are deliberately NOT part of this change.
--
-- Safe to re-run.
-- ============================================================================

-- ── seasons ─────────────────────────────────────────────────────────────────
create table if not exists public.seasons (
  id          uuid primary key default gen_random_uuid(),
  no          int  not null,
  name        text not null,
  starts_on   date not null,
  ends_on     date not null,
  status      text not null default 'scheduled',  -- scheduled | live | ended
  published   boolean not null default false,
  frozen      boolean not null default false,
  paid_out    boolean not null default false,
  region      text,
  champion_id uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
-- drift-safe: a pre-existing table skips the create above, so alter every column
alter table public.seasons add column if not exists no          int;
alter table public.seasons add column if not exists name        text;
alter table public.seasons add column if not exists starts_on   date;
alter table public.seasons add column if not exists ends_on     date;
alter table public.seasons add column if not exists status      text not null default 'scheduled';
alter table public.seasons add column if not exists published   boolean not null default false;
alter table public.seasons add column if not exists frozen      boolean not null default false;
alter table public.seasons add column if not exists paid_out    boolean not null default false;
alter table public.seasons add column if not exists region      text;
alter table public.seasons add column if not exists champion_id uuid references public.profiles(id) on delete set null;
alter table public.seasons add column if not exists created_at  timestamptz not null default now();

alter table public.seasons drop constraint if exists seasons_status_chk;
alter table public.seasons add constraint seasons_status_chk
  check (status in ('scheduled','live','ended'));

create unique index if not exists seasons_no_key on public.seasons (no);
-- at most one live season at a time
create unique index if not exists seasons_one_live_key
  on public.seasons ((status)) where status = 'live';

-- ── points engine: what earns season points ─────────────────────────────────
create table if not exists public.season_rules (
  id        uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  code      text not null,   -- win | loss | tour_win | tour_podium | streak | upset
  label     text not null,
  pts       int  not null default 0,
  note      text,
  icon      text,
  sort      int  not null default 0
);
create unique index if not exists season_rules_code_key
  on public.season_rules (season_id, code);

-- ── reward brackets: rank range → what those players win ────────────────────
create table if not exists public.season_brackets (
  id        uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  rank_from int  not null,
  rank_to   int  not null,
  label     text not null,
  short     text,
  icon      text,
  color     text,
  prize     text,
  extras    text[] not null default '{}',
  budget    int  not null default 0
);
create index if not exists idx_season_brackets_season
  on public.season_brackets (season_id, rank_from);

-- ── the ledger: every point ever awarded (append-only) ──────────────────────
create table if not exists public.season_points (
  id            uuid primary key default gen_random_uuid(),
  season_id     uuid not null references public.seasons(id) on delete cascade,
  player_id     uuid not null references public.profiles(id) on delete cascade,
  rule_code     text not null,
  pts           int  not null,
  match_id      uuid references public.matches(id) on delete cascade,
  tournament_id uuid references public.tournaments(id) on delete cascade,
  reason        text,          -- manual adjustments only (audit trail)
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);
-- Voided entries stay in the ledger for the audit trail but stop counting
-- toward the standings (admin_void_season_points, below).
alter table public.season_points add column if not exists voided      boolean not null default false;
alter table public.season_points add column if not exists void_reason text;
alter table public.season_points add column if not exists voided_by   uuid references public.profiles(id);
alter table public.season_points add column if not exists voided_at   timestamptz;
create index if not exists idx_season_points_board
  on public.season_points (season_id, player_id);
-- idempotency: one row per (player, rule) per source event
create unique index if not exists season_points_match_key
  on public.season_points (season_id, player_id, rule_code, match_id)
  where match_id is not null;
create unique index if not exists season_points_tournament_key
  on public.season_points (season_id, player_id, rule_code, tournament_id)
  where tournament_id is not null;

-- ── weekly rank snapshots — the ONLY source of the "places moved" trend ─────
create table if not exists public.season_rank_snapshots (
  season_id uuid not null references public.seasons(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  taken_on  date not null default current_date,
  rank      int  not null,
  pts       int  not null,
  primary key (season_id, player_id, taken_on)
);

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Seasons/rules/brackets are public reference data once published; the board
-- itself is served by SECURITY DEFINER RPCs, so the ledger stays read-own-row.
alter table public.seasons               enable row level security;
alter table public.season_rules          enable row level security;
alter table public.season_brackets       enable row level security;
alter table public.season_points         enable row level security;
alter table public.season_rank_snapshots enable row level security;

do $$ begin
  create policy "seasons: readable" on public.seasons for select
    using (published or public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "season_rules: readable" on public.season_rules for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "season_brackets: readable" on public.season_brackets for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "season_points: own or admin" on public.season_points for select
    using (player_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "season_snapshots: own or admin" on public.season_rank_snapshots for select
    using (player_id = auth.uid() or public._is_admin());
exception when duplicate_object then null; end $$;

grant select on public.seasons, public.season_rules, public.season_brackets,
                public.season_points, public.season_rank_snapshots to authenticated;

-- ============================================================================
-- Defaults handed to a brand-new season (the design's numbers).
-- ============================================================================
create or replace function public._seed_season_defaults(p_season_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.season_rules (season_id, code, label, pts, note, icon, sort) values
    (p_season_id, 'win',         'Competitive win',    30,  'Per confirmed win',                'check',  1),
    (p_season_id, 'loss',        'Competitive loss',   8,   'Participation points',             'dash',   2),
    (p_season_id, 'tour_win',    'Tournament title',   250, 'Winning pair, per event',          'trophy', 3),
    (p_season_id, 'tour_podium', 'Tournament podium',  120, 'Finalists & semi-finalists',       'medal',  4),
    (p_season_id, 'streak',      'Win streak (3+)',    15,  'Bonus per extra win in a streak',  'fire',   5),
    (p_season_id, 'upset',       'Upset bonus',        20,  'Beating a stronger pair',          'bolt',   6)
  on conflict (season_id, code) do nothing;

  insert into public.season_brackets
    (season_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget) values
    (p_season_id, 1, 1,  'Season Champion', 'Champion', 'crown',  'gold',
       'EGP 5,000 cash',
       array['Engraved champion trophy','Champion badge (permanent)','Free entry — all next-season events'], 5000),
    (p_season_id, 2, 3,  'Podium Finish',   'Podium',   'medal',  'silver',
       'EGP 1,500 store credit',
       array['Podium badge','Free entry — 2 next-season events'], 3000),
    (p_season_id, 4, 10, 'Top 10',          'Top 10',   'trophy', 'primary',
       'EGP 750 gear voucher',
       array['Top 10 badge','Priority tournament seeding'], 5250),
    (p_season_id, 11, 25,'Top 25',          'Top 25',   'star',   'bronzegold',
       '20% store discount',
       array['Season badge'], 2200),
    (p_season_id, 26, 50,'Top 50',          'Top 50',   'shield', 'inksoft',
       'Season participant badge',
       array['Entered into the end-of-season raffle'], 0);
end $$;

-- ============================================================================
-- _award_season_points — called from _settle_rating with the pre-match ratings
-- still in place. Awards win/loss to everyone in the match, plus a streak bonus
-- (3+ consecutive wins) and an upset bonus (beat a pair rated 0.5+ above yours).
-- Idempotent: the partial unique index swallows a second call for the same match.
-- ============================================================================
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

  select avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'a'),
         avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'b')
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

-- ============================================================================
-- _settle_rating — UNCHANGED maths. The only edit is the _award_season_points
-- call, placed before the rating loop so the season engine still sees the
-- PRE-match ratings (that is what the upset bonus is measured against).
-- ============================================================================
-- ============================================================================
-- Tournament title / podium points. Derived from the winners bracket: the
-- highest round is the final (champion + runner-up), the round before it the
-- semis (their losers complete the podium). Idempotent per (player, rule, event).
-- ============================================================================
create or replace function public._award_tournament_season_points(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid; v_frozen boolean; v_title int; v_podium int;
  v_final_round int; f record; m record;
  v_champ uuid; v_runner uuid;
begin
  select s.id, s.frozen into v_sid, v_frozen
    from public.seasons s where s.status = 'live' limit 1;
  if v_sid is null or v_frozen then return; end if;

  select coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_win'), 0),
         coalesce((select pts from public.season_rules where season_id = v_sid and code = 'tour_podium'), 0)
    into v_title, v_podium;

  select max(tm.round) into v_final_round
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.winner_entry is not null;
  if v_final_round is null then return; end if;

  -- the final: champion + runner-up
  select tm.entry1, tm.entry2, tm.winner_entry into f
    from public.tournament_matches tm
   where tm.tournament_id = p_tournament_id
     and coalesce(tm.bracket, 'wb') in ('wb', 'gf')
     and tm.round = v_final_round and tm.winner_entry is not null
   order by tm.slot limit 1;
  if not found then return; end if;

  v_champ  := f.winner_entry;
  v_runner := case when f.winner_entry = f.entry1 then f.entry2 else f.entry1 end;

  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_win', v_title, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_champ and v.pid is not null
  on conflict do nothing;

  -- podium: the runner-up plus everyone who lost a semi-final
  insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
  select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
    from public.tournament_entries e,
         lateral (values (e.player_id), (e.partner_id)) as v(pid)
   where e.id = v_runner and v.pid is not null
  on conflict do nothing;

  for m in
    select tm.entry1, tm.entry2, tm.winner_entry
      from public.tournament_matches tm
     where tm.tournament_id = p_tournament_id
       and coalesce(tm.bracket, 'wb') = 'wb'
       and tm.round = v_final_round - 1
       and tm.winner_entry is not null
  loop
    insert into public.season_points (season_id, player_id, rule_code, pts, tournament_id)
    select v_sid, pid, 'tour_podium', v_podium, p_tournament_id
      from public.tournament_entries e,
           lateral (values (e.player_id), (e.partner_id)) as v(pid)
     where e.id = (case when m.winner_entry = m.entry1 then m.entry2 else m.entry1 end)
       and v.pid is not null
    on conflict do nothing;
  end loop;
end $$;

-- finalize_tournament — unchanged except the season-points call at the end.
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
      (status, match_type, scheduled_at, created_by, is_private, min_elo,
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
grant execute on function public.finalize_tournament(uuid) to authenticated;

-- ============================================================================
-- Standings. One shared builder — the player board and the admin console read
-- the same ranking so a manual adjustment moves both at once.
--   rank  : points desc, then name
--   trend : places moved since the newest snapshot at least 7 days old
-- ============================================================================
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
           coalesce(p.tier, 'bronze') as tier, a.pts, a.played
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
grant execute on function public.season_standings(uuid) to authenticated;

-- Freeze today's ranks so next week's board can show a real trend. Run weekly
-- (pg_cron below) or from the console; re-running the same day is a no-op.
create or replace function public.snapshot_season_ranks()
returns int language plpgsql security definer set search_path = public as $$
declare v_sid uuid; v_n int := 0;
begin
  select id into v_sid from public.seasons where status = 'live' limit 1;
  if v_sid is null then return 0; end if;
  insert into public.season_rank_snapshots (season_id, player_id, taken_on, rank, pts)
  select v_sid, s.player_id, current_date, s.rank, s.pts
    from public.season_standings(v_sid) s
  on conflict (season_id, player_id, taken_on) do update
    set rank = excluded.rank, pts = excluded.pts;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.snapshot_season_ranks() to authenticated;

do $$ begin
  perform cron.schedule('padel-season-snapshot', '0 2 * * 1',
    'select public.snapshot_season_ranks()');
exception when others then
  raise notice 'pg_cron not available — season trend snapshots must be taken manually.';
end $$;

-- ============================================================================
-- Player-facing: everything the leaderboard screen needs in one round trip.
-- Returns null when there is no published live season (the Home card hides).
-- ============================================================================
create or replace function public.season_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_s record; v_board jsonb; v_me jsonb; v_rules jsonb; v_brackets jsonb;
  v_days int; v_progress numeric; v_span int;
begin
  select * into v_s from public.seasons
   where status = 'live' and published order by starts_on desc limit 1;
  if not found then return null; end if;

  v_days := greatest(0, v_s.ends_on - current_date);
  v_span := greatest(1, v_s.ends_on - v_s.starts_on);
  v_progress := greatest(0, least(1, (current_date - v_s.starts_on)::numeric / v_span));

  select jsonb_agg(jsonb_build_object(
           'rank', st.rank, 'player_id', st.player_id, 'name', st.name,
           'avatar_url', st.avatar_url, 'tier', st.tier, 'pts', st.pts,
           'played', st.played, 'trend', st.trend,
           'me', st.player_id = v_uid) order by st.rank)
    into v_board
    from public.season_standings(v_s.id) st;

  select e into v_me
    from jsonb_array_elements(coalesce(v_board, '[]'::jsonb)) e
   where (e->>'player_id')::uuid = v_uid;

  select jsonb_agg(jsonb_build_object(
           'code', code, 'label', label, 'pts', pts, 'note', note, 'icon', icon)
         order by sort, code)
    into v_rules from public.season_rules where season_id = v_s.id;

  select jsonb_agg(jsonb_build_object(
           'id', id, 'rank_from', rank_from, 'rank_to', rank_to, 'label', label,
           'short', coalesce(short, label), 'icon', icon, 'color', color,
           'prize', prize, 'extras', to_jsonb(extras), 'budget', budget)
         order by rank_from)
    into v_brackets from public.season_brackets where season_id = v_s.id;

  return jsonb_build_object(
    'season', jsonb_build_object(
      'id', v_s.id, 'no', v_s.no, 'name', v_s.name,
      'starts_on', v_s.starts_on, 'ends_on', v_s.ends_on,
      'days_left', v_days, 'progress', round(v_progress, 4),
      'frozen', v_s.frozen, 'region', v_s.region),
    'me', v_me,
    'board', coalesce(v_board, '[]'::jsonb),
    'rules', coalesce(v_rules, '[]'::jsonb),
    'brackets', coalesce(v_brackets, '[]'::jsonb));
end $$;
grant execute on function public.season_overview() to authenticated;

-- ============================================================================
-- Admin console (SUPER ADMIN only).
-- ============================================================================
create or replace function public.admin_season_console(p_season_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_s record; v_seasons jsonb; v_rules jsonb; v_brackets jsonb; v_board jsonb;
  v_days int; v_progress numeric; v_span int; v_matches int;
begin
  if not public._is_admin() then return jsonb_build_object('error', 'Not authorised.'); end if;

  select jsonb_agg(jsonb_build_object(
           'id', s.id, 'no', s.no, 'name', s.name, 'status', s.status,
           'starts_on', s.starts_on, 'ends_on', s.ends_on,
           'published', s.published, 'frozen', s.frozen, 'paid_out', s.paid_out,
           'champion', (select p.name from public.profiles p where p.id = s.champion_id),
           'ranked', (select count(distinct sp.player_id)::int
                        from public.season_points sp
                       where sp.season_id = s.id and not coalesce(sp.voided, false)))
         order by s.no desc)
    into v_seasons from public.seasons s;

  select * into v_s from public.seasons
   where id = coalesce(p_season_id, (select id from public.seasons where status = 'live' limit 1),
                       (select id from public.seasons order by no desc limit 1));
  if not found then
    return jsonb_build_object('seasons', coalesce(v_seasons, '[]'::jsonb), 'season', null);
  end if;

  v_days := greatest(0, v_s.ends_on - current_date);
  v_span := greatest(1, v_s.ends_on - v_s.starts_on);
  v_progress := greatest(0, least(1, (current_date - v_s.starts_on)::numeric / v_span));
  select count(distinct sp.match_id)::int into v_matches
    from public.season_points sp
   where sp.season_id = v_s.id and sp.match_id is not null
     and not coalesce(sp.voided, false);

  select jsonb_agg(jsonb_build_object(
           'code', code, 'label', label, 'pts', pts, 'note', note, 'icon', icon)
         order by sort, code)
    into v_rules from public.season_rules where season_id = v_s.id;

  select jsonb_agg(jsonb_build_object(
           'id', id, 'rank_from', rank_from, 'rank_to', rank_to, 'label', label,
           'short', coalesce(short, label), 'icon', icon, 'color', color,
           'prize', prize, 'extras', to_jsonb(extras), 'budget', budget)
         order by rank_from)
    into v_brackets from public.season_brackets where season_id = v_s.id;

  select jsonb_agg(jsonb_build_object(
           'rank', st.rank, 'player_id', st.player_id, 'name', st.name,
           'avatar_url', st.avatar_url, 'tier', st.tier, 'pts', st.pts,
           'played', st.played, 'trend', st.trend) order by st.rank)
    into v_board from public.season_standings(v_s.id) st;

  return jsonb_build_object(
    'seasons', coalesce(v_seasons, '[]'::jsonb),
    'season', jsonb_build_object(
      'id', v_s.id, 'no', v_s.no, 'name', v_s.name, 'status', v_s.status,
      'starts_on', v_s.starts_on, 'ends_on', v_s.ends_on,
      'published', v_s.published, 'frozen', v_s.frozen, 'paid_out', v_s.paid_out,
      'region', v_s.region, 'days_left', v_days, 'progress', round(v_progress, 4),
      'ranked', jsonb_array_length(coalesce(v_board, '[]'::jsonb)),
      'matches', coalesce(v_matches, 0)),
    'rules', coalesce(v_rules, '[]'::jsonb),
    'brackets', coalesce(v_brackets, '[]'::jsonb),
    'standings', coalesce(v_board, '[]'::jsonb));
end $$;
grant execute on function public.admin_season_console(uuid) to authenticated;

create or replace function public.admin_create_season(
  p_name text, p_starts date, p_ends date, p_copy_from uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_no int; v_id uuid; v_status text;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if p_name is null or btrim(p_name) = '' then return 'Name the season.'; end if;
  if p_ends <= p_starts then return 'The season must end after it starts.'; end if;

  select coalesce(max(no), 0) + 1 into v_no from public.seasons;
  -- goes live immediately only if nothing else is live and it has already started
  v_status := case
    when p_starts <= current_date
     and not exists (select 1 from public.seasons where status = 'live') then 'live'
    else 'scheduled' end;

  insert into public.seasons (no, name, starts_on, ends_on, status, published)
  values (v_no, btrim(p_name), p_starts, p_ends, v_status, false)
  returning id into v_id;

  if p_copy_from is not null then
    insert into public.season_rules (season_id, code, label, pts, note, icon, sort)
    select v_id, code, label, pts, note, icon, sort
      from public.season_rules where season_id = p_copy_from;
    insert into public.season_brackets
      (season_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget)
    select v_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget
      from public.season_brackets where season_id = p_copy_from;
  else
    perform public._seed_season_defaults(v_id);
  end if;
  return null;
end $$;
grant execute on function public.admin_create_season(text, date, date, uuid) to authenticated;

create or replace function public.admin_set_season_flag(
  p_season_id uuid, p_flag text, p_value boolean)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if p_flag = 'published' then
    update public.seasons set published = p_value where id = p_season_id;
  elsif p_flag = 'frozen' then
    update public.seasons set frozen = p_value where id = p_season_id;
  else
    return 'Unknown flag.';
  end if;
  return null;
end $$;
grant execute on function public.admin_set_season_flag(uuid, text, boolean) to authenticated;

-- Close & pay out: ends the season, stamps the champion, notifies everyone who
-- finished inside a reward bracket, and promotes the next scheduled season.
create or replace function public.admin_close_season(p_season_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare v_champ uuid; v_n int := 0; v_next uuid; v_name text;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  select name into v_name from public.seasons where id = p_season_id;
  if v_name is null then return 'Season not found.'; end if;

  select st.player_id into v_champ
    from public.season_standings(p_season_id) st where st.rank = 1;

  update public.seasons
     set status = 'ended', frozen = true, paid_out = true, champion_id = v_champ
   where id = p_season_id;

  insert into public.notifications (user_id, type, title, body, data)
  select st.player_id, 'season',
         v_name || ' — you finished #' || st.rank,
         'You placed in ' || b.label || '. Reward: ' || coalesce(b.prize, 'see the app') ||
         '. It will be issued within 7 days.',
         jsonb_build_object('season_id', p_season_id, 'rank', st.rank, 'bracket', b.label)
    from public.season_standings(p_season_id) st
    join public.season_brackets b
      on b.season_id = p_season_id and st.rank between b.rank_from and b.rank_to;
  get diagnostics v_n = row_count;

  select id into v_next from public.seasons
   where status = 'scheduled' order by starts_on limit 1;
  if v_next is not null then
    update public.seasons set status = 'live' where id = v_next;
  end if;

  return 'Season closed — ' || v_n || ' player' || (case when v_n = 1 then '' else 's' end)
         || ' in a reward bracket were notified.';
end $$;
grant execute on function public.admin_close_season(uuid) to authenticated;

create or replace function public.admin_save_season_rule(
  p_season_id uuid, p_code text, p_pts int, p_note text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  update public.season_rules set pts = greatest(0, coalesce(p_pts, 0)), note = p_note
   where season_id = p_season_id and code = p_code;
  if not found then return 'Rule not found.'; end if;
  return null;
end $$;
grant execute on function public.admin_save_season_rule(uuid, text, int, text) to authenticated;

create or replace function public.admin_save_season_bracket(
  p_id uuid, p_season_id uuid, p_rank_from int, p_rank_to int, p_label text,
  p_prize text, p_extras text[], p_budget int,
  p_icon text default 'shield', p_color text default 'inksoft', p_short text default null)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if p_label is null or btrim(p_label) = '' then return 'Name the bracket.'; end if;
  if p_rank_to < p_rank_from then return 'The last rank must not be above the first.'; end if;
  if exists (select 1 from public.season_brackets b
              where b.season_id = p_season_id and b.id is distinct from p_id
                and p_rank_from <= b.rank_to and p_rank_to >= b.rank_from) then
    return 'That rank range overlaps another bracket.';
  end if;

  if p_id is null then
    insert into public.season_brackets
      (season_id, rank_from, rank_to, label, short, icon, color, prize, extras, budget)
    values (p_season_id, p_rank_from, p_rank_to, btrim(p_label),
            coalesce(nullif(btrim(coalesce(p_short, '')), ''), btrim(p_label)),
            p_icon, p_color, p_prize, coalesce(p_extras, '{}'), greatest(0, coalesce(p_budget, 0)));
  else
    update public.season_brackets set
      rank_from = p_rank_from, rank_to = p_rank_to, label = btrim(p_label),
      short = coalesce(nullif(btrim(coalesce(p_short, '')), ''), btrim(p_label)),
      icon = p_icon, color = p_color, prize = p_prize,
      extras = coalesce(p_extras, '{}'), budget = greatest(0, coalesce(p_budget, 0))
    where id = p_id;
    if not found then return 'Bracket not found.'; end if;
  end if;
  return null;
end $$;
grant execute on function public.admin_save_season_bracket(
  uuid, uuid, int, int, text, text, text[], int, text, text, text) to authenticated;

create or replace function public.admin_delete_season_bracket(p_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  delete from public.season_brackets where id = p_id;
  return null;
end $$;
grant execute on function public.admin_delete_season_bracket(uuid) to authenticated;

-- Manual adjustment. Always leaves a ledger row with a reason + who did it, and
-- tells the player — the design is explicit that this is never silent.
create or replace function public.admin_adjust_season_points(
  p_season_id uuid, p_player_id uuid, p_delta int, p_reason text)
returns text
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  if coalesce(p_delta, 0) = 0 then return 'Enter an adjustment.'; end if;
  select name into v_name from public.seasons where id = p_season_id;
  if v_name is null then return 'Season not found.'; end if;

  insert into public.season_points
    (season_id, player_id, rule_code, pts, reason, created_by)
  values (p_season_id, p_player_id, 'adjustment', p_delta,
          nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());

  insert into public.notifications (user_id, type, title, body, data)
  values (p_player_id, 'season',
          'Season points ' || (case when p_delta > 0 then '+' else '' end) || p_delta,
          v_name || ' · ' || coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
                                      'Adjusted by an administrator.'),
          jsonb_build_object('season_id', p_season_id, 'delta', p_delta));
  return null;
end $$;
grant execute on function public.admin_adjust_season_points(uuid, uuid, int, text) to authenticated;


-- ============================================================================
-- Everything the console's player sheet shows, in one call.
-- ============================================================================
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
         coalesce(p.rating, p.level, 0), coalesce(p.tier, 'bronze'),
         coalesce(p.sigma, 0.85), coalesce(p.competitive_matches, 0),
         coalesce(p.is_anchor, false), coalesce(p.status, 'active'), p.created_at
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
grant execute on function public.admin_season_player(uuid, uuid) to authenticated;

-- ============================================================================
-- Void / restore one ledger entry. Never deletes: the row stays for the audit
-- trail, stops counting toward the standings, and the player is told.
-- ============================================================================
create or replace function public.admin_void_season_points(
  p_id uuid, p_void boolean default true, p_reason text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_pts int; v_pid uuid; v_sid uuid; v_name text; v_void boolean := coalesce(p_void, true);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  select sp.pts, sp.player_id, sp.season_id into v_pts, v_pid, v_sid
    from public.season_points sp where sp.id = p_id;
  if v_pid is null then return 'Entry not found.'; end if;

  update public.season_points set
    voided      = v_void,
    void_reason = case when v_void then v_reason else null end,
    voided_by   = case when v_void then auth.uid() else null end,
    voided_at   = case when v_void then now() else null end
  where id = p_id;

  select s.name into v_name from public.seasons s where s.id = v_sid;

  insert into public.notifications (user_id, type, title, body, data)
  values (v_pid, 'season',
    case when v_void then 'Season points removed' else 'Season points restored' end,
    coalesce(v_name, 'Season') || ' · a '
      || (case when v_pts >= 0 then '+' else '' end) || v_pts || ' pts entry '
      || (case when v_void then 'no longer counts' else 'counts again' end)
      || coalesce(' — ' || v_reason, '') || '.',
    jsonb_build_object('season_id', v_sid, 'entry_id', p_id, 'voided', v_void));
  return null;
end $$;
grant execute on function public.admin_void_season_points(uuid, boolean, text) to authenticated;
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
           coalesce(p.tier, 'bronze'),
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
grant execute on function public.admin_season_find_players(uuid, text, int) to authenticated;
-- ============================================================================
-- What each product has actually sold. Cancelled and refunded orders are
-- excluded entirely; `delivered_*` is the subset that has reached the customer,
-- so the console can separate money banked from money still in flight.
-- ============================================================================
create or replace function public.admin_product_sales()
returns table (
  product_id        uuid,
  units             int,
  revenue           numeric,
  delivered_units   int,
  delivered_revenue numeric,
  unit_cost         numeric,
  profit            numeric,
  order_count       int,
  last_sold_at      timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then return; end if;
  return query
    with li as (
      select o.id as order_id, o.status, o.created_at,
             nullif(it->>'product_id', '')::uuid          as pid,
             coalesce((it->>'qty')::int, 0)               as qty,
             coalesce((it->>'unit_price')::numeric, 0)    as unit_price
        from public.orders o,
             lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) it
       where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
    )
    select li.pid,
           coalesce(sum(li.qty), 0)::int,
           coalesce(sum(li.qty * li.unit_price), 0)::numeric,
           coalesce(sum(li.qty) filter (where li.status = 'delivered'), 0)::int,
           coalesce(sum(li.qty * li.unit_price)
                      filter (where li.status = 'delivered'), 0)::numeric,
           coalesce(pc.cost, 0)::numeric,
           (coalesce(sum(li.qty * li.unit_price), 0)
              - coalesce(sum(li.qty), 0) * coalesce(pc.cost, 0))::numeric,
           count(distinct li.order_id)::int,
           max(li.created_at)
      from li
      left join public.product_costs pc on pc.product_id = li.pid
     where li.pid is not null
     group by li.pid, pc.cost;
end $$;
grant execute on function public.admin_product_sales() to authenticated;

-- ── orders survive their customer ───────────────────────────────────────────
alter table public.orders alter column player_id drop not null;

-- Re-point the FK so a deleted profile leaves the order standing, unlinked.
do $$
declare v_con text;
begin
  select con.conname into v_con
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
   where ns.nspname = 'public' and rel.relname = 'orders'
     and con.contype = 'f'
     and pg_get_constraintdef(con.oid) like '%player_id%REFERENCES%profiles%'
   limit 1;
  if v_con is not null then
    execute format('alter table public.orders drop constraint %I', v_con);
  end if;
end $$;

do $$ begin
  alter table public.orders
    add constraint orders_player_id_fkey
    foreign key (player_id) references public.profiles(id) on delete set null;
exception when duplicate_object then null; end $$;

-- Marks an order whose customer deleted their account, so the console can say
-- so instead of showing a blank name.
alter table public.orders add column if not exists customer_deleted boolean not null default false;

-- ============================================================================
-- delete_account_self — unchanged except for orders (now anonymised, not
-- deleted) and the storage cleanup at the end.
-- ============================================================================
create or replace function public.delete_account_self()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in.';
  end if;

  -- 1. Matches the user created: drop the ranking-history link, then delete the
  --    matches (their match_players rows cascade on matches.id). Clears the
  --    NOT NULL matches.created_by -> auth.users blocker.
  begin
    update public.ranking_history set match_id = null
     where match_id in (select id from public.matches where created_by = uid);
  exception when undefined_table or undefined_column then null; end;
  begin
    delete from public.matches where created_by = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 2. The user's own participation rows (reference auth.users, no cascade).
  begin delete from public.match_players where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 3. Tournament entries — first detach any bracket slots that point at them.
  begin
    update public.tournament_matches m set
      entry1 = case when m.entry1 in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.entry1 end,
      entry2 = case when m.entry2 in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.entry2 end,
      winner_entry = case when m.winner_entry in (select id from public.tournament_entries
                 where player_id = uid or partner_id = uid) then null else m.winner_entry end
     where m.entry1 in (select id from public.tournament_entries where player_id = uid or partner_id = uid)
        or m.entry2 in (select id from public.tournament_entries where player_id = uid or partner_id = uid)
        or m.winner_entry in (select id from public.tournament_entries where player_id = uid or partner_id = uid);
  exception when undefined_table or undefined_column then null; end;
  begin delete from public.tournament_entries where player_id = uid or partner_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 4. Store orders — ANONYMISE, do not delete. The sale is our accounting
  --    record and must survive for the tax retention period; everything that
  --    identifies the customer is stripped from it here.
  begin
    delete from storage.objects
     where bucket_id = 'payment-proofs'
       and name in (select o.instapay_proof_url from public.orders o
                     where o.player_id = uid and o.instapay_proof_url is not null);
  exception when others then null; end;
  begin
    update public.orders set
      player_id          = null,
      address            = null,
      instapay_sender    = null,
      instapay_proof_url = null,
      customer_deleted   = true
    where player_id = uid;
  exception when undefined_table or undefined_column then null; end;

  -- 5. Uploaded images that belong to the person, not to a record.
  begin
    delete from storage.objects
     where bucket_id = 'avatars' and name like uid::text || '/%';
  exception when others then null; end;
  begin
    delete from storage.objects
     where bucket_id = 'payment-proofs' and name like 'proofs/' || uid::text || '/%';
  exception when others then null; end;
  begin
    delete from storage.objects
     where bucket_id = 'trade-photos' and name like uid::text || '/%';
  exception when others then null; end;

  -- 6. Remove the auth user; profiles + all profile-cascade data go with it.
  begin
    delete from auth.users where id = uid;
  exception when others then
    delete from public.profiles where id = uid;
  end;
end $$;
grant execute on function public.delete_account_self() to authenticated;

-- ============================================================================
-- Receipt images are evidence of payment, not a permanent record. Twelve months
-- after an order reaches a final state the image goes; the order row remains.
-- ============================================================================
create or replace function public.prune_payment_proofs()
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int := 0;
begin
  delete from storage.objects
   where bucket_id = 'payment-proofs'
     and name in (
       select o.instapay_proof_url from public.orders o
        where o.instapay_proof_url is not null
          and o.status in ('delivered', 'cancelled', 'refunded')
          and o.created_at < now() - interval '12 months');
  update public.orders set instapay_proof_url = null
   where instapay_proof_url is not null
     and status in ('delivered', 'cancelled', 'refunded')
     and created_at < now() - interval '12 months';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.prune_payment_proofs() to authenticated;

do $$ begin
  perform cron.schedule('padel-prune-payment-proofs', '0 4 * * 0',
    'select public.prune_payment_proofs()');
exception when others then
  raise notice 'pg_cron not available — run prune_payment_proofs() manually.';
end $$;

notify pgrst, 'reload schema';

-- ============================================================================
-- Blocking and reporting (2026-08-04) - App Store Guideline 1.2.
--
-- BLOCK is the user's own call, symmetric (once either side blocks, neither
-- sees the other) and takes effect immediately. REPORT goes to the moderation
-- queue in the admin console. Blocking hides messages; it never removes
-- anyone from a match.
-- Full notes: supabase/changes/2026-08-04_block_and_report.sql
-- ============================================================================

-- ── tables ────────────────────────────────────────────────────────────────

create table if not exists public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocked_users_not_self check (blocker_id <> blocked_id)
);
create index if not exists idx_blocked_by
  on public.blocked_users (blocked_id);

create table if not exists public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references public.profiles(id) on delete cascade,
  -- What was reported. target_id is the row id in the matching table; it is
  -- intentionally NOT a foreign key so a report survives the content being
  -- deleted (otherwise acting on a report would erase the evidence).
  target_type    text not null,
  target_id      uuid,
  -- Who is being complained about. Kept even if the content goes, so repeat
  -- offenders are visible.
  target_user_id uuid references public.profiles(id) on delete set null,
  reason         text not null,
  note           text,
  -- Snapshot of the content as it was when reported, so the queue still shows
  -- what happened after the author edits or deletes it.
  content_excerpt text,
  status         text not null default 'open',
  created_at     timestamptz not null default now(),
  handled_by     uuid references public.profiles(id) on delete set null,
  handled_at     timestamptz,
  handled_note   text
);
create index if not exists idx_reports_open
  on public.reports (status, created_at desc);
create index if not exists idx_reports_target_user
  on public.reports (target_user_id);

alter table public.reports drop constraint if exists reports_target_type_chk;
alter table public.reports add constraint reports_target_type_chk
  check (target_type in ('dm_message','ticket_message','community_message',
                         'announcement_comment','user'));
alter table public.reports drop constraint if exists reports_status_chk;
alter table public.reports add constraint reports_status_chk
  check (status in ('open','actioned','dismissed'));

-- ── the block predicate ───────────────────────────────────────────────────

-- Symmetric: true if EITHER party blocked the other. SECURITY DEFINER because
-- it is used inside RLS policies, where the caller cannot read the other
-- side's block rows.
create or replace function public._blocked_with(p_other uuid)
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1 from public.blocked_users b
     where (b.blocker_id = auth.uid() and b.blocked_id = p_other)
        or (b.blocker_id = p_other and b.blocked_id = auth.uid()));
$$;
grant execute on function public._blocked_with(uuid) to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.blocked_users enable row level security;
-- You manage your own block list and can only ever see your own.
drop policy if exists "blocks: own" on public.blocked_users;
create policy "blocks: own" on public.blocked_users
  for all using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());
grant select, insert, delete on public.blocked_users to authenticated;

alter table public.reports enable row level security;
drop policy if exists "reports: file own" on public.reports;
create policy "reports: file own" on public.reports
  for insert with check (reporter_id = auth.uid());
-- Reporters see their own; moderation staff see everything.
drop policy if exists "reports: read own or staff" on public.reports;
create policy "reports: read own or staff" on public.reports
  for select using (reporter_id = auth.uid() or public._has_access('requests'));
drop policy if exists "reports: staff update" on public.reports;
create policy "reports: staff update" on public.reports
  for update using (public._can_edit('requests'))
  with check (public._can_edit('requests'));
grant select, insert on public.reports to authenticated;
grant update on public.reports to authenticated;

-- ── blocking actually hides things ────────────────────────────────────────

-- Direct messages: a blocked person's messages disappear from the thread.
drop policy if exists "dm: participant read" on public.direct_messages;
create policy "dm: participant read" on public.direct_messages
  for select using (
    exists (select 1 from public.conversations c
             where c.id = conversation_id
               and auth.uid() in (c.player_a, c.player_b))
    and not public._blocked_with(sender_id));

-- ...and they cannot send you new ones.
drop policy if exists "dm: participant send" on public.direct_messages;
create policy "dm: participant send" on public.direct_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (select 1 from public.conversations c
                 where c.id = conversation_id
                   and auth.uid() in (c.player_a, c.player_b)
                   and not public._blocked_with(
                     case when c.player_a = auth.uid() then c.player_b
                          else c.player_a end)));

-- Community chat: hide a blocked member's posts from you only. Everyone else
-- still sees them - blocking is personal, not a community-wide takedown.
-- Keeps the original organizer/admin read path intact - only the block
-- filter is new.
drop policy if exists "community_chat: member read" on public.community_chat;
create policy "community_chat: member read" on public.community_chat
  for select using (
    (
      exists (select 1 from public.community_members m
               where m.community_id = community_chat.community_id
                 and m.player_id = auth.uid())
      or exists (select 1 from public.communities c
                  where c.id = community_chat.community_id
                    and (c.organizer_id = auth.uid() or public._is_admin()))
    )
    and not public._blocked_with(sender_id));

-- Announcement comments.
drop policy if exists "ann_comments: read all" on public.announcement_comments;
create policy "ann_comments: read all" on public.announcement_comments
  for select using (not public._blocked_with(player_id));

-- Match tickets: messages hidden, but the roster is untouched - you are still
-- playing this match with them and still need the court and the time.
drop policy if exists "ticket msg: member read" on public.ticket_messages;
create policy "ticket msg: member read" on public.ticket_messages
  for select using (
    public._ticket_member(ticket_id) and not public._blocked_with(sender_id));

-- ── inbox has to agree with the policies ──────────────────────────────────

-- dm_inbox is SECURITY DEFINER, so it bypasses the RLS above and would keep
-- listing blocked conversations. Filter explicitly.
--
-- NOTE: superseded further down (2026-08-11 delete chat), which also filters
-- out conversations you have cleared. Same columns, so no drop is needed here.
-- NOTE: superseded further down (2026-08-11 dm avatars), which ADDS an
-- other_avatar column. The drop is what keeps this file re-runnable:
-- create or replace cannot change a return type (42P13).
drop function if exists public.dm_inbox();
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
         lm.text,
         lm.sent_at,
         coalesce((
           select count(*)::int from public.notifications n
            where n.user_id = auth.uid()
              and n.type = 'message'
              and n.read = false
              and n.data->>'conversation_id' = c.id::text), 0)
    from public.conversations c
    join public.profiles other
      on other.id = case when c.player_a = auth.uid() then c.player_b else c.player_a end
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
     and not public._blocked_with(other.id)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- Opening a chat with someone you have blocked (or who blocked you) must fail
-- rather than silently create a thread nobody can post in.
-- Unchanged from the original except for the block guard. Returns NULL rather
-- than raising, exactly as before: DMChatScreen already renders a graceful
-- "couldn't open this chat" on null, and a raise would surface a Postgres
-- error string to the player instead.
create or replace function public.get_or_create_conversation(
  p_other uuid, p_match_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_a uuid; v_b uuid; v_id uuid;
begin
  if v_uid is null or p_other is null or p_other = v_uid then return null; end if;
  if public._blocked_with(p_other) then return null; end if;
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

-- ── player-facing RPCs ────────────────────────────────────────────────────

create or replace function public.block_user(p_user uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if p_user = auth.uid() then
    raise exception 'Cannot block yourself';
  end if;
  insert into public.blocked_users (blocker_id, blocked_id)
  values (auth.uid(), p_user)
  on conflict do nothing;
end $$;
grant execute on function public.block_user(uuid) to authenticated;

create or replace function public.unblock_user(p_user uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  delete from public.blocked_users
   where blocker_id = auth.uid() and blocked_id = p_user;
end $$;
grant execute on function public.unblock_user(uuid) to authenticated;

create or replace function public.my_blocked_users()
returns table (player_id uuid, name text, username text, avatar_url text,
               blocked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.username, p.avatar_url, b.created_at
    from public.blocked_users b
    join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$$;
grant execute on function public.my_blocked_users() to authenticated;

-- Files a report. Resolves who is being complained about and snapshots the
-- content, so the queue is still useful after the message is gone.
create or replace function public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_reason      text,
  p_note        text default null,
  p_target_user uuid default null)
returns uuid language plpgsql security definer
set search_path = public as $$
declare v_user uuid := p_target_user; v_text text; v_id uuid;
begin
  if p_target_type = 'dm_message' then
    select dm.sender_id, dm.text into v_user, v_text
      from public.direct_messages dm where dm.id = p_target_id;
  elsif p_target_type = 'ticket_message' then
    select tm.sender_id, tm.text into v_user, v_text
      from public.ticket_messages tm where tm.id = p_target_id;
  elsif p_target_type = 'community_message' then
    select cc.sender_id, cc.body into v_user, v_text
      from public.community_chat cc where cc.id = p_target_id;
  elsif p_target_type = 'announcement_comment' then
    select ac.player_id, ac.body into v_user, v_text
      from public.announcement_comments ac where ac.id = p_target_id;
  end if;

  insert into public.reports (reporter_id, target_type, target_id,
                              target_user_id, reason, note, content_excerpt)
  values (auth.uid(), p_target_type, p_target_id,
          coalesce(v_user, p_target_user), p_reason, nullif(btrim(coalesce(p_note,'')), ''),
          left(v_text, 500))
  returning id into v_id;

  -- Tell every moderator there is something waiting. Rides the existing
  -- admin_% alert plumbing, so the console bell picks it up for free.
  insert into public.notifications (user_id, type, title, body, data)
  select pr.id, 'admin_report', 'Content reported',
         'A player reported ' ||
           case p_target_type when 'user' then 'another player'
                              else 'a message' end || '.',
         jsonb_build_object('report_id', v_id, 'admin', true)
    from public.profiles pr
   where pr.is_admin = true;

  return v_id;
end $$;
grant execute on function public.report_content(text, uuid, text, text, uuid) to authenticated;

-- ── admin moderation queue ────────────────────────────────────────────────

create or replace function public.admin_reports(p_status text default null)
returns table (
  id uuid, target_type text, target_id uuid, reason text, note text,
  content_excerpt text, status text, created_at timestamptz,
  reporter_id uuid, reporter_name text,
  target_user_id uuid, target_user_name text,
  target_user_status text, prior_reports int
)
language sql stable security definer set search_path = public as $$
  select r.id, r.target_type, r.target_id, r.reason, r.note,
         r.content_excerpt, r.status, r.created_at,
         r.reporter_id, rp.name,
         r.target_user_id, tp.name, tp.status,
         (select count(*)::int from public.reports x
           where x.target_user_id = r.target_user_id and x.id <> r.id)
    from public.reports r
    left join public.profiles rp on rp.id = r.reporter_id
    left join public.profiles tp on tp.id = r.target_user_id
   where public._has_access('requests')
     and (p_status is null or r.status = p_status)
   order by (r.status = 'open') desc, r.created_at desc;
$$;
grant execute on function public.admin_reports(text) to authenticated;

-- Resolve a report. p_delete removes the offending message outright, which is
-- what Apple means by acting on a report.
create or replace function public.admin_resolve_report(
  p_id uuid, p_status text, p_note text default null, p_delete boolean default false)
returns void language plpgsql security definer
set search_path = public as $$
declare r public.reports;
begin
  if not public._can_edit('requests') then
    raise exception 'Not authorised';
  end if;
  select * into r from public.reports where id = p_id;
  if r.id is null then
    raise exception 'Report not found';
  end if;

  if p_delete and r.target_id is not null then
    if    r.target_type = 'dm_message' then
      delete from public.direct_messages where id = r.target_id;
    elsif r.target_type = 'ticket_message' then
      delete from public.ticket_messages where id = r.target_id;
    elsif r.target_type = 'community_message' then
      delete from public.community_chat where id = r.target_id;
    elsif r.target_type = 'announcement_comment' then
      delete from public.announcement_comments where id = r.target_id;
    end if;
  end if;

  update public.reports
     set status = p_status,
         handled_by = auth.uid(),
         handled_at = now(),
         handled_note = nullif(btrim(coalesce(p_note,'')), '')
   where id = p_id;
end $$;
grant execute on function public.admin_resolve_report(uuid, text, text, boolean) to authenticated;

-- The console bell already fans out anything typed admin_%; make sure the new
-- alert maps to the Requests section so tapping it lands somewhere useful.
-- (sectionForAlertType is client-side; nothing to do server-side.)

-- ============================================================================
-- FINANCE: expenses ledger, P&L and the weekly report  (2026-08-06)
-- Canonical copy of supabase/changes/2026-08-06_expenses_and_pl.sql — see that
-- file's header for the full accounting rules (why there is no 'stock'
-- category, which statuses count as money in, and who may see the numbers).
-- ============================================================================
-- ── The ledger of what we pay ───────────────────────────────────────────────
create table if not exists public.expenses (
  id            uuid primary key default gen_random_uuid(),
  spent_on      date not null default current_date,
  category      text not null default 'other',
  amount        numeric(12,2) not null default 0,
  vendor        text,
  note          text,
  tournament_id uuid references public.tournaments(id) on delete set null,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Drift guards: on a live DB the create-table above is skipped entirely.
alter table public.expenses add column if not exists spent_on      date not null default current_date;
alter table public.expenses add column if not exists category      text not null default 'other';
alter table public.expenses add column if not exists amount        numeric(12,2) not null default 0;
alter table public.expenses add column if not exists vendor        text;
alter table public.expenses add column if not exists note          text;
alter table public.expenses add column if not exists tournament_id uuid references public.tournaments(id) on delete set null;
alter table public.expenses add column if not exists created_by    uuid references public.profiles(id);
alter table public.expenses add column if not exists created_at    timestamptz not null default now();
alter table public.expenses add column if not exists updated_at    timestamptz not null default now();

-- Categories mirror kExpenseCategories in lib/admin/data/finance_model.dart —
-- change both. Deliberately no 'stock': see the COGS note in the header.
alter table public.expenses drop constraint if exists expenses_category_chk;
alter table public.expenses add constraint expenses_category_chk check (
  category in ('materials','court_rent','prizes','marketing','salaries',
               'shipping','software','equipment','other'));

alter table public.expenses drop constraint if exists expenses_amount_chk;
alter table public.expenses add constraint expenses_amount_chk check (amount >= 0);

create index if not exists expenses_spent_on_idx on public.expenses (spent_on desc);
create index if not exists expenses_category_idx on public.expenses (category);

comment on table public.expenses is
  'What the platform pays out, recorded by hand. Cost of goods sold and '
  'trade-in credit are derived from the orders/trade ledgers instead.';

-- Stamp the author + keep updated_at honest.
create or replace function public.expenses_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_expenses_touch on public.expenses;
create trigger trg_expenses_touch before insert or update on public.expenses
  for each row execute function public.expenses_touch();

-- ── Drift guard: tournament_entries has no created_at on the live DB ────────
-- migrations/0003 shipped the column as `registered_at`; the create-table block
-- above calls it `created_at` and is skipped on a live database, so it was
-- never added. Add it and backfill from registered_at where that exists, so
-- historic entries keep their REAL date instead of all landing in today's week.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public'
                    and table_name   = 'tournament_entries'
                    and column_name  = 'created_at') then
    alter table public.tournament_entries add column created_at timestamptz;
    if exists (select 1 from information_schema.columns
                where table_schema = 'public'
                  and table_name   = 'tournament_entries'
                  and column_name  = 'registered_at') then
      -- Dynamic: the column name must not be resolved unless it exists.
      execute 'update public.tournament_entries
                  set created_at = registered_at where created_at is null';
    end if;
    update public.tournament_entries set created_at = now() where created_at is null;
    alter table public.tournament_entries alter column created_at set default now();
    alter table public.tournament_entries alter column created_at set not null;
  end if;
end $$;

-- ── Repairs: dated by updated_at ────────────────────────────────────────────
-- A repair counts as money in on the day the racket is COLLECTED, so the weekly
-- report reads repair_requests.updated_at. migrations/0003 already declares the
-- column AND keeps it moving (trg_repair_requests_touch), so there is nothing
-- to add — the guard below only covers a database that somehow lacks it. The
-- drop removes the duplicate trigger an earlier draft of this file created;
-- 0003's is the one that stays.
alter table public.repair_requests
  add column if not exists updated_at timestamptz not null default now();
drop trigger if exists trg_repair_touch on public.repair_requests;

-- ── Who may see the money ───────────────────────────────────────────────────
-- Super admin always; an Analyst holding Reports (read-only by definition) too.
-- Anyone else — an organizer handed the Reports section, say — is refused, so
-- granting a section can never leak platform-wide finances.
create or replace function public._can_see_finance()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select p.is_admin
        or (p.admin_role = 'analyst' and public._has_access('reports'))
      from public.profiles p
     where p.id = auth.uid()), false);
$$;
grant execute on function public._can_see_finance() to authenticated;

alter table public.expenses enable row level security;
drop policy if exists "expenses: finance read" on public.expenses;
create policy "expenses: finance read" on public.expenses
  for select using (public._can_see_finance());
drop policy if exists "expenses: admin write" on public.expenses;
create policy "expenses: admin write" on public.expenses
  for all using (public._is_admin()) with check (public._is_admin());
grant select, insert, update, delete on public.expenses to authenticated;

-- ============================================================================
-- The P&L engine. One core function; the summary, the weekly report and any
-- future export all go through it so the numbers can never disagree.
--
-- [p_from, p_to) — Africa/Cairo local dates, from inclusive, to exclusive.
-- ============================================================================
create or replace function public._finance_core(p_from date, p_to date)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_a timestamptz := (p_from::timestamp) at time zone 'Africa/Cairo';
  v_b timestamptz := (p_to::timestamp)   at time zone 'Africa/Cairo';
  v_store numeric := 0; v_collected numeric := 0; v_orders int := 0;
  v_cogs numeric := 0;
  v_entries numeric := 0; v_entry_n int := 0;
  v_repairs numeric := 0; v_repair_n int := 0;
  v_trade numeric := 0;   v_trade_n int := 0;
  v_exp numeric := 0;     v_exp_n int := 0;
  v_cats json := '[]'::json;
  v_in numeric; v_out numeric; v_profit numeric;
begin
  -- Store sales. `delivered` is the subset actually banked; the rest is booked
  -- but still in flight (cash on delivery collects at the door).
  select coalesce(sum(o.total), 0),
         coalesce(sum(o.total) filter (where o.status = 'delivered'), 0),
         count(*)
    into v_store, v_collected, v_orders
    from public.orders o
   where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
     and o.created_at >= v_a and o.created_at < v_b;

  -- Cost of the goods in those same orders (unpriced products cost 0).
  with li as (
    select coalesce((it->>'qty')::int, 0)        as qty,
           nullif(it->>'product_id', '')::uuid   as pid
      from public.orders o,
           lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) it
     where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
       and o.created_at >= v_a and o.created_at < v_b
  )
  select coalesce(sum(li.qty * coalesce(pc.cost, 0)), 0)
    into v_cogs
    from li
    left join public.product_costs pc on pc.product_id = li.pid;

  -- Tournament entry fees, verified and not refunded.
  select coalesce(sum(coalesce(te.paid_amount, 0)), 0), count(*)
    into v_entries, v_entry_n
    from public.tournament_entries te
   where te.status = 'paid'
     and coalesce(te.refund_status, 'none') <> 'refunded'
     and te.created_at >= v_a and te.created_at < v_b;

  -- Repairs: charged when the player collects the racket.
  select coalesce(sum(coalesce(r.quote_amount, 0)), 0), count(*)
    into v_repairs, v_repair_n
    from public.repair_requests r
   where r.status = 'collected'
     and coalesce(r.updated_at, r.created_at) >= v_a
     and coalesce(r.updated_at, r.created_at) <  v_b;

  -- Trade-ins: credit handed to a player for their racket.
  select coalesce(sum(coalesce(t.offer_credit, 0)), 0), count(*)
    into v_trade, v_trade_n
    from public.trade_requests t
   where t.status in ('accepted', 'completed')
     and t.created_at >= v_a and t.created_at < v_b;

  -- Hand-recorded expenses, and the same money split by category.
  select coalesce(sum(e.amount), 0), count(*)
    into v_exp, v_exp_n
    from public.expenses e
   where e.spent_on >= p_from and e.spent_on < p_to;

  select coalesce(json_agg(x order by x.amount desc), '[]'::json)
    into v_cats
    from (select e.category,
                 sum(e.amount)::numeric as amount,
                 count(*)::int          as n
            from public.expenses e
           where e.spent_on >= p_from and e.spent_on < p_to
           group by e.category) x;

  v_in     := v_store + v_entries + v_repairs;
  v_out    := v_cogs + v_trade + v_exp;
  v_profit := v_in - v_out;

  return json_build_object(
    'from', p_from,
    'to',   p_to - 1,                       -- inclusive last day, for display
    'in', json_build_object(
      'store',           v_store,
      'store_collected', v_collected,
      'entries',         v_entries,
      'repairs',         v_repairs,
      'total',           v_in),
    'out', json_build_object(
      'cogs',        v_cogs,
      'trade_in',    v_trade,
      'expenses',    v_exp,
      'by_category', v_cats,
      'total',       v_out),
    'profit', v_profit,
    'margin', case when v_in = 0 then 0
                   else round(100.0 * v_profit / v_in, 1) end,
    'counts', json_build_object(
      'orders',   v_orders,
      'entries',  v_entry_n,
      'repairs',  v_repair_n,
      'trade_in', v_trade_n,
      'expenses', v_exp_n)
  );
end $$;
-- The core has no guard of its own — it is the raw numbers. Postgres grants
-- EXECUTE to PUBLIC by default, which would let ANY signed-in player read the
-- platform's finances. Only the guarded wrappers below may reach it (they are
-- SECURITY DEFINER, so they call it as the owner).
revoke all on function public._finance_core(date, date) from public;

-- One period's full picture. Null dates = all time.
create or replace function public.admin_finance_summary(
  p_from date default null,
  p_to   date default null)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;
  return public._finance_core(
    coalesce(p_from, date '2000-01-01'),
    coalesce(p_to, ((now() at time zone 'Africa/Cairo')::date + 1)));
end $$;
grant execute on function public.admin_finance_summary(date, date) to authenticated;

-- The weekly report: the last [p_weeks] Monday-to-Sunday weeks, newest first,
-- each carrying the same breakdown as the summary above. The current week is
-- included and is partial by definition.
create or replace function public.admin_weekly_finance(p_weeks int default 8)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_n     int;
  v_this  date;
  v_first date;
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;
  v_n     := least(greatest(coalesce(p_weeks, 8), 1), 26);
  v_this  := date_trunc('week', (now() at time zone 'Africa/Cairo'))::date;
  v_first := v_this - ((v_n - 1) * 7);
  return (
    select coalesce(json_agg(w order by w.week_start desc), '[]'::json)
      from (
        -- generate_series returns timestamp, and `timestamp + int` is not an
        -- operator — cast to date FIRST, then add days.
        select ws::date              as week_start,
               ws::date + 6          as week_end,
               ws::date = v_this     as is_current,
               public._finance_core(ws::date, ws::date + 7) as report
          from generate_series(v_first::timestamp, v_this::timestamp,
                               interval '7 day') ws
      ) w
  );
end $$;
grant execute on function public.admin_weekly_finance(int) to authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- FINANCE: money in, recorded by hand  (2026-08-06)
-- Canonical copy of supabase/changes/2026-08-06_manual_income.sql. Redefines
-- _finance_core (the definition above is superseded) so offline money — cash
-- sales, coaching, court hire, sponsorship — reaches the same P&L.
-- ============================================================================
create table if not exists public.income (
  id            uuid primary key default gen_random_uuid(),
  received_on   date not null default current_date,
  category      text not null default 'other',
  amount        numeric(12,2) not null default 0,
  payer         text,
  note          text,
  tournament_id uuid references public.tournaments(id) on delete set null,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Drift guards, in case an earlier draft created the table.
alter table public.income add column if not exists received_on   date not null default current_date;
alter table public.income add column if not exists category      text not null default 'other';
alter table public.income add column if not exists amount        numeric(12,2) not null default 0;
alter table public.income add column if not exists payer         text;
alter table public.income add column if not exists note          text;
alter table public.income add column if not exists tournament_id uuid references public.tournaments(id) on delete set null;
alter table public.income add column if not exists created_by    uuid references public.profiles(id);
alter table public.income add column if not exists created_at    timestamptz not null default now();
alter table public.income add column if not exists updated_at    timestamptz not null default now();

-- Mirrors kIncomeCategories in lib/admin/data/finance_model.dart — change both.
alter table public.income drop constraint if exists income_category_chk;
alter table public.income add constraint income_category_chk check (
  category in ('cash_sale','coaching','court_hire','sponsorship','event','other'));

alter table public.income drop constraint if exists income_amount_chk;
alter table public.income add constraint income_amount_chk check (amount >= 0);

create index if not exists income_received_on_idx on public.income (received_on desc);
create index if not exists income_category_idx    on public.income (category);

comment on table public.income is
  'Money taken outside the app — cash sales, coaching, court hire, sponsorship. '
  'Store orders, entry fees and repairs are counted from their own ledgers.';

-- ── Shared stamp trigger for both hand-kept ledgers ─────────────────────────
create or replace function public.ledger_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_income_touch on public.income;
create trigger trg_income_touch before insert or update on public.income
  for each row execute function public.ledger_touch();

-- Re-point expenses at the shared function (expenses_touch stays defined, so
-- an older trigger still works if this file is run out of order).
drop trigger if exists trg_expenses_touch on public.expenses;
create trigger trg_expenses_touch before insert or update on public.expenses
  for each row execute function public.ledger_touch();

-- ── Same eyes as the rest of the finances ───────────────────────────────────
alter table public.income enable row level security;
drop policy if exists "income: finance read" on public.income;
create policy "income: finance read" on public.income
  for select using (public._can_see_finance());
drop policy if exists "income: admin write" on public.income;
create policy "income: admin write" on public.income
  for all using (public._is_admin()) with check (public._is_admin());
grant select, insert, update, delete on public.income to authenticated;

-- ============================================================================
-- Fold it into the P&L. Identical to the version in
-- 2026-08-06_expenses_and_pl.sql apart from the `manual` money-in line, which
-- is added to the money-in total and reported separately so the breakdown can
-- name it.
-- ============================================================================
create or replace function public._finance_core(p_from date, p_to date)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_a timestamptz := (p_from::timestamp) at time zone 'Africa/Cairo';
  v_b timestamptz := (p_to::timestamp)   at time zone 'Africa/Cairo';
  v_store numeric := 0; v_collected numeric := 0; v_orders int := 0;
  v_cogs numeric := 0;
  v_entries numeric := 0; v_entry_n int := 0;
  v_repairs numeric := 0; v_repair_n int := 0;
  v_manual numeric := 0;  v_manual_n int := 0;
  v_trade numeric := 0;   v_trade_n int := 0;
  v_exp numeric := 0;     v_exp_n int := 0;
  v_cats json := '[]'::json;
  v_incats json := '[]'::json;
  v_in numeric; v_out numeric; v_profit numeric;
begin
  -- Store sales. `delivered` is the subset actually banked; the rest is booked
  -- but still in flight (cash on delivery collects at the door).
  select coalesce(sum(o.total), 0),
         coalesce(sum(o.total) filter (where o.status = 'delivered'), 0),
         count(*)
    into v_store, v_collected, v_orders
    from public.orders o
   where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
     and o.created_at >= v_a and o.created_at < v_b;

  -- Cost of the goods in those same orders (unpriced products cost 0).
  with li as (
    select coalesce((it->>'qty')::int, 0)        as qty,
           nullif(it->>'product_id', '')::uuid   as pid
      from public.orders o,
           lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) it
     where coalesce(o.status, 'pending') not in ('cancelled', 'refunded')
       and o.created_at >= v_a and o.created_at < v_b
  )
  select coalesce(sum(li.qty * coalesce(pc.cost, 0)), 0)
    into v_cogs
    from li
    left join public.product_costs pc on pc.product_id = li.pid;

  -- Tournament entry fees, verified and not refunded.
  select coalesce(sum(coalesce(te.paid_amount, 0)), 0), count(*)
    into v_entries, v_entry_n
    from public.tournament_entries te
   where te.status = 'paid'
     and coalesce(te.refund_status, 'none') <> 'refunded'
     and te.created_at >= v_a and te.created_at < v_b;

  -- Repairs: charged when the player collects the racket.
  select coalesce(sum(coalesce(r.quote_amount, 0)), 0), count(*)
    into v_repairs, v_repair_n
    from public.repair_requests r
   where r.status = 'collected'
     and coalesce(r.updated_at, r.created_at) >= v_a
     and coalesce(r.updated_at, r.created_at) <  v_b;

  -- Money taken outside the app, recorded by hand.
  select coalesce(sum(i.amount), 0), count(*)
    into v_manual, v_manual_n
    from public.income i
   where i.received_on >= p_from and i.received_on < p_to;

  select coalesce(json_agg(y order by y.amount desc), '[]'::json)
    into v_incats
    from (select i.category,
                 sum(i.amount)::numeric as amount,
                 count(*)::int          as n
            from public.income i
           where i.received_on >= p_from and i.received_on < p_to
           group by i.category) y;

  -- Trade-ins: credit handed to a player for their racket.
  select coalesce(sum(coalesce(t.offer_credit, 0)), 0), count(*)
    into v_trade, v_trade_n
    from public.trade_requests t
   where t.status in ('accepted', 'completed')
     and t.created_at >= v_a and t.created_at < v_b;

  -- Hand-recorded expenses, and the same money split by category.
  select coalesce(sum(e.amount), 0), count(*)
    into v_exp, v_exp_n
    from public.expenses e
   where e.spent_on >= p_from and e.spent_on < p_to;

  select coalesce(json_agg(x order by x.amount desc), '[]'::json)
    into v_cats
    from (select e.category,
                 sum(e.amount)::numeric as amount,
                 count(*)::int          as n
            from public.expenses e
           where e.spent_on >= p_from and e.spent_on < p_to
           group by e.category) x;

  v_in     := v_store + v_entries + v_repairs + v_manual;
  v_out    := v_cogs + v_trade + v_exp;
  v_profit := v_in - v_out;

  return json_build_object(
    'from', p_from,
    'to',   p_to - 1,                       -- inclusive last day, for display
    'in', json_build_object(
      'store',           v_store,
      'store_collected', v_collected,
      'entries',         v_entries,
      'repairs',         v_repairs,
      'manual',          v_manual,
      'by_category',     v_incats,
      'total',           v_in),
    'out', json_build_object(
      'cogs',        v_cogs,
      'trade_in',    v_trade,
      'expenses',    v_exp,
      'by_category', v_cats,
      'total',       v_out),
    'profit', v_profit,
    'margin', case when v_in = 0 then 0
                   else round(100.0 * v_profit / v_in, 1) end,
    'counts', json_build_object(
      'orders',   v_orders,
      'entries',  v_entry_n,
      'repairs',  v_repair_n,
      'manual',   v_manual_n,
      'trade_in', v_trade_n,
      'expenses', v_exp_n)
  );
end $$;
-- Raw numbers, no guard of its own — only the guarded wrappers may reach it.
revoke all on function public._finance_core(date, date) from public;

notify pgrst, 'reload schema';

-- ============================================================================
-- WEEKLY REPORT LINKS  (2026-08-06)
-- Canonical copy of supabase/changes/2026-08-06_weekly_report_links.sql.
-- A week's P&L as a permanent, login-free URL — what makes it emailable.
-- The optional pg_cron auto-send block lives only in that delta: it needs your
-- project ref and a secret filled in, so it is not part of the schema.
-- ============================================================================
create table if not exists public.report_links (
  token        text primary key,
  week_start   date not null,
  week_end     date not null,
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  view_count   int not null default 0,
  revoked      boolean not null default false
);

-- Drift guards, in case an earlier draft created the table.
alter table public.report_links add column if not exists week_start   date;
alter table public.report_links add column if not exists week_end     date;
alter table public.report_links add column if not exists created_by   uuid references public.profiles(id);
alter table public.report_links add column if not exists created_at   timestamptz not null default now();
alter table public.report_links add column if not exists last_seen_at timestamptz;
alter table public.report_links add column if not exists view_count   int not null default 0;
alter table public.report_links add column if not exists revoked      boolean not null default false;

-- One live link per week. A revoked link keeps its row (so the token stays
-- burned) but stops being the one a new request hands back — hence the partial
-- unique index rather than a plain unique constraint.
create unique index if not exists report_links_week_live_idx
  on public.report_links (week_start) where not revoked;

comment on table public.report_links is
  'Permanent share tokens for the weekly P&L. One live token per week; the '
  'holder can read that week without logging in.';

alter table public.report_links enable row level security;

-- Only people who may see the money may see the links to it. Writes go through
-- the RPCs below (super admin), never straight from a client.
drop policy if exists "report_links: finance read" on public.report_links;
create policy "report_links: finance read" on public.report_links
  for select using (public._can_see_finance());

grant select on public.report_links to authenticated;

-- ── Mint (or return) the link for a week ───────────────────────
-- The work itself, unguarded. Never granted to anyone — the two wrappers below
-- are the only ways in, and they carry the permission checks.
create or replace function public._report_link_ensure(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_start date;
begin
  -- Snap to the Monday of whatever week the caller names, so the same week can
  -- never end up with two links because of an off-by-a-day.
  v_start := date_trunc('week', p_week_start::timestamp)::date;

  select token into v_token
    from public.report_links
   where week_start = v_start and not revoked;

  if v_token is null then
    -- Two uuids = 256 bits of CSPRNG output, no pgcrypto dependency.
    v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.report_links (token, week_start, week_end, created_by)
      values (v_token, v_start, v_start + 6, auth.uid())
      -- Two admins tapping at once: keep the row that won, return its token.
      on conflict do nothing;
    select token into v_token
      from public.report_links
     where week_start = v_start and not revoked;
  end if;

  return json_build_object(
    'token',      v_token,
    'week_start', v_start,
    'week_end',   v_start + 6);
end $$;
revoke all on function public._report_link_ensure(date) from public, anon, authenticated;

-- What the console calls. Super admin only: handing out a login-free link to
-- the P&L is a bigger decision than reading it, so an Analyst who can see the
-- numbers still can't create a link to them.
create or replace function public.admin_report_link(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then
    return json_build_object('error', 'not_allowed');
  end if;
  return public._report_link_ensure(p_week_start);
end $$;
grant execute on function public.admin_report_link(date) to authenticated;

-- What the `weekly-report-send` Edge Function calls. It runs unattended from
-- pg_cron, so there is no auth.uid() to check — service_role IS the trust.
create or replace function public.report_link_ensure(p_week_start date)
returns json
language plpgsql security definer set search_path = public as $$
begin
  return public._report_link_ensure(p_week_start);
end $$;
revoke all on function public.report_link_ensure(date) from public, anon, authenticated;
grant execute on function public.report_link_ensure(date) to service_role;

-- ── Kill a link ────────────────────────────────────────────────
create or replace function public.admin_revoke_report_link(p_token text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Not authorised.'; end if;
  update public.report_links set revoked = true where token = p_token;
  return null;
end $$;
grant execute on function public.admin_revoke_report_link(text) to authenticated;

-- ── What the Edge Function renders ─────────────────────────────
-- Everything the page shows, in one call. No guard of its own beyond the token
-- because it is reachable only by service_role — the Edge Function holds that
-- key, the public internet does not.
create or replace function public.report_render(p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_row public.report_links%rowtype;
  v_this date := date_trunc('week', (now() at time zone 'Africa/Cairo'))::date;
begin
  select * into v_row from public.report_links
   where token = p_token and not revoked;
  if not found then
    return json_build_object('error', 'not_found');
  end if;

  update public.report_links
     set view_count = view_count + 1, last_seen_at = now()
   where token = p_token;

  return json_build_object(
    'week_start', v_row.week_start,
    'week_end',   v_row.week_end,
    -- A link to the running week renders "so far" rather than pretending the
    -- week is closed.
    'is_current', v_row.week_start = v_this,
    'report',     public._finance_core(v_row.week_start, v_row.week_start + 7));
end $$;
revoke all on function public.report_render(text) from public, anon, authenticated;
grant execute on function public.report_render(text) to service_role;

notify pgrst, 'reload schema';


-- ============================================================================
-- WEEKLY REPORT RECIPIENTS  (2026-08-07)
--
-- Until now the weekly report went to exactly one hardcoded address — the
-- `REPORT_TO` secret, changeable only from the Supabase CLI. That is the wrong
-- place for a list that changes whenever the team does, and the person who
-- manages the team is not the person with a terminal.
--
-- So the mailing list becomes data:
--
--   report_recipients        one row per address. The single source of truth
--                            for who gets the Monday mail. Managed from the
--                            console, super admin only.
--
--   admin_report_recipients  what the console reads: the current list, PLUS
--                            the staff who could be added but aren't yet, so
--                            adding a teammate is a tap and not a typed email.
--
--   report_recipients_active what the `weekly-report-send` Edge Function reads
--                            with the service-role key. Granted to service_role
--                            ONLY. If it comes back empty the function falls
--                            back to REPORT_TO, so an unrun migration degrades
--                            to today's behaviour instead of mailing nobody.
--
-- WHO CAN BE ADDED. The picker offers only staff who can already see the money
-- (`_can_see_finance_of`) — super admins, and analysts holding Reports. Anyone
-- else (an accountant with no app account, say) can still be added, but their
-- address has to be typed. That keeps "add a colleague" one tap without making
-- it easy to mail the P&L to a Support moderator by mistake.
--
-- Note this is a mailing list, not a permission: the report link opens without
-- a login, so being on this list IS access to that week's numbers. Adding
-- someone is therefore super-admin-only, the same rule as minting the link.
--
-- Requires 2026-08-06_weekly_report_links.sql.
-- Safe to re-run.
-- ============================================================================

-- ── Per-user versions of the two access guards ─────────────────
-- `_access_ids()` only ever answered for the CALLER, which is all any RLS
-- policy needed. Listing candidate recipients means asking about someone else,
-- so the body moves into a function that takes a user and the original becomes
-- a one-line wrapper. Same logic, same results — every existing policy that
-- calls `_access_ids()` is unaffected.
create or replace function public._access_ids_of(p_user uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare
  v_is_admin boolean; v_role text; v_access jsonb;
begin
  select coalesce(is_admin, false), admin_role, admin_access
    into v_is_admin, v_role, v_access
    from public.profiles where id = p_user;
  if not found then return '{}'::text[]; end if;
  if v_is_admin then return public._role_default('super_admin'); end if;
  if v_role is null then return '{}'::text[]; end if;
  if jsonb_typeof(v_access) = 'array' and jsonb_array_length(v_access) > 0 then
    return (select array(select jsonb_array_elements_text(v_access)));
  end if;
  return public._role_default(v_role);
end $$;
grant execute on function public._access_ids_of(uuid) to authenticated;

create or replace function public._access_ids()
returns text[] language sql stable security definer set search_path = public as $$
  select public._access_ids_of(auth.uid());
$$;
grant execute on function public._access_ids() to authenticated;

-- Mirrors _can_see_finance(), for an arbitrary user.
create or replace function public._can_see_finance_of(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select p.is_admin
        or (p.admin_role = 'analyst' and 'reports' = any (public._access_ids_of(p.id)))
      from public.profiles p
     where p.id = p_user), false);
$$;
grant execute on function public._can_see_finance_of(uuid) to authenticated;

-- ── The list ───────────────────────────────────────────────────
create table if not exists public.report_recipients (
  email      text primary key,
  name       text,
  -- Set when the address belongs to a staff account, so the console can show
  -- who they are and stop offering them in the picker. Null for outsiders.
  profile_id uuid references public.profiles(id) on delete set null,
  -- Off keeps the row (and the name) while stopping the mail — for someone on
  -- leave, without losing them from the list.
  active     boolean not null default true,
  added_by   uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- Drift guards, in case an earlier draft created the table.
alter table public.report_recipients add column if not exists name       text;
alter table public.report_recipients add column if not exists profile_id uuid references public.profiles(id) on delete set null;
alter table public.report_recipients add column if not exists active     boolean not null default true;
alter table public.report_recipients add column if not exists added_by   uuid references public.profiles(id);
alter table public.report_recipients add column if not exists created_at timestamptz not null default now();

comment on table public.report_recipients is
  'Who the weekly P&L is emailed to. Being on this list is access to the '
  'numbers — the report link opens without a login.';

alter table public.report_recipients enable row level security;

-- Only people who may see the money may see who else gets it. All writes go
-- through the super-admin RPCs below, never straight from a client.
drop policy if exists "report_recipients: finance read" on public.report_recipients;
create policy "report_recipients: finance read" on public.report_recipients
  for select using (public._can_see_finance());

grant select on public.report_recipients to authenticated;

-- ── Seed, once ─────────────────────────────────────────────────
-- Start the list as every super admin, so the feature works the moment it is
-- switched on. Guarded on the table being empty: someone deliberately removed
-- must not come back on the next re-run.
insert into public.report_recipients (email, name, profile_id)
select distinct on (lower(u.email))
       lower(u.email), p.name, p.id
  from public.profiles p
  join auth.users u on u.id = p.id
 where p.is_admin
   and u.email is not null
   and u.email <> ''
   and not exists (select 1 from public.report_recipients)
 order by lower(u.email)
on conflict (email) do nothing;

-- ── Read: the list + who could join it ─────────────────────────
create or replace function public.admin_report_recipients()
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._can_see_finance() then
    return json_build_object('error', 'not_allowed');
  end if;

  return json_build_object(
    'recipients', coalesce((
      select json_agg(row_to_json(x) order by x.active desc, x.email)
        from (
          select r.email, r.name, r.profile_id, r.active, r.created_at,
                 p.avatar_url,
                 -- Shown as the reason they're on the list; null for outsiders.
                 case when p.is_admin then 'super_admin' else p.admin_role end
                   as admin_role
            from public.report_recipients r
            left join public.profiles p on p.id = r.profile_id
        ) x), '[]'::json),
    -- Staff who can already see the money but aren't on the list. The console
    -- offers these as one-tap adds; anyone else has to be typed.
    'candidates', coalesce((
      select json_agg(row_to_json(y) order by y.name)
        from (
          select p.id, p.name, p.avatar_url, lower(u.email) as email,
                 case when p.is_admin then 'super_admin' else p.admin_role end
                   as admin_role
            from public.profiles p
            join auth.users u on u.id = p.id
           where u.email is not null
             and u.email <> ''
             and public._can_see_finance_of(p.id)
             and not exists (select 1 from public.report_recipients r
                              where r.email = lower(u.email))
        ) y), '[]'::json));
end $$;
grant execute on function public.admin_report_recipients() to authenticated;

-- ── Write: super admin only ────────────────────────────────────
-- Same rule as minting a link. An analyst may read the P&L and read this list,
-- but may not decide who else receives it.
create or replace function public.admin_add_report_recipient(
  p_email      text,
  p_name       text default null,
  p_profile_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;

  v_email := lower(trim(coalesce(p_email, '')));
  if v_email = '' then return 'Enter an email address.'; end if;
  -- Deliberately loose: enough to catch a typo, not a full RFC parser.
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return 'That doesn''t look like an email address.';
  end if;

  -- Aliased so the DO UPDATE can name the existing row unambiguously.
  insert into public.report_recipients as r (email, name, profile_id, added_by)
    values (v_email, nullif(trim(coalesce(p_name, '')), ''), p_profile_id, auth.uid())
  -- Already there: turn them back on rather than complaining.
  on conflict (email) do update
    set active     = true,
        name       = coalesce(excluded.name, r.name),
        profile_id = coalesce(excluded.profile_id, r.profile_id);

  return null;
end $$;
grant execute on function public.admin_add_report_recipient(text, text, uuid) to authenticated;

create or replace function public.admin_set_report_recipient(
  p_email  text,
  p_active boolean)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;
  update public.report_recipients
     set active = p_active
   where email = lower(trim(coalesce(p_email, '')));
  return null;
end $$;
grant execute on function public.admin_set_report_recipient(text, boolean) to authenticated;

create or replace function public.admin_remove_report_recipient(p_email text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin() then return 'Only a super admin can do that.'; end if;
  delete from public.report_recipients
   where email = lower(trim(coalesce(p_email, '')));
  return null;
end $$;
grant execute on function public.admin_remove_report_recipient(text) to authenticated;

-- ── What the Edge Function sends to ────────────────────────────
-- service_role only: the sender runs unattended from pg_cron, where there is no
-- auth.uid() to check. Returns [] rather than erroring when nobody is listed,
-- which the function reads as "fall back to REPORT_TO".
create or replace function public.report_recipients_active()
returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('email', email, 'name', name)
                           order by email), '[]'::json)
    from public.report_recipients
   where active;
$$;
revoke all on function public.report_recipients_active() from public, anon, authenticated;
grant execute on function public.report_recipients_active() to service_role;

notify pgrst, 'reload schema';

-- ============================================================
-- Partner invites (2026-08-10) — naming a partner is a REQUEST, not an
-- enrolment. Supersedes the create_match / join_match / mm_accept /
-- leave_match / cancel_match / notify_match_join definitions ABOVE, and moves
-- the match-ticket trigger off `matches` INSERT onto `match_players`.
--
-- Why: a named partner used to be inserted straight into match_players, which
-- made them a ticket member, which made ticket_roster() hand their phone
-- number to whoever named them. See changes/2026-08-10_partner_invites.sql for
-- the full write-up.
-- ============================================================

-- ── the invite ────────────────────────────────────────────────────────────

create table if not exists public.match_invites (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null references public.matches(id)  on delete cascade,
  inviter_id   uuid not null references public.profiles(id) on delete cascade,
  invitee_id   uuid not null references public.profiles(id) on delete cascade,
  team         text not null,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);

-- Widen-safe CHECKs (the table may predate this file on a drifted DB).
alter table public.match_invites drop constraint if exists match_invites_team_chk;
alter table public.match_invites add  constraint match_invites_team_chk
  check (team in ('a', 'b'));
alter table public.match_invites drop constraint if exists match_invites_status_chk;
alter table public.match_invites add  constraint match_invites_status_chk
  check (status in ('pending', 'accepted', 'declined', 'cancelled'));

-- One live invite per person per match. Partial, so a declined invite doesn't
-- block a later re-invite.
create unique index if not exists match_invites_one_live
  on public.match_invites (match_id, invitee_id) where status = 'pending';
create index if not exists idx_match_invites_invitee
  on public.match_invites (invitee_id, status);

-- ── occupancy: players + reserved slots ───────────────────────────────────

-- A pending invite only holds a slot while the match could still be played.
-- Deriving that from time means no sweep job is required for correctness.
create or replace function public._invite_slots(p_match uuid, p_team text default null)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int
    from public.match_invites i
    join public.matches m on m.id = i.match_id
   where i.match_id = p_match
     and i.status   = 'pending'
     and m.status   = 'open'
     and now() < m.scheduled_at
     and (p_team is null or i.team = p_team);
$$;

-- Seats taken overall = actual players + slots reserved by live invites.
create or replace function public._match_taken(p_match uuid)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.match_players where match_id = p_match)
       + public._invite_slots(p_match, null);
$$;

-- Same, per side.
create or replace function public._team_taken(p_match uuid, p_team text)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.match_players
           where match_id = p_match and team = p_team)
       + public._invite_slots(p_match, p_team);
$$;

grant execute on function public._invite_slots(uuid, text) to authenticated;
grant execute on function public._match_taken(uuid)        to authenticated;
grant execute on function public._team_taken(uuid, text)   to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────
-- Readable by the two people concerned and by anyone already in the match (so
-- the lobby can render "waiting for Sara"). Never writable from the client —
-- every mutation goes through a SECURITY DEFINER RPC below.

alter table public.match_invites enable row level security;
drop policy if exists "match invite: read" on public.match_invites;
create policy "match invite: read" on public.match_invites
  for select using (
    invitee_id = auth.uid()
    or inviter_id = auth.uid()
    or exists (select 1 from public.match_players mp
                where mp.match_id = match_invites.match_id
                  and mp.player_id = auth.uid()));
grant select on public.match_invites to authenticated;

-- An invitee is not a match_player yet, so the existing "matches: participant
-- read" policy hides the match from them — they'd tap the notification and
-- land on an empty screen with nothing to answer. A live invite is its own
-- reason to see the match. SECURITY DEFINER helper (same pattern as
-- _ticket_member) so the policy can't recurse through match_invites' own RLS.
create or replace function public._invited_to_match(p_match uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.match_invites i
     where i.match_id = p_match
       and i.invitee_id = auth.uid()
       and i.status = 'pending');
$$;
grant execute on function public._invited_to_match(uuid) to authenticated;

drop policy if exists "matches: invitee read" on public.matches;
create policy "matches: invitee read" on public.matches
  for select using (public._invited_to_match(id));

-- ── raising an invite ─────────────────────────────────────────────────────

-- Shared by create_match / join_match / mm_accept. RAISES on a bad partner
-- rather than returning a string: the caller has usually inserted its own
-- match_players row by this point, and rolling the whole thing back is the only
-- way to avoid committing a half-done join. The exception surfaces to Dart as a
-- PostgrestException, which the service layer already turns into a message.
-- Assumes the caller has validated rating/band rules.
create or replace function public._invite_partner(
  p_match uuid, p_partner uuid, p_team text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_name      text;
  v_when      timestamptz;
  v_type      text;
  v_invite    uuid;
begin
  if p_partner is null or p_partner = v_uid then return; end if;

  if not exists (select 1 from public.profiles where id = p_partner) then
    raise exception 'Partner not found.';
  end if;
  if exists (select 1 from public.match_players
              where match_id = p_match and player_id = p_partner) then
    raise exception 'That partner is already in this match.';
  end if;
  if exists (select 1 from public.match_invites
              where match_id = p_match and invitee_id = p_partner
                and status = 'pending') then
    raise exception 'They already have a pending invite to this match.';
  end if;

  insert into public.match_invites (match_id, inviter_id, invitee_id, team)
  values (p_match, v_uid, p_partner, p_team)
  returning id into v_invite;

  select name into v_name from public.profiles where id = v_uid;
  select scheduled_at, match_type into v_when, v_type
    from public.matches where id = p_match;

  insert into public.notifications (user_id, type, title, body, data)
  values (p_partner, 'match', 'Partner invite',
          coalesce(v_name, 'A player') || ' wants you as their partner on ' ||
            to_char(v_when, 'Dy DD Mon') || ' at ' || to_char(v_when, 'HH24:MI') ||
            '. Accept to join the match.',
          jsonb_build_object('match_id', p_match, 'invite_id', v_invite,
                             'action', 'partner_invite'));
end $$;
grant execute on function public._invite_partner(uuid, uuid, text) to authenticated;

-- ── answering an invite ───────────────────────────────────────────────────

create or replace function public.respond_match_invite(
  p_invite uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_inv     public.match_invites;
  v_status  text;
  v_when    timestamptz;
  v_name    text;
  v_taken   int;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select * into v_inv from public.match_invites where id = p_invite for update;
  if not found then return 'Invite not found.'; end if;
  if v_inv.invitee_id <> v_uid then return 'This invite isn''t yours.'; end if;
  if v_inv.status <> 'pending' then
    return 'You already answered this invite.';
  end if;

  select name into v_name from public.profiles where id = v_uid;

  -- ── decline: free the slot, tell the inviter ──
  if not coalesce(p_accept, false) then
    update public.match_invites
       set status = 'declined', responded_at = now() where id = p_invite;
    insert into public.notifications (user_id, type, title, body, data)
    values (v_inv.inviter_id, 'match', 'Partner invite declined',
            coalesce(v_name, 'Your partner') ||
              ' can''t make it — the spot is open to anyone now.',
            jsonb_build_object('match_id', v_inv.match_id));
    return null;
  end if;

  -- ── accept: re-check everything, the world moved while they thought ──
  select status, scheduled_at into v_status, v_when
    from public.matches where id = v_inv.match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status = 'cancelled' then return 'That match was cancelled.'; end if;
  if v_status <> 'open'     then return 'This match is no longer open.'; end if;
  if now() >= v_when        then return 'That match has already started.'; end if;

  if exists (select 1 from public.match_players
              where match_id = v_inv.match_id and player_id = v_uid) then
    update public.match_invites
       set status = 'accepted', responded_at = now() where id = p_invite;
    return null;
  end if;

  -- Our own reservation is one of these seats, so exclude it before counting.
  if (select count(*) from public.match_players
       where match_id = v_inv.match_id and team = v_inv.team) >= 2 then
    update public.match_invites
       set status = 'cancelled', responded_at = now() where id = p_invite;
    return 'That spot was taken before you answered.';
  end if;

  -- Suppress the generic "someone joined" ping: we send a tailored one below.
  perform set_config('padel.invite_accept', '1', true);
  insert into public.match_players (match_id, player_id, team)
  values (v_inv.match_id, v_uid, v_inv.team);

  update public.match_invites
     set status = 'accepted', responded_at = now() where id = p_invite;

  insert into public.notifications (user_id, type, title, body, data)
  values (v_inv.inviter_id, 'match', 'Partner confirmed',
          coalesce(v_name, 'Your partner') || ' accepted and is in the match.',
          jsonb_build_object('match_id', v_inv.match_id));

  select count(*) into v_taken from public.match_players
   where match_id = v_inv.match_id;
  if v_taken >= 4 then
    update public.matches set status = 'full' where id = v_inv.match_id;
  end if;
  return null;
end $$;
grant execute on function public.respond_match_invite(uuid, boolean) to authenticated;

-- The invitee's own list, for the inbox. Dead invites (match started, closed or
-- cancelled) are filtered out by the same rule that stops them reserving.
create or replace function public.my_match_invites()
returns table (
  invite_id      uuid,
  match_id       uuid,
  inviter_id     uuid,
  inviter_name   text,
  inviter_avatar text,
  match_type     text,
  scheduled_at   timestamptz,
  venue          text,
  court          text,
  team           text,
  created_at     timestamptz
)
language sql stable security definer set search_path = public as $$
  select i.id, i.match_id, i.inviter_id, p.name, p.avatar_url,
         m.match_type, m.scheduled_at, c.venue_name, c.name, i.team, i.created_at
    from public.match_invites i
    join public.matches  m on m.id = i.match_id
    join public.profiles p on p.id = i.inviter_id
    left join public.courts c on c.id = m.court_id
   where i.invitee_id = auth.uid()
     and i.status = 'pending'
     and m.status = 'open'
     and now() < m.scheduled_at
   order by m.scheduled_at asc;
$$;
grant execute on function public.my_match_invites() to authenticated;

-- What the lobby renders in a reserved slot. Name only — never a phone number;
-- that is the whole point of this change.
create or replace function public.match_pending_invites(p_match uuid)
returns table (
  invite_id      uuid,
  invitee_id     uuid,
  invitee_name   text,
  invitee_avatar text,
  team           text,
  is_me          boolean
)
language sql stable security definer set search_path = public as $$
  select i.id, i.invitee_id, p.name, p.avatar_url, i.team,
         (i.invitee_id = auth.uid())
    from public.match_invites i
    join public.profiles p on p.id = i.invitee_id
    join public.matches  m on m.id = i.match_id
   where i.match_id = p_match
     and i.status = 'pending'
     and m.status = 'open'
     and now() < m.scheduled_at
     and (exists (select 1 from public.match_players mp
                   where mp.match_id = p_match and mp.player_id = auth.uid())
          or i.invitee_id = auth.uid()
          or i.inviter_id = auth.uid());
$$;
grant execute on function public.match_pending_invites(uuid) to authenticated;

-- ── create_match: partner becomes an invite ───────────────────────────────

create or replace function public.create_match(
  p_competitive  boolean,
  p_scheduled_at timestamptz,
  p_court_id     uuid default null,
  p_partner_id   uuid default null,
  p_min_elo      int default 0,
  p_open         boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'Not signed in.'; end if;
  if p_scheduled_at is null then raise exception 'Pick a time for the match.'; end if;

  insert into public.matches
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_elo, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     not coalesce(p_open, true),
     coalesce(p_min_elo, 0),
     'PDL-' || upper(substr(md5(gen_random_uuid()::text), 1, 5)))
  returning id into v_id;

  insert into public.match_players (match_id, player_id, team) values (v_id, v_uid, 'a');

  -- The partner is ASKED, not added. They hold the second team-A slot while
  -- they decide; nothing about them is exposed until they accept.
  if p_partner_id is not null and p_partner_id <> v_uid then
    perform public._invite_partner(v_id, p_partner_id, 'a');
  end if;

  return v_id;
end $$;
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- ── join_match: same treatment, and respect reserved slots ────────────────

create or replace function public.join_match(
  p_match_id uuid, p_team text default null, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_elo int;
  v_my_elo int;
  v_partner_elo int;
  v_team text;
  v_team_a int;
  v_team_b int;
  v_need int;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

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

  -- Bringing a partner: validate them before we touch anything.
  if p_partner_id is not null then
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    select coalesce(elo, 1000) into v_partner_elo from profiles where id = p_partner_id;
    if not found then return 'Partner not found.'; end if;
    if v_partner_elo < v_min_elo then
      return 'Your partner needs ' || v_min_elo || '+ ELO for this match.';
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
grant execute on function public.join_match(uuid, text, uuid) to authenticated;

-- ── mm_accept: same treatment ─────────────────────────────────────────────

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
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at
    into v_status, v_created_by, v_center, v_created_at
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_created_by = v_uid then return 'This is your own match.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

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
        from profiles where id = p_partner_id;
      if abs(coalesce(v_partner_rating, 2.0) - v_center) > v_hw then
        return 'Your partner is outside this match''s rating band.';
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
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- ── leaving / cancelling drops the invites you raised ─────────────────────

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

  -- Anyone you were still waiting on stops being waited on.
  update public.match_invites
     set status = 'cancelled', responded_at = now()
   where match_id = p_match_id and inviter_id = v_uid and status = 'pending';

  update matches set status = 'open' where id = p_match_id and status = 'full';
  -- if the creator left and nobody is in the match, cancel it
  delete from matches m where m.id = p_match_id
    and not exists (select 1 from match_players mp where mp.match_id = m.id);
  return null;
end $$;
grant execute on function public.leave_match(uuid) to authenticated;

create or replace function public.cancel_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_creator uuid; v_status text;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  select created_by, status into v_creator, v_status
    from public.matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_creator <> v_uid and not public._is_admin() then
    return 'Only the host can cancel this match.';
  end if;
  if v_status in ('completed', 'cancelled') then
    return 'This match is already ' || v_status || '.';
  end if;
  update public.matches set status = 'cancelled' where id = p_match_id;

  -- Tell anyone still holding an invite, then close it.
  insert into public.notifications (user_id, type, title, body, data)
  select i.invitee_id, 'match', 'Match cancelled',
         'The match you were invited to was cancelled.',
         jsonb_build_object('match_id', p_match_id)
    from public.match_invites i
   where i.match_id = p_match_id and i.status = 'pending';
  update public.match_invites
     set status = 'cancelled', responded_at = now()
   where match_id = p_match_id and status = 'pending';

  insert into public.notifications (user_id, type, title, body, data)
  select mp.player_id, 'match', 'Match cancelled',
         'The host cancelled this match.', jsonb_build_object('match_id', p_match_id)
    from public.match_players mp
   where mp.match_id = p_match_id and mp.player_id <> v_uid;
  return null;
end $$;
grant execute on function public.cancel_match(uuid) to authenticated;

-- ── the join notification ─────────────────────────────────────────────────
-- An accepted invite sends its own tailored "Partner confirmed", so the generic
-- "someone joined your match" is suppressed for that insert. The old
-- `padel.partner_add` branch is left in place but is now unreachable from
-- create/join/mm_accept — nothing adds a partner directly any more.

create or replace function public.notify_match_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_host        uuid;
  v_joiner      text;
  v_host_name   text;
  v_partner_add boolean;
begin
  if coalesce(current_setting('padel.invite_accept', true), '') = '1' then
    return new;
  end if;

  select created_by into v_host from public.matches where id = new.match_id;
  if v_host is null then return new; end if;

  v_partner_add := coalesce(current_setting('padel.partner_add', true), '') = '1';

  if v_partner_add then
    if new.player_id <> v_host then
      select name into v_host_name from public.profiles where id = v_host;
      insert into public.notifications (user_id, type, title, body, data)
      values (new.player_id, 'match', 'You were added to a match',
              coalesce(v_host_name, 'A player') || ' added you to their match.',
              jsonb_build_object('match_id', new.match_id));
    end if;
    return new;
  end if;

  if new.player_id <> v_host then
    select name into v_joiner from public.profiles where id = new.player_id;
    insert into public.notifications (user_id, type, title, body, data)
    values (v_host, 'match', 'Someone joined your match',
            coalesce(v_joiner, 'A player') || ' joined your match.',
            jsonb_build_object('match_id', new.match_id));
  end if;
  return new;
end $$;

-- ── the ticket opens when an opponent shows up ────────────────────────────
-- Was: a trigger on `matches` INSERT, so the thread (and every number in it)
-- existed before anyone else had joined. Now it opens on the join that first
-- puts a player on both sides.

create or replace function public.open_match_ticket_on_join()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.match_players
              where match_id = new.match_id and team = 'a')
     and exists (select 1 from public.match_players
                  where match_id = new.match_id and team = 'b') then
    insert into public.match_tickets (match_id)
    values (new.match_id)
    on conflict (match_id) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists trg_open_match_ticket on public.matches;
drop trigger if exists trg_open_match_ticket_join on public.match_players;
create trigger trg_open_match_ticket_join
  after insert on public.match_players
  for each row execute function public.open_match_ticket_on_join();

-- Retire tickets the old backfill opened for one-sided matches. Only ones with
-- no messages — an existing conversation is never deleted.
delete from public.match_tickets t
 where not exists (select 1 from public.ticket_messages tm where tm.ticket_id = t.id)
   and not (exists (select 1 from public.match_players mp
                     where mp.match_id = t.match_id and mp.team = 'a')
        and exists (select 1 from public.match_players mp
                     where mp.match_id = t.match_id and mp.team = 'b'));

-- Open one for any match that already has both sides but lost its ticket above
-- (or never got one because it filled before this change).
insert into public.match_tickets (match_id)
select m.id from public.matches m
 where m.status <> 'cancelled'
   and now() < m.scheduled_at + interval '24 hours'
   and exists (select 1 from public.match_players mp
                where mp.match_id = m.id and mp.team = 'a')
   and exists (select 1 from public.match_players mp
                where mp.match_id = m.id and mp.team = 'b')
on conflict (match_id) do nothing;

notify pgrst, 'reload schema';

-- ============================================================
-- Number requests + phone privacy (2026-08-10). Supersedes ticket_roster
-- ABOVE. Being in a match with someone stops being enough to see their
-- number: inside a ticket you ask and they accept (a mutual swap), and
-- everywhere else `profiles.phone_public` (default FALSE) decides whether
-- co-players see it without asking. See
-- changes/2026-08-10_number_requests.sql for the full write-up.
-- ============================================================

-- ── the switch ────────────────────────────────────────────────────────────

-- Private by default. The whole point of this change is that being in a match
-- with someone stops being enough, so the safe value is the default value.
alter table public.profiles
  add column if not exists phone_public boolean not null default false;

-- ── who may see whom ──────────────────────────────────────────────────────

-- An accepted swap. Stored once per pair with a_id < b_id so the pair has ONE
-- canonical row and "did we swap" is a primary-key lookup in either direction.
create table if not exists public.contact_shares (
  a_id       uuid not null references public.profiles(id) on delete cascade,
  b_id       uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (a_id, b_id)
);
alter table public.contact_shares drop constraint if exists contact_shares_order_chk;
alter table public.contact_shares add  constraint contact_shares_order_chk
  check (a_id < b_id);

create table if not exists public.number_requests (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid references public.match_tickets(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  target_id    uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);
alter table public.number_requests drop constraint if exists number_requests_status_chk;
alter table public.number_requests add  constraint number_requests_status_chk
  check (status in ('pending', 'accepted', 'declined'));

-- One live ask per direction per pair. Partial, so a decline doesn't block a
-- later ask in a different match.
create unique index if not exists number_requests_one_live
  on public.number_requests (requester_id, target_id) where status = 'pending';
create index if not exists idx_number_requests_target
  on public.number_requests (target_id, status);

-- Canonical pair order, so callers never have to think about it.
create or replace function public._pair_lo(a uuid, b uuid)
returns uuid language sql immutable as $$ select least(a, b); $$;
create or replace function public._pair_hi(a uuid, b uuid)
returns uuid language sql immutable as $$ select greatest(a, b); $$;

-- Have these two swapped?
create or replace function public._has_share(p_one uuid, p_two uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.contact_shares
     where a_id = public._pair_lo(p_one, p_two)
       and b_id = public._pair_hi(p_one, p_two));
$$;

-- THE rule for showing a phone number, in one place so every surface agrees:
-- it's mine, or we've swapped, or they chose to be public.
create or replace function public._can_see_phone(p_viewer uuid, p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_viewer is not null and (
    p_viewer = p_target
    or public._has_share(p_viewer, p_target)
    or coalesce((select phone_public from public.profiles where id = p_target), false));
$$;

grant execute on function public._has_share(uuid, uuid)     to authenticated;
grant execute on function public._can_see_phone(uuid, uuid) to authenticated;

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.contact_shares enable row level security;
drop policy if exists "contact share: mine" on public.contact_shares;
create policy "contact share: mine" on public.contact_shares
  for select using (a_id = auth.uid() or b_id = auth.uid());
grant select on public.contact_shares to authenticated;

alter table public.number_requests enable row level security;
drop policy if exists "number request: mine" on public.number_requests;
create policy "number request: mine" on public.number_requests
  for select using (requester_id = auth.uid() or target_id = auth.uid());
grant select on public.number_requests to authenticated;

-- ── asking ────────────────────────────────────────────────────────────────

create or replace function public.request_number(p_ticket uuid, p_target uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_id   uuid;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_target = v_uid then return 'That''s you.'; end if;

  -- You may only ask someone you are actually in this ticket with. Without
  -- this the RPC would be a way to ping any user id in the database.
  if not public._ticket_member(p_ticket) then
    return 'Not a member of this ticket.';
  end if;
  if not exists (
    select 1 from public.match_tickets t
      join public.match_players mp on mp.match_id = t.match_id
     where t.id = p_ticket and mp.player_id = p_target) then
    return 'That player isn''t in this match.';
  end if;

  if public._has_share(v_uid, p_target) then
    return null; -- already connected; nothing to ask for
  end if;
  if exists (select 1 from public.number_requests
              where requester_id = v_uid and target_id = p_target
                and status = 'pending') then
    return null; -- already asked; treat as success so the UI just shows Pending
  end if;

  insert into public.number_requests (ticket_id, requester_id, target_id)
  values (p_ticket, v_uid, p_target)
  returning id into v_id;

  select name into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (p_target, 'match', 'Number request',
          coalesce(v_name, 'A player') ||
            ' asked for your number so you can sort the game.' ||
            ' Accepting shares both ways.',
          jsonb_build_object('request_id', v_id, 'ticket_id', p_ticket,
                             'action', 'number_request'));
  return null;
end $$;
grant execute on function public.request_number(uuid, uuid) to authenticated;

create or replace function public.respond_number_request(
  p_request uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.number_requests;
  v_name text;
begin
  if v_uid is null then return 'Not signed in.'; end if;

  select * into v_req from public.number_requests where id = p_request for update;
  if not found then return 'Request not found.'; end if;
  if v_req.target_id <> v_uid then return 'This request isn''t yours.'; end if;
  if v_req.status <> 'pending' then return 'You already answered this.'; end if;

  update public.number_requests
     set status = case when coalesce(p_accept, false) then 'accepted' else 'declined' end,
         responded_at = now()
   where id = p_request;

  if not coalesce(p_accept, false) then
    -- Deliberately silent: telling someone they were turned down invites a
    -- second ask. The requester's row just stops showing "Pending".
    return null;
  end if;

  insert into public.contact_shares (a_id, b_id)
  values (public._pair_lo(v_uid, v_req.requester_id),
          public._pair_hi(v_uid, v_req.requester_id))
  on conflict do nothing;

  select name into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, data)
  values (v_req.requester_id, 'match', 'Number shared',
          coalesce(v_name, 'They') || ' shared their number with you.',
          jsonb_build_object('ticket_id', v_req.ticket_id,
                             'action', 'number_shared'));
  return null;
end $$;
grant execute on function public.respond_number_request(uuid, boolean) to authenticated;

-- Requests waiting on me, for the accept/decline sheet.
create or replace function public.my_number_requests()
returns table (
  request_id     uuid,
  ticket_id      uuid,
  requester_id   uuid,
  requester_name text,
  requester_avatar text,
  created_at     timestamptz
)
language sql stable security definer set search_path = public as $$
  select r.id, r.ticket_id, r.requester_id, p.name, p.avatar_url, r.created_at
    from public.number_requests r
    join public.profiles p on p.id = r.requester_id
   where r.target_id = auth.uid() and r.status = 'pending'
   order by r.created_at desc;
$$;
grant execute on function public.my_number_requests() to authenticated;

-- ── the roster, rebuilt around the rule ───────────────────────────────────
-- Same shape as before plus `share_state`, which is all the UI needs to decide
-- between showing a number, a Request button, or Pending.
--   'me'       — your own row
--   'shared'   — visible (swapped, or they are public)
--   'pending'  — you asked, no answer yet
--   'none'     — ask them

drop function if exists public.ticket_roster(uuid);
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
    p.level,
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
grant execute on function public.ticket_roster(uuid) to authenticated;

-- ── the lobby's contact sheet ─────────────────────────────────────────────
-- Replaces the profiles.phone embed in MatchService.matchCols, which shipped a
-- number to the client for every co-player and left the decision to Dart.
-- Now the number never leaves Postgres unless the rule allows it.

create or replace function public.player_phone(p_player uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return null; end if;
  -- Must actually share a match with them, so this can't be used to test the
  -- whole user table for public numbers.
  if v_uid <> p_player and not exists (
    select 1 from public.match_players a
      join public.match_players b on b.match_id = a.match_id
     where a.player_id = v_uid and b.player_id = p_player) then
    return null;
  end if;
  if not public._can_see_phone(v_uid, p_player) then return null; end if;
  return (select phone from public.profiles where id = p_player);
end $$;
grant execute on function public.player_phone(uuid) to authenticated;

-- ── the privacy screen ────────────────────────────────────────────────────

create or replace function public.set_phone_public(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  update public.profiles set phone_public = coalesce(p_on, false)
   where id = auth.uid();
end $$;
grant execute on function public.set_phone_public(boolean) to authenticated;

-- Who I've swapped with, so approving is reversible.
create or replace function public.my_contact_shares()
returns table (
  player_id  uuid,
  name       text,
  username   text,
  avatar_url text,
  since      timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.username, p.avatar_url, s.created_at
    from public.contact_shares s
    join public.profiles p
      on p.id = case when s.a_id = auth.uid() then s.b_id else s.a_id end
   where s.a_id = auth.uid() or s.b_id = auth.uid()
   order by s.created_at desc;
$$;
grant execute on function public.my_contact_shares() to authenticated;

-- Revoking cuts BOTH ways — a swap is one row, and taking your number back
-- while keeping theirs would be a strange kind of consent.
create or replace function public.revoke_contact_share(p_other uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return 'Not signed in.'; end if;
  delete from public.contact_shares
   where a_id = public._pair_lo(v_uid, p_other)
     and b_id = public._pair_hi(v_uid, p_other);
  -- Clear any answered request between the two of you so a fresh ask is
  -- possible later rather than being blocked by history.
  delete from public.number_requests
   where status <> 'pending'
     and ((requester_id = v_uid and target_id = p_other)
       or (requester_id = p_other and target_id = v_uid));
  return null;
end $$;
grant execute on function public.revoke_contact_share(uuid) to authenticated;

-- ===========================================================================
-- Delete a DM thread (2026-08-11). Supersedes dm_inbox() above.
--
-- Long-press a conversation in the Messages inbox -> Delete chat. It clears
-- YOUR copy: nothing leaves direct_messages, a conversation_clears row records
-- when you cleared it, and your surfaces are filtered to messages newer than
-- that. The other side keeps their thread, and a reported message survives the
-- reported person pressing delete.
-- Standalone delta: supabase/changes/2026-08-11_delete_chat.sql
-- ===========================================================================

create table if not exists public.conversation_clears (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  cleared_at      timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table public.conversation_clears enable row level security;

-- Your own row only. Nobody gets to learn that you cleared them.
drop policy if exists "conv clears: own read" on public.conversation_clears;
create policy "conv clears: own read" on public.conversation_clears
  for select using (user_id = auth.uid());

-- SELECT only, deliberately: clear_conversation() below is the sole writer, so
-- the participant check cannot be bypassed by writing the table directly (and
-- nobody can back-date someone else's cleared_at to hide messages from them).
grant select on public.conversation_clears to authenticated;

create or replace function public.clear_conversation(p_conversation uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not signed in.';
  end if;
  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and v_uid in (c.player_a, c.player_b)) then
    raise exception 'That conversation is not yours.';
  end if;

  insert into public.conversation_clears (conversation_id, user_id, cleared_at)
  values (p_conversation, v_uid, now())
  on conflict (conversation_id, user_id)
    do update set cleared_at = excluded.cleared_at;

  -- A thread you deleted must not keep its unread badge alive on Home.
  update public.notifications
     set read = true
   where user_id = v_uid
     and type = 'message'
     and read = false
     and data->>'conversation_id' = p_conversation::text;
end $$;
grant execute on function public.clear_conversation(uuid) to authenticated;

-- ── the inbox has to honour the clear ─────────────────────────────────────
-- Same columns as before (so `create or replace` is enough — no drop needed).
-- The only change is the conversation_clears join and the cleared_at filter
-- inside the lateral: `lm` stays an INNER join, so a conversation with nothing
-- newer than the clear produces no row and drops off the inbox entirely.
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
         lm.text,
         lm.sent_at,
         coalesce((
           select count(*)::int from public.notifications n
            where n.user_id = auth.uid()
              and n.type = 'message'
              and n.read = false
              and n.data->>'conversation_id' = c.id::text), 0)
    from public.conversations c
    join public.profiles other
      on other.id = case when c.player_a = auth.uid() then c.player_b else c.player_a end
    left join public.conversation_clears cl
      on cl.conversation_id = c.id and cl.user_id = auth.uid()
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
         and (cl.cleared_at is null or dm.sent_at > cl.cleared_at)
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
     and not public._blocked_with(other.id)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- ===========================================================================
-- Private casual matches + invite codes (2026-08-11). Supersedes create_match,
-- join_match, mm_accept, mm_candidates and mm_player_sees_match above.
--
-- matches.is_private and matches.invite_code existed from the first migration
-- and were DEAD: a code was minted for every match, nothing read it, no
-- discovery path filtered on is_private, no join path asked for a code.
-- Private is CASUAL-ONLY - a private ranked lobby is how you would farm rating
-- off a hand-picked opponent.
-- Standalone delta: supabase/changes/2026-08-11_private_casual.sql
-- ===========================================================================

-- ── code generation ───────────────────────────────────────────────────────
-- Charset excludes 0/O/1/I/L — these get read aloud and typed by hand, and
-- those four are where that goes wrong. matches_invite_code_key (a partial
-- unique index) is the real guard; the loop just retries a collision.
create or replace function public._new_invite_code()
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  charset constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  i int;
begin
  for attempt in 1..20 loop
    v_code := 'PDL-';
    for i in 1..5 loop
      v_code := v_code || substr(charset, 1 + floor(random() * length(charset))::int, 1);
    end loop;
    if not exists (select 1 from public.matches where invite_code = v_code) then
      return v_code;
    end if;
  end loop;
  -- 31^5 is ~28.6M codes; twenty collisions means something is very wrong.
  raise exception 'Could not allocate an invite code.';
end $$;

-- ── create_match: private is casual-only, and only private gets a code ────
create or replace function public.create_match(
  p_competitive  boolean,
  p_scheduled_at timestamptz,
  p_court_id     uuid default null,
  p_partner_id   uuid default null,
  p_min_elo      int default 0,
  p_open         boolean default true
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
    (status, match_type, scheduled_at, created_by, court_id, is_private, min_elo, invite_code)
  values
    ('open',
     case when p_competitive then 'ranked' else 'casual' end,
     p_scheduled_at, v_uid, p_court_id,
     v_private,
     coalesce(p_min_elo, 0),
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
grant execute on function public.create_match(boolean, timestamptz, uuid, uuid, int, boolean) to authenticated;

-- ── may this caller join a private match? ─────────────────────────────────
-- Either they were invited, or they redeemed the code THIS transaction.
-- The GUC mirrors the padel.invite_accept pattern already used by
-- respond_match_invite: set by the trusted RPC, invisible to a client, and
-- gone when the transaction ends.
create or replace function public._may_join_private(p_match uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(current_setting('padel.join_code_ok', true), '') = p_match::text then
    return true;
  end if;
  return public._invited_to_match(p_match);
end $$;

-- ── join_match: refuse a private match without the code ───────────────────
-- Only the guard is new; everything else is byte-for-byte the previous body.
create or replace function public.join_match(
  p_match_id uuid, p_team text default null, p_partner_id uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
  v_status text;
  v_min_elo int;
  v_my_elo int;
  v_partner_elo int;
  v_team text;
  v_team_a int;
  v_team_b int;
  v_need int;
  v_private boolean;
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, min_elo, is_private into v_status, v_min_elo, v_private
    from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if v_status <> 'open' then return 'This match is no longer open.'; end if;

  if coalesce(v_private, false) and not public._may_join_private(p_match_id) then
    return 'This match is private — you need its invite code.';
  end if;

  select coalesce(elo, 1000) into v_my_elo from profiles where id = v_uid;
  if v_my_elo < v_min_elo then
    return 'This match requires ' || v_min_elo || '+ ELO.';
  end if;

  if exists (select 1 from match_players where match_id = p_match_id and player_id = v_uid) then
    return null; -- already in: treat as success
  end if;

  -- Bringing a partner: validate them before we touch anything.
  if p_partner_id is not null then
    if exists (select 1 from match_players where match_id = p_match_id and player_id = p_partner_id) then
      return 'That partner is already in this match.';
    end if;
    select coalesce(elo, 1000) into v_partner_elo from profiles where id = p_partner_id;
    if not found then return 'Partner not found.'; end if;
    if v_partner_elo < v_min_elo then
      return 'Your partner needs ' || v_min_elo || '+ ELO for this match.';
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
grant execute on function public.join_match(uuid, text, uuid) to authenticated;

-- ── join by code ──────────────────────────────────────────────────────────
-- Returns (match_id, error). match_id is non-null whenever the caller ends up
-- in the match — including when they were already in it, so scanning the same
-- code twice navigates instead of erroring.
--
-- "No match with that code" covers wrong, expired and already-started codes
-- ON PURPOSE. Distinguishing them turns this into an oracle for probing which
-- codes exist.
create or replace function public.join_match_by_code(
  p_code text, p_partner_id uuid default null)
returns table (match_id uuid, error text)
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_code text;
  v_id   uuid;
  v_err  text;
begin
  if v_uid is null then
    return query select null::uuid, 'Not signed in.'::text; return;
  end if;

  -- Accept "pdl-ab12c", "PDL-AB12C", " AB12C " — people retype these from a
  -- screenshot or a voice note, so normalise rather than scold.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_code like 'PDL%' then v_code := substr(v_code, 4); end if;
  if length(v_code) <> 5 then
    return query select null::uuid, 'That code doesn''t look right — it''s 5 characters, like PDL-AB12C.'::text;
    return;
  end if;
  v_code := 'PDL-' || v_code;

  select id into v_id
    from public.matches
   where invite_code = v_code
     and is_private
     and status = 'open'
     and scheduled_at > now();
  if v_id is null then
    return query select null::uuid, 'No match with that code. Check it with whoever invited you.'::text;
    return;
  end if;

  -- Unlock the private guard for this transaction only, scoped to THIS match
  -- so it can't be leaned on to enter a different one.
  perform set_config('padel.join_code_ok', v_id::text, true);
  v_err := public.join_match(v_id, null, p_partner_id);
  perform set_config('padel.join_code_ok', '', true);

  if v_err is not null then
    return query select null::uuid, v_err; return;
  end if;
  return query select v_id, null::text;
end $$;
grant execute on function public.join_match_by_code(text, uuid) to authenticated;

-- ── mm_accept: the other direct-join RPC ──────────────────────────────────
-- It does its own band check rather than going through mm_player_sees_match,
-- so filtering the list functions does not cover it. A client can pass any
-- uuid here. Only the is_private read and the guard below it are new.
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
begin
  if v_uid is null then return 'Not signed in.'; end if;
  if p_partner_id = v_uid then p_partner_id := null; end if;

  select status, created_by, coalesce(mm_center_rating, 2.0), created_at, is_private
    into v_status, v_created_by, v_center, v_created_at, v_private
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
        from profiles where id = p_partner_id;
      if abs(coalesce(v_partner_rating, 2.0) - v_center) > v_hw then
        return 'Your partner is outside this match''s rating band.';
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
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- ── discovery: private matches are not offered ────────────────────────────
-- mm_count_candidates selects from mm_candidates, so it needs no change.
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
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
    into v_rating, v_city, v_plac from public.profiles p where p.id = v_uid;
  v_window := coalesce((select value::numeric from public.app_settings
                         where key = 'mm_time_window_hours'), 12);

  return query
  select m.id, m.scheduled_at, m.match_type,
         c.name, c.venue_name, coalesce(c.city, cp.city),
         cp.id, cp.name, cp.rating, cp.level,
         (select count(*)::int from public.match_players mp where mp.match_id = m.id),
         coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0),
         greatest(0, 100 - round(abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) * 40))::int
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
         then coalesce(cp.placement_played, 0) < 5
         else coalesce(cp.placement_played, 0) >= 5
              and abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0))
                  <= public.mm_band_halfwidth(extract(epoch from (now() - m.created_at)) / 60.0)
       end
     )
     and (v_city is null or coalesce(c.city, cp.city) is null or coalesce(c.city, cp.city) = v_city)
   order by abs(v_rating - coalesce(m.mm_center_rating, cp.rating, cp.level, 2.0)) asc,
            m.scheduled_at asc
   limit p_limit;
end $$;
grant execute on function public.mm_candidates(int, timestamptz, timestamptz) to authenticated;

-- ── push fan-out must not announce a private match ────────────────────────
-- Only the is_private read and the one early return are new; the rest of the
-- body is unchanged. Without this the "new match near you" notification tells
-- strangers a private match exists, which is precisely what the host asked us
-- not to do.
create or replace function public.mm_player_sees_match(p_player uuid, p_match uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_rating numeric; v_city text; v_plac boolean; v_window numeric;
  v_status text; v_cby uuid; v_center numeric; v_created timestamptz; v_sched timestamptz;
  v_court uuid; v_ccity text; v_courtcity text; v_cplac boolean; v_count int;
  v_type text; v_private boolean;
begin
  select coalesce(p.rating, p.level, 2.0), p.city, (coalesce(p.placement_played, 0) < 5)
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

  select (coalesce(placement_played, 0) < 5), city into v_cplac, v_ccity
    from public.profiles where id = v_cby;
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

-- ===========================================================================
-- Casual matches are joinable by anyone (2026-08-11). Supersedes mm_accept.
--
-- A placed player tapping Join on an unplaced host's CASUAL match got
-- "This match is outside your matchmaking pool." - the card was offered and
-- then the join refused. mm_candidates and mm_player_sees_match both exempt
-- casual from the band + placed/unplaced split; mm_accept never looked at
-- match_type at all, and it is the one the Join button calls.
-- Standalone delta: supabase/changes/2026-08-11_casual_pool_fix.sql
-- ===========================================================================

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
          from profiles where id = p_partner_id;
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
grant execute on function public.mm_accept(uuid, uuid) to authenticated;

-- ===========================================================================
-- Messages list shows the other person's photo (2026-08-11).
-- Supersedes dm_inbox above; ADDS other_avatar, hence the mandatory drop.
-- Standalone delta: supabase/changes/2026-08-11_dm_avatars.sql
-- ===========================================================================

drop function if exists public.dm_inbox();
create or replace function public.dm_inbox()
returns table (
  conversation_id uuid,
  other_id        uuid,
  other_name      text,
  other_username  text,
  other_avatar    text,
  last_text       text,
  last_at         timestamptz,
  unread          int
) language sql stable security definer set search_path = public as $$
  select c.id,
         other.id,
         other.name,
         other.username,
         other.avatar_url,
         lm.text,
         lm.sent_at,
         coalesce((
           select count(*)::int from public.notifications n
            where n.user_id = auth.uid()
              and n.type = 'message'
              and n.read = false
              and n.data->>'conversation_id' = c.id::text), 0)
    from public.conversations c
    join public.profiles other
      on other.id = case when c.player_a = auth.uid() then c.player_b else c.player_a end
    left join public.conversation_clears cl
      on cl.conversation_id = c.id and cl.user_id = auth.uid()
    join lateral (
      select dm.text, dm.sent_at
        from public.direct_messages dm
       where dm.conversation_id = c.id
         and (cl.cleared_at is null or dm.sent_at > cl.cleared_at)
       order by dm.sent_at desc
       limit 1
    ) lm on true
   where auth.uid() in (c.player_a, c.player_b)
     and not public._blocked_with(other.id)
   order by lm.sent_at desc;
$$;
grant execute on function public.dm_inbox() to authenticated;

-- ===========================================================================
-- Live match lobby (2026-08-11). Publishes match_players so the lobby updates
-- when someone joins instead of waiting for a pull-to-refresh.
-- Standalone delta: supabase/changes/2026-08-11_match_players_realtime.sql
-- ===========================================================================

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'match_players'
  ) then
    alter publication supabase_realtime add table public.match_players;
  end if;
end $$;

-- ===========================================================================
-- Rating engine V3-F5 (2026-08-13) — replaces rating engine v2 as the engine
-- that settles a competitive match.
--
-- V3-F5 was selected in the Ranking Lab (tools/ranking_simulation/). Every
-- constant below was read out of the EXECUTABLE lab config — engines.dart,
-- `final kV3F5 = kV3F.copyWith(...)`, resolved through the
-- kV3Config -> kV3E -> kV3F -> kV3F5 copyWith chain and run by
-- `HybridEngine.update`. The Dart mirror is
-- lib/backend/models/rating_engine_v3f5.dart; the two are pinned against each
-- other by test/rating_engine_v3f5_parity_test.dart, which also reads THIS
-- FILE and compares the constant block below to the Dart constants, so drift
-- between SQL and Dart fails a test rather than silently mis-rating people.
--
-- WHAT CHANGES, versus v2:
--   prior      2.00 -> 3.30            sigma0     0.85 -> 0.95
--   S          0.7*result + 0.3*ratio  ->  0.85*result + 0.15*saturating margin
--   W floor    0.50 always             ->  1.00 in placement, 0.65 after
--   K          (0.04+0.31s) x1.5 <5    ->  staged 1.15/0.90/0.70 then 0.04+0.31s
--   sigma      x0.92 flat              ->  0.970 / 0.980 / 0.975 / 0.970 by band
--   precision  rating numeric(3,2)     ->  numeric(9,6)   (level stays 2dp)
--
-- WHAT DOES NOT CHANGE: the status machine, who may submit or confirm a score,
-- the rating_applied idempotency guard, season points, casual matches staying
-- unrated, the 5-match placement gate (production already used 5), anchors,
-- and the 0.00-7.00 public scale.
--
-- Safe to re-run. Run it once on live; see the header of the migration file
-- for the "only one person runs SQL" rule.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Precision. V3-F5 does no rounding internally; production stored ratings
--    at numeric(3,2) AND round()ed to 2dp on every settlement, which quantised
--    the estimate ~50x more coarsely than the deltas the engine produces
--    (a 20-match player's delta is often < 0.01). Widening to 6dp makes the
--    per-match quantisation 5e-7 — far below anything observable, and far
--    below the 0.25 step a player is shown.
--
--    `level` deliberately stays the 2dp DISPLAY mirror. Nothing reads `level`
--    back into the math; rating is the engine's number, level is the screen's.
-- ---------------------------------------------------------------------------
do $$
begin
  -- guarded: retyping is a table rewrite, so skip it once already applied
  if (select numeric_scale from information_schema.columns
       where table_schema = 'public' and table_name = 'profiles'
         and column_name = 'rating') is distinct from 6 then
    alter table public.profiles alter column rating type numeric(9,6);
  end if;
end $$;

-- New accounts start at the V3-F5 starting uncertainty. Existing rows are NOT
-- touched here — see section 9.
alter table public.profiles
  alter column sigma set default 0.95;

-- ---------------------------------------------------------------------------
-- 2. Rating history gains provenance. Legacy rows keep engine_version NULL,
--    which is how v2-settled history stays distinguishable forever.
-- ---------------------------------------------------------------------------
alter table public.ranking_history
  add column if not exists engine_version text,
  add column if not exists match_no       int,
  add column if not exists k_factor       numeric,
  add column if not exists w_opp          numeric,
  add column if not exists expected       numeric,
  add column if not exists signal         numeric;

comment on column public.ranking_history.engine_version is
  'Rating engine that produced this row. NULL = rating engine v2 (pre 2026-08-13).';
comment on column public.ranking_history.match_no is
  'This match''s 1-based ordinal in the player''s competitive career.';

create index if not exists ranking_history_engine_idx
  on public.ranking_history (engine_version);

-- ---------------------------------------------------------------------------
-- 3. The confidence flag, recalibrated to the V3-F5 sigma curve.
--
--    This is NOT the placement gate. Placement is 5 matches and is measured by
--    placement_played; after it the rating is public. is_provisional is the
--    separate "the engine is not confident yet" flag, and V3-F5 pulls the two
--    much further apart than v2 did (revealed at match 5 with sigma ~0.82).
--
--    The threshold is DERIVED, not chosen. v2 paired `sigma > 0.40` with
--    `matches < 10` because 0.85*0.92^n crosses 0.40 at exactly n=10, so both
--    clauses flipped together. The same construction on the V3-F5 curve gives
--    sigma 0.5871 after 19 matches and 0.5725 after 20, so 0.58 flips at
--    exactly the end of the last post-placement sigma band (matches >= 20).
--    Leaving it at 0.40 would have kept every player provisional until ~match
--    32 while the app told them they only needed 10.
--
--    A generated column's expression cannot be altered in place, so it is
--    dropped and re-added. Nothing in the schema depends on it (no views; the
--    admin consoles read it from PL/pgSQL functions, which are not bound at
--    DDL time).
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
begin
  select pg_get_expr(d.adbin, d.adrelid) into v_def
    from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where d.adrelid = 'public.profiles'::regclass and a.attname = 'is_provisional';
  -- guarded: dropping a stored generated column rewrites the table, so only
  -- do it when the live expression is still the v2 one
  if v_def is null or v_def not like '%0.58%' then
    alter table public.profiles drop column if exists is_provisional;
    alter table public.profiles
      add column is_provisional boolean
        generated always as (sigma > 0.58 or competitive_matches < 20) stored;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The saturating games margin — the whole of V3-F5's margin contribution.
--
--        rho  = gamesFor / (gamesFor + gamesAgainst)      (0.5 if no games)
--        rho' = 0.5 + clamp(rho - 0.5, +/-0.15) / 0.15 * 0.5
--
--    Beyond a 0.65 games ratio every scoreline is worth the same, so 6-2 6-2
--    and 6-0 6-0 carry identical weight and running up a score buys nothing.
--    rho'(for,against) + rho'(against,for) == 1 by construction, which is what
--    makes S_win + S_lose == 1.
--
--    Split out as its own immutable function so SQL and Dart share ONE
--    expression rather than two transcriptions of it.
-- ---------------------------------------------------------------------------
create or replace function public._v3f5_margin(p_for int, p_against int)
returns numeric language sql immutable as $$
  select 0.5 + (greatest(-0.15, least(0.15,
    (case when coalesce(p_for, 0) + coalesce(p_against, 0) = 0 then 0.5
          else coalesce(p_for, 0)::numeric
               / (coalesce(p_for, 0) + coalesce(p_against, 0))
     end) - 0.5)) / 0.15) * 0.5
$$;

-- ---------------------------------------------------------------------------
-- 1. _settle_rating absorbs the engine.
--
--    Previously: a dispatcher that read app_settings and delegated. Now the
--    V3-F5 body directly, with the casual guard at the top — one function, one
--    engine, nothing to select. The engine identity lives where it is actually
--    useful: stamped on every ranking_history row as engine_version.
--
--    The constant block below is still the SQL half of the Dart/SQL parity
--    test, which reads THIS function by name.
-- ---------------------------------------------------------------------------
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
  select avg(coalesce(p.rating, c_prior))  filter (where mp.team = 'a'),
         avg(coalesce(p.rating, c_prior))  filter (where mp.team = 'b'),
         avg(coalesce(p.sigma,  c_sigma0)) filter (where mp.team = 'a'),
         avg(coalesce(p.sigma,  c_sigma0)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join profiles p on p.id = mp.player_id
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
           coalesce(p.rating, c_prior)  as rating,
           coalesce(p.sigma,  c_sigma0) as sigma,
           coalesce(p.competitive_matches, 0) as cm,
           coalesce(p.is_anchor, false) as anchor
      from match_players mp join profiles p on p.id = mp.player_id
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

    update profiles set
      rating = v_after,
      -- level is the 2dp DISPLAY mirror of rating; it is never read back into
      -- the math, so display rounding cannot feed the engine.
      level  = round(v_after, 2),
      tier   = public.tier_from_level(v_after),
      sigma  = v_sig_after,
      competitive_matches = r.cm + 1,
      -- the placement counter, and with it the public reveal, at match 5
      placement_played = least(coalesce(placement_played, 0) + 1, c_placement),
      last_competitive_match_at = now()
    where id = r.player_id;

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

-- ---------------------------------------------------------------------------
-- 2. Drop what is now unreachable.
--
--    _settle_rating_v3f5 goes too: its body is _settle_rating now, and leaving
--    a second identical copy behind is how the two drift apart later. Nothing
--    calls it — every caller (confirm_match_result, admin_resolve_match,
--    expire_stale_matches, finalize_tournament) goes through _settle_rating.
-- ---------------------------------------------------------------------------
drop function if exists public._settle_rating_v2(uuid);
drop function if exists public._settle_rating_v3f5(uuid);
drop function if exists public.rating_engine_version();

delete from public.app_settings where key = 'rating_engine';

-- ---------------------------------------------------------------------------
-- 3. Prove nothing was left pointing at the removed engine.
--
--    A stale call would only surface when a match settled, which is exactly
--    when nobody wants to discover it.
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ')
    into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname <> '_settle_rating'
     and (p.prosrc like '%_settle_rating_v2%'
       or p.prosrc like '%_settle_rating_v3f5%'
       or p.prosrc like '%rating_engine_version%');
  if v_bad is not null then
    raise exception 'still referencing the removed v2 engine: %', v_bad;
  end if;

  if not exists (select 1 from pg_proc
                  where proname = '_settle_rating'
                    and pronamespace = 'public'::regnamespace) then
    raise exception '_settle_rating is missing — do not leave the DB in this state';
  end if;

  raise notice 'rating engine v2 removed. _settle_rating is V3-F5, no dispatch.';
  raise notice 'ranking_history keeps % v2-era rows (engine_version null or ''v2'').',
    (select count(*) from public.ranking_history
      where engine_version is null or engine_version = 'v2');
end $$;

grant execute on function public._settle_rating(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Existing players are NOT reset.
--
--    Ratings, sigmas, competitive_matches and all of ranking_history are left
--    exactly as they are. Established players stay ranked and keep their
--    number; players part-way through placement keep their progress and carry
--    on toward five. Only FUTURE matches settle under V3-F5.
--
--    THE SIGMA GAP IS NOW CLOSED — see
--    supabase/changes/2026-08-13_v3f5_sigma_backfill.sql, run straight after
--    this one.
--
--    The problem it solves: existing sigmas came off v2's 0.92-per-match
--    curve, which falls ~3x faster than V3-F5's, so a 10-match player carried
--    sigma ~0.43 where V3-F5 expects 0.74. K is sigma-driven, so early
--    adopters would have corrected at roughly half the intended rate — the
--    people who were here first getting a materially weaker engine than new
--    signups.
--
--    That backfill re-derives sigma from `competitive_matches` alone (which is
--    valid precisely because V3-F5's sigma carries no player information), in
--    full below 20 matches and tapering to no-change at 72. It touches sigma
--    and nothing else: no rating, no match count, no placement state. Ratings
--    and match counts remain preserved exactly as described above.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 10. Inactivity widens UNCERTAINTY only. It no longer touches the rating.
--
--     Absence is lost information, not lost skill. V3-F5 was selected with
--     `ratingInactivityDecay = false`, so a job that quietly subtracted
--     0.04/week from the skill estimate meant production was not really
--     running the engine that was validated — it was running V3-F5 during
--     matches and something else between them. The rating decay is REMOVED.
--     Nothing outside match settlement may move a rating now, except an
--     explicit admin action.
--
--     What that deleted, for the record: −0.04/week after 60 days idle,
--     floored at the division boundary (5.0 / 3.5 / 2.0) and never below 1.0,
--     for players with 5+ competitive matches. It wrote `engine_version =
--     'decay'` rows to ranking_history. Existing rows from the v2 era stay —
--     history is not rewritten, and those ratings are not restored, because
--     re-inflating people on the basis of a rule we just retired would be its
--     own unreviewed rating change. They will simply re-converge by playing.
--
--     WHAT REMAINS is the sigma half, kept and corrected. The Ranking Lab's
--     idle() helper is known-broken — `min(cap, sigma + ...)` LOWERS sigma for
--     anyone already above the cap — and is NOT ported. Production had the
--     identical bug, dormant: `least(0.60, sigma + 0.01)` never bit under v2
--     because sigma fell below 0.60 within a few matches. Under V3-F5 sigma
--     stays above 0.60 until ~match 17, so going quiet would have made the app
--     MORE confident about a player it had just stopped learning about. It is
--     monotone now — inactivity may raise uncertainty, never lower it — at v2's
--     unchanged 0.60 target and 0.01/week rate.
--
--     Raising sigma is the right response to absence on its own terms: it
--     widens K, so a returning player is re-measured quickly by playing rather
--     than being pre-emptively marked down for not playing.
--
--     The NAME is now a misnomer and is kept deliberately: the pg_cron
--     schedule stores `select public.apply_rating_decay()` as a command
--     STRING, so renaming would silently orphan the job. Note it needs pg_cron
--     enabled to run at all.
-- ---------------------------------------------------------------------------
create or replace function public.apply_rating_decay()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  update public.profiles p
     set sigma = greatest(p.sigma, least(0.60, p.sigma + 0.01))
  where coalesce(p.is_admin, false) = false and p.sigma < 0.60
    and (p.last_competitive_match_at is null
         or p.last_competitive_match_at < now() - interval '14 days');
  get diagnostics v_count = row_count;
  -- returns players whose uncertainty was widened (it used to return players
  -- whose rating was cut, which is now always zero by construction)
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Admin rating controls follow the recalibrated confidence gate.
--
--     Both RPCs used to force competitive_matches to >= 10 because that was
--     where v2's is_provisional cleared. The gate is now 20, so they push to
--     20 — otherwise "Mark anchor" would leave the player flagged provisional,
--     which is the opposite of what the action means.
--
--     Anchor ratings themselves are NOT created or recalibrated here. The
--     Ranking Lab's established pool is anchored at TRUE skill with sigma 0.25
--     for research purposes; production anchors are hand-calibrated humans and
--     are not equivalent. Reproducing the lab's pool in production would be
--     inventing data.
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_player_rating(p_player_id uuid, p_elo int)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_old_rating numeric; v_rating numeric;
begin
  if not public._can_edit('players') then return 'Not authorised.'; end if;
  v_rating := public.level_from_elo(greatest(800, least(2200, p_elo)));
  select coalesce(rating, coalesce(level, 0)) into v_old_rating
    from public.profiles where id = p_player_id;
  if not found then return 'Player not found.'; end if;
  update public.profiles set
    rating = v_rating, level = round(v_rating, 2),
    tier = public.tier_from_level(v_rating),
    elo = greatest(800, least(2200, p_elo)), sigma = 0.30,
    competitive_matches = greatest(coalesce(competitive_matches, 0), 20),
    placement_played = greatest(coalesce(placement_played, 0), 5)
  where id = p_player_id;
  insert into public.ranking_history
    (profile_id, match_id, level_before, level_after,
     rating_before, rating_after, sigma_before, sigma_after, delta, engine_version)
  values (p_player_id, null, round(v_old_rating, 2), round(v_rating, 2),
     v_old_rating, v_rating, null, 0.30, round(v_rating - v_old_rating, 6), 'admin');
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
    elo = greatest(800, least(2200, (800 + v_rating * 200)::int)),
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
-- 12. NOT IN THIS DELTA, on purpose: two admin surfaces carry their own copy
--     of the confidence rule, each buried inside a large function this change
--     otherwise has no business rewriting.
--
--       * admin_players_console  — `coalesce(p.is_provisional, cm < 5)`. The
--         coalesce fallback only fires on a database where the generated
--         column does not exist, so it is dead on live.
--       * admin_season_player    — `(v_sigma > 0.40 or v_cm < 5)`, computed
--         from scratch and therefore genuinely stale.
--
--     Both are display-only (a "Provisional" chip in the console — no money,
--     no rating, no gate), and both are corrected in
--     supabase/migration_player_app.sql, which is re-run on live. Flagged here
--     so the discrepancy is a decision on the record rather than an oversight.
-- ---------------------------------------------------------------------------

grant execute on function public._settle_rating(uuid)       to authenticated;
grant execute on function public.admin_set_player_rating(uuid, int) to authenticated;
grant execute on function public.admin_set_rating(uuid, numeric, numeric, boolean, text) to authenticated;

notify pgrst, 'reload schema';
