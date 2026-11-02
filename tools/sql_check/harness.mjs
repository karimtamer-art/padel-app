// Runs the REAL tournament SQL from migration_player_app.sql in an in-process
// Postgres, on a stub schema. Nothing here can reach the live database.
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';

export const repo = decodeURIComponent(new URL('../..', import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1').replace(/\/$/, '');
const migration = fs.readFileSync(`${repo}/supabase/migration_player_app.sql`, 'utf8').replace(/\r\n/g, '\n');

export function fnText(name, sql = migration) {
  const start = sql.indexOf(`create or replace function public.${name}(`);
  if (start < 0) throw new Error('no function ' + name);
  const open = sql.indexOf('$$', start);
  const close = sql.indexOf('$$', open + 2);
  return sql.slice(start, sql.indexOf(';', close) + 1);
}

const schema = `
create schema if not exists auth;
create role authenticated; create role anon;
create function auth.uid() returns uuid language sql as 'select null::uuid';
create table profiles (id uuid primary key default gen_random_uuid(), name text);
create table player_ratings (player_id uuid primary key, level numeric);
create function _is_admin() returns boolean language sql as 'select false'; create function current_admin_role() returns text language sql as 'select ''organizer'''; create table tournaments (id uuid primary key default gen_random_uuid(), name text, format text, format_spec jsonb,
  rated boolean default true, rating_applied boolean default false, organizer_id uuid, status text default 'in_progress',
  region_id text default 'EG');
create table tournament_entries (id uuid primary key default gen_random_uuid(), tournament_id uuid references tournaments,
  player_id uuid, partner_id uuid, status text default 'paid', name text);
create table tournament_matches (id uuid primary key default gen_random_uuid(), tournament_id uuid not null references tournaments on delete cascade,
  bracket text not null default 'wb', round int not null, slot int not null,
  entry1 uuid references tournament_entries, entry2 uuid references tournament_entries, winner_entry uuid references tournament_entries,
  score text, stage int not null default 0, result_status text not null default 'open', submitted_winner uuid, submitted_score text, submitted_by uuid,
  unique (tournament_id, bracket, round, slot));
create table matches (id uuid primary key default gen_random_uuid(), status text, match_type text, scheduled_at timestamptz, created_by uuid,
  is_private boolean, min_rating numeric, winner_team text, score_team_a text, rating_applied boolean, invite_code text, tournament_match_id uuid);
create table match_players (match_id uuid, player_id uuid, team text);
create function _settle_rating(uuid) returns void language sql as 'select null::void';
create function owns_tournament(uuid) returns boolean language sql as 'select true';
create table seasons (id uuid primary key default gen_random_uuid(), frozen boolean default false);
create table season_rules (season_id uuid, code text, pts int);
create table season_points (season_id uuid, player_id uuid, rule_code text, pts int, tournament_id uuid, unique (season_id, player_id, rule_code, tournament_id));
create function _live_season(text) returns uuid language sql as 'select id from seasons limit 1';
`;

export async function fresh(...deltas) {
  const db = new PGlite();
  await db.exec(schema);
  await db.exec(`insert into seasons default values;
    insert into season_rules select id,'tour_win',100 from seasons;
    insert into season_rules select id,'tour_podium',40 from seasons;`);
  for (const f of ['_advance_winner', 'generate_draw', 'record_bracket_winner', '_ko_round_name', '_build_ko_round',
    'generate_from_format', 'advance_stage', '_award_tournament_season_points', 'finalize_tournament']) {
    await db.exec(fnText(f));
  }
  for (const d of deltas) await db.exec(fs.readFileSync(d, 'utf8'));
  return db;
}

/** A full tournament of n pairs, each player a real profile. */
export async function makeTournament(db, format, n, spec = null) {
  const t = (await db.query(`insert into tournaments (format, format_spec) values ($1,$2) returning id`, [format, spec])).rows[0].id;
  const ids = [];
  for (let i = 0; i < n; i++) {
    const r = await db.query(`insert into tournament_entries (tournament_id, player_id, partner_id, name)
      values ($1, gen_random_uuid(), gen_random_uuid(), $2) returning id`, [t, 'P' + String(i).padStart(2, '0')]);
    ids.push(r.rows[0].id);
  }
  return { t, ids };
}

export const ready = async (db, t) => (await db.query(
  `select id, bracket, round, slot, entry1, entry2 from tournament_matches
    where tournament_id=$1 and winner_entry is null and entry1 is not null and entry2 is not null`, [t])).rows;

/** Plays every playable match in a random order, as the organiser would. */
export async function playOut(db, t, rng = Math.random) {
  let played = 0;
  for (;;) {
    const r = await ready(db, t);
    if (!r.length) return played;
    const m = r[Math.floor(rng() * r.length)];
    const w = rng() < 0.5 ? m.entry1 : m.entry2;
    const err = (await db.query(`select record_bracket_winner($1,$2,'6-4,6-3') e`, [m.id, w])).rows[0].e;
    if (err) throw new Error(err);
    played++;
  }
}
