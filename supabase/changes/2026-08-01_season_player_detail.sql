-- ============================================================================
-- SEASON — PER-PLAYER DETAIL + VOIDABLE LEDGER ENTRIES  (2026-08-01)
--
-- Follows 2026-08-01_season_leaderboards.sql. Run that one FIRST.
--
-- Adds the season console's player table: one RPC that returns everything
-- known about a player in the season (profile, rating, standing, where every
-- point came from, and the full ledger), plus the ability to VOID a single
-- ledger entry instead of deleting it — a wrongly-awarded win stops counting
-- but the row survives for the audit trail, and it can be restored.
--
-- Safe to re-run.
-- ============================================================================

-- ── voidable ledger entries ─────────────────────────────────────────────────
alter table public.season_points add column if not exists voided      boolean not null default false;
alter table public.season_points add column if not exists void_reason text;
alter table public.season_points add column if not exists voided_by   uuid references public.profiles(id);
alter table public.season_points add column if not exists voided_at   timestamptz;

-- ── standings now ignore voided entries (the single source of rank) ─────────
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
      'is_provisional', (v_sigma > 0.40 or v_cm < 5),
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

notify pgrst, 'reload schema';
