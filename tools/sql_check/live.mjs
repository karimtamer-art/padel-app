// Against a schema dump of live: applies the deltas still to run, in order, and plays
// whole tournaments as a signed-in organiser. node live.mjs <path-to-dump>
// LOCKDOWN=1 also applies the lock-down proposal first.
import assert from 'assert';
import fs from 'fs';
import { PGlite } from '@electric-sql/pglite';
import { repo } from './harness.mjs';
import { loadDump } from './live_schema.mjs';

const dump = process.argv[2];
if (!dump) throw new Error('usage: node live.mjs <path-to-dump>');
const ch = `${repo}/supabase/changes`;
const read = (f) => fs.readFileSync(f, 'utf8');

const db = new PGlite();
const failed = await loadDump(db, dump);
console.log(`dump loaded, ${failed.length} statement(s) didn't`);
for (const f of failed) console.log('  ', f.what, '->', f.why);

const applied = [
  `${ch}/2026-11-02_entries_no_self_write.sql`,
  `${ch}/2026-11-02_season_points_free_labels.sql`,
  `${ch}/2026-11-02_payment_status.sql`,
];
for (const f of applied) {
  const rows = (await db.exec(read(f))).at(-1).rows;
  for (const r of rows) assert.notEqual(r.ok, false, `${f}: ${r.check_name}`);
  console.log(`  ${f.split('/').pop()}: verify ${rows.length}/${rows.length} ok`);
}
if (process.env.LOCKDOWN) {
  const src = read(`${repo}/supabase/proposals/2026-11-02_lock_down_functions.sql`);
  const main = src.slice(0, src.indexOf('-- ── ROLLBACK'));
  const rows = await db.transaction(async (tx) => (await tx.exec(main)).at(-1).rows);
  for (const r of rows) {
    console.log('  lockdown:', r.check_name, '=', r.ok, String(r.detail ?? '').slice(0, 300));
    assert.equal(r.ok, true, r.check_name);
  }
}

const user = async (name, admin = false) => {
  const id = (await db.query(`insert into auth.users (email) values ($1) returning id`, [`${name.replace(/\W/g, '')}@x.test`])).rows[0].id;
  await db.query(`insert into public.profiles (id, name, is_admin) values ($1,$2,$3)
    on conflict (id) do update set name = excluded.name, is_admin = excluded.is_admin`, [id, name, admin]);
  return id;
};
const admin = await user('Org Aniser', true);
const asAdmin = async (sql, params) => {
  await db.exec(`select set_config('test.uid', '${admin}', false); set role authenticated;`);
  try { return (await db.query(sql, params)).rows; } finally { await db.exec('reset role'); }
};

// A live season, made the way the console makes one.
const s = (await asAdmin(`select public.admin_create_season('Season 1', '2026-01-01', '2026-12-31', null, 'EG') r`))[0].r;
await db.exec(`update public.seasons set status = 'live'`);
console.log('season ready:', JSON.stringify(s)?.slice(0, 60));

const event = async (format, pairs, spec) => {
  const t = (await db.query(`insert into public.tournaments (name, status, start_date, start_time, capacity, entry_fee, format, format_spec, organizer_id)
    values ('Event', 'open', '2026-11-06', '5:00 PM', 32, 500, $1, $2, $3) returning id`, [format, spec, admin])).rows[0].id;
  const ids = [];
  for (let i = 0; i < pairs; i++) {
    const a = await user(`P${i}a${format}`), b = await user(`P${i}b${format}`);
    ids.push((await db.query(`insert into public.tournament_entries (tournament_id, player_id, player_name, partner_id, partner_name, status, paid_amount)
      values ($1,$2,$3,$4,$5,'paid',1000) returning id`, [t, a, `P${i}a`, b, `P${i}b`])).rows[0].id);
  }
  return { t, ids };
};
const who = async (t, rule) => (await db.query(`select distinct e.id from public.season_points sp
  join public.tournament_entries e on sp.player_id in (e.player_id, e.partner_id) and e.tournament_id = sp.tournament_id
  where sp.tournament_id = $1 and sp.rule_code = $2`, [t, rule])).rows.map((r) => r.id).sort();
const open = async (t) => (await db.query(`select id, entry1, entry2, bracket from public.tournament_matches
  where tournament_id = $1 and winner_entry is null and entry1 is not null and entry2 is not null`, [t])).rows;

