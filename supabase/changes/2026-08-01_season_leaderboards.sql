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
create or replace function public._settle_rating(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_winner text; v_score_a text; v_applied boolean;
  v_ga int; v_gb int; v_tot int;
  v_avg_a numeric; v_avg_b numeric; v_sig_a numeric; v_sig_b numeric;
  v_e_a numeric; v_e_b numeric; v_ratio_a numeric; v_ratio_b numeric;
  v_s_a numeric; v_s_b numeric; v_w_a numeric; v_w_b numeric;
  r record; v_k numeric; v_w numeric; v_s numeric; v_e numeric;
  v_delta numeric; v_after numeric; v_sig_after numeric;
begin
  select winner_team, score_team_a, coalesce(rating_applied, false)
    into v_winner, v_score_a, v_applied
    from matches where id = p_match_id for update;
  if v_applied then return; end if;
  if v_winner is null then return; end if;

  select a, b into v_ga, v_gb from public._parse_set_games(v_score_a);
  v_ga := coalesce(v_ga, 0); v_gb := coalesce(v_gb, 0); v_tot := v_ga + v_gb;

  select avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'a'),
         avg(coalesce(p.rating, 2.0)) filter (where mp.team = 'b'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'a'),
         avg(coalesce(p.sigma, 0.85)) filter (where mp.team = 'b')
    into v_avg_a, v_avg_b, v_sig_a, v_sig_b
    from match_players mp join profiles p on p.id = mp.player_id
   where mp.match_id = p_match_id;
  v_avg_a := coalesce(v_avg_a, 2.0); v_avg_b := coalesce(v_avg_b, 2.0);
  v_sig_a := coalesce(v_sig_a, 0.85); v_sig_b := coalesce(v_sig_b, 0.85);

  v_e_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / 1.0));
  v_e_b := 1.0 / (1.0 + power(10.0, (v_avg_a - v_avg_b) / 1.0));
  v_ratio_a := case when v_tot = 0 then 0.5 else v_ga::numeric / v_tot end;
  v_ratio_b := case when v_tot = 0 then 0.5 else v_gb::numeric / v_tot end;
  v_s_a := 0.7 * (case when v_winner = 'a' then 1 else 0 end) + 0.3 * v_ratio_a;
  v_s_b := 0.7 * (case when v_winner = 'b' then 1 else 0 end) + 0.3 * v_ratio_b;
  v_w_a := 0.5 + 0.5 * (1 - v_sig_b);
  v_w_b := 0.5 + 0.5 * (1 - v_sig_a);

  -- season ladder (separate from rating) — must run on the pre-match ratings
  perform public._award_season_points(p_match_id);

  for r in
    select mp.player_id, mp.team,
           coalesce(p.rating, 2.0) as rating, coalesce(p.sigma, 0.85) as sigma,
           coalesce(p.competitive_matches, 0) as cm, coalesce(p.is_anchor, false) as anchor
      from match_players mp join profiles p on p.id = mp.player_id
     where mp.match_id = p_match_id
  loop
    if r.team = 'a' then v_s := v_s_a; v_e := v_e_a; v_w := v_w_a;
    else                 v_s := v_s_b; v_e := v_e_b; v_w := v_w_b; end if;
    v_k := 0.04 + (0.35 - 0.04) * (r.sigma / 1.0);
    if r.cm < 5 then v_k := v_k * 1.5; end if;
    v_delta := v_k * v_w * (v_s - v_e);
    if r.anchor then v_delta := greatest(-0.05, least(0.05, v_delta)); end if;
    v_after := round(greatest(0.0, least(7.0, r.rating + v_delta)), 2);
    v_sig_after := greatest(0.12, round(r.sigma * 0.92, 4));
    update profiles set
      rating = v_after, level = v_after, tier = public.tier_from_level(v_after),
      sigma = v_sig_after, competitive_matches = r.cm + 1,
      placement_played = least(coalesce(placement_played, 0) + 1, 5),
      last_competitive_match_at = now()
    where id = r.player_id;
    insert into ranking_history
      (profile_id, match_id, level_before, level_after,
       rating_before, rating_after, sigma_before, sigma_after, delta,
       opp_avg_rating, games_for, games_against, won)
    values (r.player_id, p_match_id, r.rating, v_after,
       r.rating, v_after, r.sigma, v_sig_after, round(v_after - r.rating, 2),
       round((case when r.team = 'a' then v_avg_b else v_avg_a end)::numeric, 2),
       case when r.team = 'a' then v_ga else v_gb end,
       case when r.team = 'a' then v_gb else v_ga end,
       (r.team = v_winner));
  end loop;

  update matches set rating_applied = true where id = p_match_id;
end $$;

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
                        from public.season_points sp where sp.season_id = s.id))
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
    from public.season_points sp where sp.season_id = v_s.id and sp.match_id is not null;

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

notify pgrst, 'reload schema';
