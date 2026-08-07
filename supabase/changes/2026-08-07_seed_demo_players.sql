-- ============================================================================
-- 2026-08-07 · SEED — 5 named players (+4 opponents) with a real match history
-- ----------------------------------------------------------------------------
-- Creates 9 brand-new accounts with complete profiles and runs 24 settled
-- ranked doubles matches through the real _settle_rating() engine, so every
-- rating / sigma / tier / ranking_history row is produced by the same maths a
-- real match would use. Nothing here computes a rating by hand (rule #2).
--
-- Requested appearance counts, hit EXACTLY:
--     Youssef Ehab 24 · Kareem Tamer 18 · Moamen Molham 13
--     Omar Mohsen 10  · Noor Eldin Mahmoud 9
-- A padel match seats 4, so 24 matches = 96 player-slots; the five above fill
-- 74 of them. The remaining 22 go to four extra club players (Adham Sherif,
-- Seif Nabil, Marwan Fouad, Hazem Ragab) — without them the counts cannot be
-- satisfied at all, since Youssef alone needs 24 matches and the other four
-- named players only supply 50 of the 72 non-Youssef slots.
--
-- These are REAL, SIGN-IN-ABLE accounts. Part 6 sets one shared password and
-- gives each an auth.identities row, and the emails follow the app's existing
-- username convention (AuthService.resolveLogin: a login with no "@" gets
-- @padelegypt.app appended), so on the sign-in screen you type just the handle:
--
--     username: youssef_ehab        password: PadelSeed2026!
--
-- CHANGE THE PASSWORD in part 6 before running if this database is public.
-- If one of these people later signs up with their own email, they get their
-- own separate account — these are not linked to anybody's real identity.
--
-- SAFE TO RE-RUN: part 3 wipes the previous run (its matches, its ranking
-- history, its season points) and puts the 9 profiles back to unranked before
-- re-seeding. It touches ONLY the 9 ids listed in part 1 — every existing
-- account in the database, including the older "Omar Mohsen" / "karim tamer" /
-- "Youssef Ehab" rows, is left completely alone.
--
-- This is data, not schema, so it is deliberately NOT folded into
-- migration_player_app.sql. Run it in the Supabase SQL editor.
-- ============================================================================


-- ── PART 1: the 9 accounts ──────────────────────────────────────────────────
-- Inserting into auth.users fires on_auth_user_created → handle_new_user(),
-- which builds the profile row from raw_user_meta_data. That is the same path a
-- real signup takes, so name / username / phone / bio / dob / gender / hand /
-- court side all land through the normal code rather than a hand-written insert.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select
  '00000000-0000-0000-0000-000000000000',
  s.id, 'authenticated', 'authenticated', s.email,
  null,                       -- real hash is set in part 6
  now(),                      -- pre-confirmed: no mail is ever sent
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object(
    'name',                 s.name,
    'username',             s.username,
    'phone',                s.phone,
    'bio',                  s.bio,
    'date_of_birth',        s.dob::text,
    'gender',               s.gender,
    'preferred_hand',       s.hand,
    'preferred_court_side', s.side
  ),
  now(), now(), '', '', '', ''
from (values
  ('5eed0000-0000-4000-8000-000000000001'::uuid, 'youssef.ehab@padelegypt.app',
   'Youssef Ehab',       'youssef_ehab',  '+20 100 220 1188',
   'Plays almost every night in New Cairo. Right side, likes the lob.',
   '1998-03-14'::date, 'male', 'right', 'right'),
  ('5eed0000-0000-4000-8000-000000000002'::uuid, 'kareem.tamer@padelegypt.app',
   'Kareem Tamer',       'kareem_tamer',  '+20 101 445 7723',
   'Left side. Came over from tennis, still hits the bandeja flat.',
   '1997-11-02'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000003'::uuid, 'moamen.molham@padelegypt.app',
   'Moamen Molham',      'moamen_molham', '+20 106 338 9014',
   'Lefty at the net. Weekend doubles regular.',
   '2000-06-21'::date, 'male', 'left',  'right'),
  ('5eed0000-0000-4000-8000-000000000004'::uuid, 'omar.mohsen@padelegypt.app',
   'Omar Mohsen',        'omar_mohsen',   '+20 122 907 4451',
   'Left side, patient from the back. Playing since 2023.',
   '1996-01-09'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000005'::uuid, 'noor.eldin@padelegypt.app',
   'Noor Eldin Mahmoud', 'noor_eldin',    '+20 128 651 3390',
   'Newest of the group. Fast hands, still learning the walls.',
   '2001-09-30'::date, 'male', 'right', 'right'),
  -- the four extra club players who fill the remaining 22 slots
  ('5eed0000-0000-4000-8000-000000000006'::uuid, 'adham.sherif@padelegypt.app',
   'Adham Sherif',       'adham_sherif',  '+20 109 774 2265',
   'Midweek regular. Big smash, streaky.',
   '1999-04-18'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000007'::uuid, 'seif.nabil@padelegypt.app',
   'Seif Nabil',         'seif_nabil',    '+20 111 502 8836',
   'Lefty. Plays the right court so the forehands sit in the middle.',
   '1995-08-07'::date, 'male', 'left',  'right'),
  ('5eed0000-0000-4000-8000-000000000008'::uuid, 'marwan.fouad@padelegypt.app',
   'Marwan Fouad',       'marwan_fouad',  '+20 114 286 6607',
   'Weekend player, mostly Fridays.',
   '2002-02-25'::date, 'male', 'right', 'right'),
  ('5eed0000-0000-4000-8000-000000000009'::uuid, 'hazem.ragab@padelegypt.app',
   'Hazem Ragab',        'hazem_ragab',   '+20 127 013 5578',
   'Steady from the back, rarely misses twice.',
   '1994-12-11'::date, 'male', 'right', 'left')
) as s(id, email, name, username, phone, bio, dob, gender, hand, side)
on conflict (id) do nothing;


-- ── PART 2: finish the profiles ─────────────────────────────────────────────
-- handle_new_user() covers everything except city, which is not part of signup
-- metadata. Also re-asserts the profile fields so a re-run repairs any drift.
update public.profiles p
   set name                 = s.name,
       username             = s.username,
       phone                = s.phone,
       bio                  = s.bio,
       city                 = 'Cairo',
       date_of_birth        = s.dob,
       gender               = s.gender,
       preferred_hand       = s.hand,
       preferred_court_side = s.side
from (values
  ('5eed0000-0000-4000-8000-000000000001'::uuid, 'Youssef Ehab',       'youssef_ehab',  '+20 100 220 1188', 'Plays almost every night in New Cairo. Right side, likes the lob.', '1998-03-14'::date, 'male', 'right', 'right'),
  ('5eed0000-0000-4000-8000-000000000002'::uuid, 'Kareem Tamer',       'kareem_tamer',  '+20 101 445 7723', 'Left side. Came over from tennis, still hits the bandeja flat.',     '1997-11-02'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000003'::uuid, 'Moamen Molham',      'moamen_molham', '+20 106 338 9014', 'Lefty at the net. Weekend doubles regular.',                         '2000-06-21'::date, 'male', 'left',  'right'),
  ('5eed0000-0000-4000-8000-000000000004'::uuid, 'Omar Mohsen',        'omar_mohsen',   '+20 122 907 4451', 'Left side, patient from the back. Playing since 2023.',              '1996-01-09'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000005'::uuid, 'Noor Eldin Mahmoud', 'noor_eldin',    '+20 128 651 3390', 'Newest of the group. Fast hands, still learning the walls.',         '2001-09-30'::date, 'male', 'right', 'right'),
  ('5eed0000-0000-4000-8000-000000000006'::uuid, 'Adham Sherif',       'adham_sherif',  '+20 109 774 2265', 'Midweek regular. Big smash, streaky.',                               '1999-04-18'::date, 'male', 'right', 'left'),
  ('5eed0000-0000-4000-8000-000000000007'::uuid, 'Seif Nabil',         'seif_nabil',    '+20 111 502 8836', 'Lefty. Plays the right court so the forehands sit in the middle.',   '1995-08-07'::date, 'male', 'left',  'right'),
  ('5eed0000-0000-4000-8000-000000000008'::uuid, 'Marwan Fouad',       'marwan_fouad',  '+20 114 286 6607', 'Weekend player, mostly Fridays.',                                    '2002-02-25'::date, 'male', 'right', 'right'),
  ('5eed0000-0000-4000-8000-000000000009'::uuid, 'Hazem Ragab',        'hazem_ragab',   '+20 127 013 5578', 'Steady from the back, rarely misses twice.',                         '1994-12-11'::date, 'male', 'right', 'left')
) as s(id, name, username, phone, bio, dob, gender, hand, side)
where p.id = s.id;

-- "Member since" would otherwise read as today, next to a match history that
-- starts in April. Backdate the join date to just before the first seeded match.
update public.profiles
   set created_at = timestamptz '2026-04-01 12:00'
 where id::text like '5eed0000-0000-4000-8000-%';
update auth.users
   set created_at = timestamptz '2026-04-01 12:00'
 where id::text like '5eed0000-0000-4000-8000-%';


-- ── PART 3: clear any previous run of THIS seed ─────────────────────────────
-- Rating settlement is one-way, so re-running must first put these 9 profiles
-- back to unranked or the second pass would stack on top of the first.
do $$
declare
  v_ids uuid[] := array[
    '5eed0000-0000-4000-8000-000000000001','5eed0000-0000-4000-8000-000000000002',
    '5eed0000-0000-4000-8000-000000000003','5eed0000-0000-4000-8000-000000000004',
    '5eed0000-0000-4000-8000-000000000005','5eed0000-0000-4000-8000-000000000006',
    '5eed0000-0000-4000-8000-000000000007','5eed0000-0000-4000-8000-000000000008',
    '5eed0000-0000-4000-8000-000000000009']::uuid[];
begin
  -- season_points only exists once the seasons change has been applied
  if to_regclass('public.season_points') is not null then
    delete from public.season_points where player_id = any(v_ids);
  end if;
  delete from public.ranking_history  where profile_id = any(v_ids);
  delete from public.match_players mp using public.matches m
    where mp.match_id = m.id and m.invite_code like 'SEED24-%';
  delete from public.matches where invite_code like 'SEED24-%';

  update public.profiles set
    rating = null, level = null, tier = null, elo = null,
    sigma = 0.85, competitive_matches = 0, placement_played = 0,
    placement_revealed = false, division_pts = 0, is_anchor = false,
    last_competitive_match_at = null
  where id = any(v_ids);
end $$;


-- ── PART 4: the 24 matches ──────────────────────────────────────────────────
-- Plan indices map to v_p[1..9] in the order listed above (0 = Youssef … 8 =
-- Hazem). Scores are team-A perspective, per set "A-B", which is what
-- _parse_set_games expects. Matches are settled in date order, and each one's
-- ranking_history rows are backdated to the match date immediately — the season
-- streak bonus counts back through that history, so the order has to be right
-- before the next match settles.
do $$
declare
  v_p uuid[] := array[
    '5eed0000-0000-4000-8000-000000000001','5eed0000-0000-4000-8000-000000000002',
    '5eed0000-0000-4000-8000-000000000003','5eed0000-0000-4000-8000-000000000004',
    '5eed0000-0000-4000-8000-000000000005','5eed0000-0000-4000-8000-000000000006',
    '5eed0000-0000-4000-8000-000000000007','5eed0000-0000-4000-8000-000000000008',
    '5eed0000-0000-4000-8000-000000000009']::uuid[];
  v_plan jsonb := '[
    {"ta":[3,2],"tb":[0,1],"w":"a","s":"7-5,6-4","d":"2026-04-17 21:00"},
    {"ta":[2,4],"tb":[1,0],"w":"b","s":"2-6,4-6","d":"2026-04-22 19:00"},
    {"ta":[2,1],"tb":[3,0],"w":"a","s":"6-4,3-6,6-2","d":"2026-04-26 21:00"},
    {"ta":[0,2],"tb":[1,3],"w":"a","s":"6-7,6-4,7-5","d":"2026-05-01 21:00"},
    {"ta":[1,0],"tb":[2,4],"w":"b","s":"2-6,4-6","d":"2026-05-05 20:00"},
    {"ta":[0,4],"tb":[1,2],"w":"a","s":"4-6,6-3,6-4","d":"2026-05-10 19:00"},
    {"ta":[3,0],"tb":[2,1],"w":"b","s":"6-7,4-6","d":"2026-05-15 21:00"},
    {"ta":[3,1],"tb":[0,6],"w":"a","s":"6-4,6-3","d":"2026-05-19 19:00"},
    {"ta":[4,0],"tb":[2,1],"w":"b","s":"4-6,6-3,2-6","d":"2026-05-24 19:00"},
    {"ta":[0,5],"tb":[4,1],"w":"a","s":"7-6,6-4","d":"2026-05-29 21:00"},
    {"ta":[1,6],"tb":[0,5],"w":"a","s":"4-6,6-3,6-4","d":"2026-06-03 20:00"},
    {"ta":[1,0],"tb":[2,8],"w":"b","s":"2-6,4-6","d":"2026-06-07 21:00"},
    {"ta":[7,1],"tb":[3,0],"w":"a","s":"6-7,6-4,7-5","d":"2026-06-12 19:00"},
    {"ta":[7,1],"tb":[8,0],"w":"b","s":"6-7,4-6","d":"2026-06-17 20:00"},
    {"ta":[6,1],"tb":[3,0],"w":"b","s":"7-6,4-6,5-7","d":"2026-06-21 20:00"},
    {"ta":[5,2],"tb":[4,0],"w":"a","s":"7-5,6-4","d":"2026-06-26 18:00"},
    {"ta":[8,0],"tb":[5,1],"w":"a","s":"6-4,3-6,6-2","d":"2026-07-01 19:00"},
    {"ta":[4,0],"tb":[2,3],"w":"a","s":"7-6,6-4","d":"2026-07-05 20:00"},
    {"ta":[8,6],"tb":[0,7],"w":"b","s":"1-6,4-6","d":"2026-07-09 20:00"},
    {"ta":[0,6],"tb":[7,4],"w":"b","s":"6-7,4-6","d":"2026-07-13 19:00"},
    {"ta":[3,0],"tb":[5,2],"w":"a","s":"7-6,6-4","d":"2026-07-17 21:00"},
    {"ta":[0,1],"tb":[2,5],"w":"a","s":"6-7,6-4,7-5","d":"2026-07-21 19:00"},
    {"ta":[8,0],"tb":[7,6],"w":"a","s":"6-4,3-6,6-2","d":"2026-07-26 19:00"},
    {"ta":[1,3],"tb":[4,0],"w":"a","s":"6-2,6-4","d":"2026-07-30 20:00"}
  ]'::jsonb;
  v_row jsonb; i int; v_idx int; v_code text; v_n int := 0;
  v_mid uuid; v_when timestamptz;
begin
  for v_row in select * from jsonb_array_elements(v_plan) loop
    v_n    := v_n + 1;
    v_code := 'SEED24-' || v_n;                       -- tag, for cleanup
    v_when := (v_row->>'d')::timestamptz;

    insert into public.matches
      (status, match_type, scheduled_at, created_by, is_private, min_elo,
       winner_team, score_team_a, score_team_b, rating_applied, invite_code,
       created_at)
    values
      ('completed', 'ranked', v_when, v_p[(v_row->'ta'->>0)::int + 1], false, 0,
       v_row->>'w', v_row->>'s', null, false, v_code, v_when)
    returning id into v_mid;

    for i in 0..1 loop
      v_idx := (v_row->'ta'->>i)::int;
      insert into public.match_players(match_id, player_id, team)
      values (v_mid, v_p[v_idx + 1], 'a');
    end loop;
    for i in 0..1 loop
      v_idx := (v_row->'tb'->>i)::int;
      insert into public.match_players(match_id, player_id, team)
      values (v_mid, v_p[v_idx + 1], 'b');
    end loop;

    perform public._settle_rating(v_mid);             -- the real engine

    -- backdate the audit rows so the rating chart plots across the season
    update public.ranking_history set created_at = v_when where match_id = v_mid;
  end loop;

  -- "last played" should be the real date, not the moment this script ran.
  -- placement_revealed is the one-time "you're placed!" celebration flag the
  -- client flips; these are established players, so mark it seen.
  update public.profiles p
     set last_competitive_match_at = x.last_at,
         placement_revealed        = true
    from (select mp.player_id, max(m.scheduled_at) as last_at
            from public.match_players mp
            join public.matches m on m.id = mp.match_id
           where m.invite_code like 'SEED24-%'
           group by mp.player_id) x
   where p.id = x.player_id;

  raise notice 'Seeded % matches for 9 players', v_n;
end $$;


-- ── PART 5: verify (expect the requested counts, exactly) ───────────────────
select p.name,
       p.username,
       p.rating,
       public.tier_from_level(p.rating)                    as tier,
       p.sigma,
       p.reliability,
       p.competitive_matches                               as played,
       (select count(*) from public.ranking_history rh
         where rh.profile_id = p.id and rh.won)             as wins,
       (select count(*) from public.ranking_history rh
         where rh.profile_id = p.id and rh.won is false)    as losses,
       p.is_provisional,
       p.onboarding_completed
  from public.profiles p
 where p.id::text like '5eed0000-0000-4000-8000-%'
 order by p.rating desc nulls last;
-- Expected played: Youssef 24, Kareem 18, Moamen 13, Omar 10, Noor 9,
--                  Adham 6, Seif 6, Marwan 5, Hazem 5.


-- ── PART 6: make the 9 accounts signable-in ─────────────────────────────────
-- Sets one shared password and gives each account the auth.identities row that
-- GoTrue looks up on email sign-in. Everything is keyed off the 9 seed ids —
-- NEVER off the @padelegypt.app domain, which real admin/staff accounts share.
--
-- >>> CHANGE v_pw BELOW BEFORE RUNNING. <<<
--
-- Both branches exist because the auth.identities column layout changed across
-- GoTrue versions: newer builds have a NOT NULL provider_id plus a generated
-- uuid id, older ones use a text id as the provider id.
create extension if not exists pgcrypto with schema extensions;

do $$
declare
  v_pw     text := 'PadelSeed2026!';        -- <<< change me
  v_schema text;
  v_hash   text;
  v_new_layout boolean;
  v_n      int;
begin
  select n.nspname into v_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_schema is null then
    raise exception 'pgcrypto is not installed — cannot hash a password';
  end if;

  -- bcrypt, exactly the hash format GoTrue writes itself
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_schema, v_schema)
     into v_hash using v_pw;

  update auth.users
     set encrypted_password = v_hash,
         email_confirmed_at = coalesce(email_confirmed_at, now()),
         banned_until       = null,
         updated_at         = now()
   where id::text like '5eed0000-0000-4000-8000-%';

  select exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'identities'
       and column_name = 'provider_id') into v_new_layout;

  if v_new_layout then
    insert into auth.identities
      (provider_id, user_id, identity_data, provider,
       last_sign_in_at, created_at, updated_at)
    select u.id::text, u.id,
           jsonb_build_object('sub', u.id::text, 'email', u.email,
                              'email_verified', true, 'phone_verified', false),
           'email', now(), now(), now()
      from auth.users u
     where u.id::text like '5eed0000-0000-4000-8000-%'
       and not exists (select 1 from auth.identities i
                        where i.user_id = u.id and i.provider = 'email');
  else
    insert into auth.identities
      (id, user_id, identity_data, provider,
       last_sign_in_at, created_at, updated_at)
    select u.id::text, u.id,
           jsonb_build_object('sub', u.id::text, 'email', u.email,
                              'email_verified', true),
           'email', now(), now(), now()
      from auth.users u
     where u.id::text like '5eed0000-0000-4000-8000-%'
       and not exists (select 1 from auth.identities i
                        where i.user_id = u.id and i.provider = 'email');
  end if;

  select count(*) into v_n from auth.users u
   where u.id::text like '5eed0000-0000-4000-8000-%'
     and u.encrypted_password is not null
     and exists (select 1 from auth.identities i
                  where i.user_id = u.id and i.provider = 'email');
  raise notice '% of 9 seed accounts can now sign in', v_n;
end $$;

-- Sign in with the handle alone (resolveLogin appends the domain):
--   youssef_ehab · kareem_tamer · moamen_molham · omar_mohsen · noor_eldin
--   adham_sherif · seif_nabil · marwan_fouad · hazem_ragab
-- Requires the Email provider to be enabled in Supabase → Authentication →
-- Providers. Nothing is ever mailed: the accounts are already confirmed.


-- ── CLEANUP (optional) — remove this seed entirely ──────────────────────────
-- Deleting the auth.users rows cascades the profiles (and identities) away.
-- Do NOT run this if anyone has since interacted with these accounts.
-- Keyed on the seed ids so real @padelegypt.app staff accounts are never hit.
--
-- delete from public.season_points   where player_id::text  like '5eed0000-0000-4000-8000-%';
-- delete from public.ranking_history where profile_id::text like '5eed0000-0000-4000-8000-%';
-- delete from public.match_players mp using public.matches m
--   where mp.match_id = m.id and m.invite_code like 'SEED24-%';
-- delete from public.matches where invite_code like 'SEED24-%';
-- delete from auth.users where id::text like '5eed0000-0000-4000-8000-%';