// ── Groups + knockout: the 6 Nov format ───────────────────────────────────
{
  const spec = JSON.stringify({ stages: [{ kind: 'groups', cfg: { groups: 2, advance: 2 } }, { kind: 'knockout' }] });
  const { t, ids } = await event('custom', 8, spec);
  // A pair under review stays out of the draw.
  const a = await user('Late A'), b = await user('Late B');
  const pending = (await db.query(`insert into public.tournament_entries (tournament_id, player_id, player_name, partner_id, partner_name, status)
    values ($1,$2,'Late A',$3,'Late B','pending') returning id`, [t, a, b])).rows[0].id;

  assert.equal((await asAdmin('select public.generate_from_format($1) e', [t]))[0].e, null, 'draw');
  const seated = (await db.query(`select count(*)::int n from public.tournament_matches where tournament_id=$1 and $2 in (entry1, entry2)`, [t, pending])).rows[0].n;
  assert.equal(seated, 0, 'pending pair not drawn');

  for (let round = 0; round < 8; round++) {
    for (const m of await open(t)) {
      assert.equal((await asAdmin(`select public.set_match_winner($1,$2,'6-3,6-3') e`, [m.id, m.entry1]))[0].e, null);
    }
    if ((await asAdmin('select public.advance_stage($1) e', [t]))[0].e) break;
  }
  const standings = await asAdmin('select * from public.tournament_standings($1)', [t]);
  assert.ok(standings.length >= 8, 'standings readable');
  const f = (await asAdmin('select public.finalize_tournament($1) e', [t]))[0].e;
  assert.match(f, /rated/, f);
  const final = (await db.query(`select * from public.tournament_matches where tournament_id=$1 and lower(bracket)='final'`, [t])).rows[0];
  assert.deepEqual(await who(t, 'tour_win'), [final.winner_entry], 'title goes to the final\'s winner');
  assert.equal((await who(t, 'tour_podium')).length, 3, 'runner-up and two semi-final losers');
  const settled = (await db.query(`select count(*)::int n from public.matches where invite_code like 'TRN-%' and rating_applied`)).rows[0].n;
  assert.ok(settled > 0, 'ratings settled');
  assert.ok(ids.length === 8);
  console.log(`groups + knockout: draw, advance, finalize; title and 3 podium pairs; ${settled} matches rated; pending pair left out`);
}

// ── Double elimination with the grand final ───────────────────────────────
{
  const { t } = await event('double_elim', 8);
  assert.equal((await asAdmin('select public.generate_draw($1) e', [t]))[0].e, null, 'draw');
  for (let i = 0; i < 40; i++) {
    const [m] = await open(t);
    if (!m) break;
    const e = (await asAdmin(`select public.record_bracket_winner($1,$2,'6-4,6-3') e`, [m.id, m.entry1]))[0].e;
    assert.ok(!e, e);
  }
  const gf = (await db.query(`select * from public.tournament_matches where tournament_id=$1 and bracket='gf'`, [t])).rows;
  assert.equal(gf.length, 1, 'one grand final, no reset');
  const f = (await asAdmin('select public.finalize_tournament($1) e', [t]))[0].e;
  assert.match(f, /rated/, f);
  assert.deepEqual(await who(t, 'tour_win'), [gf[0].winner_entry]);
  const lf = (await db.query(`select * from public.tournament_matches where tournament_id=$1 and bracket='lb' order by round desc limit 1`, [t])).rows[0];
  const third = lf.winner_entry === lf.entry1 ? lf.entry2 : lf.entry1;
  const runner = gf[0].winner_entry === gf[0].entry1 ? gf[0].entry2 : gf[0].entry1;
  assert.deepEqual(await who(t, 'tour_podium'), [third, runner].sort(), 'podium keeps the losers-final loser');
  console.log('double elimination: grand final, finalize; title, runner-up and losers-final loser on the podium');
}

// ── Knockout ──────────────────────────────────────────────────────────────
{
  const { t } = await event('knockout', 4, JSON.stringify({ stages: [{ kind: 'knockout' }] }));
  assert.equal((await asAdmin('select public.generate_from_format($1) e', [t]))[0].e, null);
  for (let round = 0; round < 6; round++) {
    for (const m of await open(t)) {
      assert.equal((await asAdmin(`select public.set_match_winner($1,$2,'6-3,6-3') e`, [m.id, m.entry1]))[0].e, null);
    }
    if ((await asAdmin('select public.advance_stage($1) e', [t]))[0].e) break;
  }
  const f = (await asAdmin('select public.finalize_tournament($1) e', [t]))[0].e;
  assert.match(f, /rated/, f);
  assert.equal((await who(t, 'tour_win')).length, 1);
  console.log('console knockout: title awarded');
}

console.log('ALL PASSED');
process.exit(0);
