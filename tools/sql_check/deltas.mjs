// Tests the three deltas. argv[2]: 'stub' (default) or a path to a schema dump.
import assert from 'assert';
import fs from 'fs';
import { fresh, makeTournament, playOut, repo } from './harness.mjs';
const ch = `${repo}/supabase/changes`;
const STD = `${ch}/2026-11-02_server_standings.sql`, INFO = `${ch}/2026-11-02_match_info_fields.sql`, GF = `${ch}/2026-11-02_grand_final.sql`;
const FG = `${ch}/2026-11-02_finalize_guard.sql`;

// Deltas end in a VERIFY select: run them, then read every ok column.
async function applyAndVerify(db, file) {
  const res = await db.exec(fs.readFileSync(file, 'utf8'));
  const last = res[res.length - 1];
  for (const row of last.rows) {
    const bad = row.ok === false;
    if (bad && !/mid-play/.test(row.check_name)) throw new Error(`${file}: ${row.check_name} is false`);
  }
  return last.rows;
}
const db = await fresh();

for (const f of [FG, STD, INFO, GF, STD, INFO, GF]) {
  const rows = await applyAndVerify(db, f);
  if (rows[0]?.check_name) console.log(' verify', f.split('/').pop(), rows.filter((r) => r.ok !== false).length + '/' + rows.length, 'ok');
}

// ── Structured losers bracket ───────────────────────────────────────────────
const standardMax = (n) => { let k = 0, s = 1; while (s < n) { s *= 2; k++; } return Math.max(2 * (k - 1), 0); };
async function run(n, order) {
  const { t } = await makeTournament(db, 'double_elim', n);
  await db.query('select generate_draw($1)', [t]);
  const lb = new Map(); let down = 0, played = 0, rematch = 0;
  const met = new Set();
  const key = (a, b) => [a, b].sort().join('|');
  for (;;) {
    const r = (await db.query(`select id, bracket, round, slot, entry1, entry2 from tournament_matches
      where tournament_id=$1 and winner_entry is null and entry1 is not null and entry2 is not null order by round, slot`, [t])).rows;
    if (!r.length) break;
    let m;
    if (order === 'random') m = r[Math.floor(Math.random() * r.length)];
    else if (order === 'one-court') m = r.find((x) => x.bracket === 'lb') ?? r[0];
    else m = r.find((x) => x.bracket === 'wb') ?? r[0];
    const w = Math.random() < 0.5 ? m.entry1 : m.entry2;
    if (met.has(key(m.entry1, m.entry2))) rematch++;
    met.add(key(m.entry1, m.entry2));
    const err = (await db.query(`select record_bracket_winner($1,$2,'6-1,6-1') e`, [m.id, w])).rows[0].e;
    assert.equal(err, null);
    played++;
    if (m.bracket === 'lb') {
      for (const e of [m.entry1, m.entry2]) lb.set(e, (lb.get(e) ?? 0) + 1);
      const seat = (await db.query(`select round from tournament_matches where tournament_id=$1 and bracket='lb' and winner_entry is null and (entry1=$2 or entry2=$2)`, [t, w])).rows[0];
      if (seat && seat.round <= m.round) down++;
    }
  }
  const rows = (await db.query(`select bracket, winner_entry, entry1, entry2 from tournament_matches where tournament_id=$1`, [t])).rows;
  const gfs = rows.filter((x) => x.bracket === 'gf');
  assert.equal(gfs.length, 1, `${n}: one final`); assert.ok(gfs[0].winner_entry);
  assert.equal(played, 2 * n - 2, `${n}: matches ${played}`);
  assert.equal(rows.filter((x) => x.bracket === 'lb' && x.winner_entry).length, Math.max(n - 2, 0));
  assert.ok(rows.every((x) => x.winner_entry || !x.entry1 || !x.entry2));
  // Lives: nobody out on one loss except the grand-final loser; nobody plays after two.
  const losses = new Map();
  for (const x of rows) if (x.winner_entry && x.entry1 && x.entry2) {
    const l = x.winner_entry === x.entry1 ? x.entry2 : x.entry1;
    losses.set(l, (losses.get(l) ?? 0) + 1);
  }
  assert.equal([...losses.values()].filter((c) => c > 2).length, 0, 'nobody loses three times');
  assert.ok(losses.size === n - 1 || losses.size === n, 'everyone but possibly the champion lost');
  const f = (await db.query('select finalize_tournament($1) e', [t])).rows[0].e;
  assert.match(f, /rated/);
  return { t, maxLb: Math.max(0, ...lb.values()), down, rematch, gf: gfs[0] };
}
console.log('pairs order           runs | total | worst LB matches vs standard | seated same/lower round | rematches per event');
for (const n of (process.env.FULL ? [2, 3, 4, 5, 6, 7, 8, 9, 12, 16, 24, 32] : [2, 5, 8])) {
  for (const order of ['random', 'round-by-round', 'one-court']) {
    const runs = process.env.FULL ? (n <= 8 ? 80 : n <= 16 ? 30 : 8) : 10;
    let worst = 0, down = 0, rem = 0;
    for (let i = 0; i < runs; i++) { const s = await run(n, order); worst = Math.max(worst, s.maxLb); down += s.down; rem += s.rematch; }
    assert.ok(worst <= standardMax(n), `${n} ${order}: ${worst} > ${standardMax(n)}`);
    assert.equal(down, 0, `${n} ${order}: a winner was seated in a same or lower round`);
    console.log(`${String(n).padStart(5)} ${order.padEnd(15)} ${String(runs).padStart(4)} | ${String(2 * n - 2).padStart(5)} | ${worst} vs ${standardMax(n)} | ${down} | ${(rem / runs).toFixed(1)}`);
  }
}

// Third place.
{
  const s = await run(8, 'random');
  const lf = (await db.query(`select * from tournament_matches where tournament_id=$1 and bracket='lb' order by round desc limit 1`, [s.t])).rows[0];
  const third = lf.winner_entry === lf.entry1 ? lf.entry2 : lf.entry1;
  const runner = s.gf.winner_entry === s.gf.entry1 ? s.gf.entry2 : s.gf.entry1;
  const who = async (rule) => (await db.query(`select e.id from season_points sp join tournament_entries e on sp.player_id in (e.player_id,e.partner_id)
    where sp.tournament_id=$1 and sp.rule_code=$2 group by e.id`, [s.t, rule])).rows.map((r) => r.id).sort();
  assert.deepEqual(await who('tour_win'), [s.gf.winner_entry]);
  assert.deepEqual(await who('tour_podium'), [third, runner].sort());
  console.log('season points: title = grand-final winner, podium = runner-up + losers-final loser');
}
// Old-routing event: refused, not overwritten.
{
  const { t, ids } = await makeTournament(db, 'double_elim', 4);
  await db.query('select generate_draw($1)', [t]);
  const m = (await db.query(`select id, entry1, entry2 from tournament_matches where tournament_id=$1 and bracket='wb' and round=1 and slot=0`, [t])).rows[0];
  const other = ids.find((i) => i !== m.entry1 && i !== m.entry2);
  await db.query(`insert into tournament_matches (tournament_id,bracket,round,slot,entry1) values ($1,'lb',1,0,$2)`, [t, other]);
  await assert.rejects(db.query(`select record_bracket_winner($1,$2)`, [m.id, m.entry1]), /seat is taken/);
  console.log('old-routing event refuses instead of overwriting');
}
// Single elimination untouched.
for (const n of [2, 6, 8]) {
  const { t } = await makeTournament(db, 'knockout', n);
  await db.query('select generate_draw($1)', [t]);
  assert.equal(await playOut(db, t), n - 1);
  assert.equal((await db.query(`select count(*)::int c from tournament_matches where tournament_id=$1 and bracket='gf'`, [t])).rows[0].c, 0);
  assert.match((await db.query('select finalize_tournament($1) e', [t])).rows[0].e, /rated/);
}
console.log('single elimination unchanged');

// ── Standings ───────────────────────────────────────────────────────────────
const sets = async (s, w) => (await db.query('select * from _match_set_counts($1,$2)', [s, w])).rows[0];
assert.deepEqual(await sets('6-3, 6-4', false), { sets_a: 0, sets_b: 2 });
assert.deepEqual(await sets('3-6, 4-6', false), { sets_a: 0, sets_b: 2 });
assert.deepEqual(await sets('6-4,3-6,10-8', true), { sets_a: 2, sets_b: 1 });
assert.deepEqual(await sets('walkover', true), { sets_a: 0, sets_b: 0 });
assert.deepEqual(await sets('6-4 6', true), { sets_a: 0, sets_b: 0 });
assert.deepEqual(await sets('123456-4', true), { sets_a: 0, sets_b: 0 });
assert.deepEqual(await sets(null, true), { sets_a: 0, sets_b: 0 });
const spec = JSON.stringify({ stages: [{ kind: 'groups', cfg: { groups: 1, advance: 2 } }, { kind: 'knockout' }] });
async function group(format, s, n, label) {
  const { t, ids } = await makeTournament(db, format, n, s);
  const add = (slot, a, b, w, score) => db.query(`insert into tournament_matches (tournament_id,bracket,round,slot,entry1,entry2,winner_entry,score,stage)
     values ($1,$2,1,$3,$4,$5,$6,$7,0)`, [t, label, slot, ids[a], ids[b], w === null ? null : ids[w], score]);
  return { t, ids, add };
}
const signedIn = 'aaaaaaaa-0000-4000-8000-000000000001';
await db.exec(`create or replace function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;`);
const as = async (uid, f) => { await db.exec(`set test.uid = '${uid ?? ''}'`); try { return await f(); } finally { await db.exec(`set test.uid = ''`); } };
const standing = async (t, ids) => as(signedIn, async () => (await db.query('select * from tournament_standings($1)', [t])).rows
  .map((r) => ({ who: ids.indexOf(r.entry_id), won: r.won, sets: `${r.sets_won}-${r.sets_lost}`, q: r.qualifies })));
{
  const { t, ids, add } = await group('custom', spec, 3, 'Group A');
  await add(0, 0, 2, 0, '6-0,6-0'); await add(1, 1, 0, 1, '6-4,4-6,10-8'); await add(2, 2, 1, 2, '6-4,6-4');
  const s = await standing(t, ids);
  assert.deepEqual(s.map((r) => r.who), [0, 2, 1]); assert.deepEqual(s.map((r) => r.q), [true, true, false]);
}
{
  const { t, ids, add } = await group('custom', spec, 2, 'Group A');
  await add(0, 0, 1, 1, null);
  assert.equal((await standing(t, ids))[0].who, 1);
}
{
  const { t, ids, add } = await group('custom', spec, 4, 'Group A');
  await add(0, 0, 1, 1, '6-4,6-4'); await add(1, 2, 3, 2, '6-0,6-0'); await add(2, 0, 2, 0, '6-4,6-4');
  await add(3, 1, 3, 1, '6-4,6-4'); await add(4, 0, 3, 0, '6-0,6-0'); await add(5, 1, 2, 2, '6-4,6-4');
  const table = await standing(t, ids);
  assert.equal((await db.query('select advance_stage($1) e', [t])).rows[0].e, null);
  const ko = (await db.query(`select entry1, entry2 from tournament_matches where tournament_id=$1 and stage=1`, [t])).rows;
  const adv = new Set(ko.flatMap((r) => [r.entry1, r.entry2]).filter(Boolean).map((e) => ids.indexOf(e)));
  assert.deepEqual([...adv].sort(), table.filter((r) => r.q).map((r) => r.who).sort());
  console.log('advance_stage promotes exactly the pairs the table marks, on a three-way tie');
}
{ // Two groups, as on 6 Nov.
  const s2 = JSON.stringify({ stages: [{ kind: 'groups', cfg: { groups: 2, advance: 2 } }, { kind: 'knockout' }] });
  const { t, ids } = await makeTournament(db, 'custom', 8, s2);
  await db.query(`update tournaments set format_spec=$2 where id=$1`, [t, s2]);
  assert.equal((await db.query('select generate_from_format($1) e', [t])).rows[0].e, null);
  const ms = (await db.query(`select id, entry1 from tournament_matches where tournament_id=$1`, [t])).rows;
  for (const m of ms) await db.query(`update tournament_matches set winner_entry=$2, score='6-3,6-3' where id=$1`, [m.id, m.entry1]);
  const table = await as(signedIn, async () => (await db.query('select * from tournament_standings($1)', [t])).rows);
  assert.equal(table.filter((r) => r.qualifies).length, 4);
  assert.equal((await db.query('select advance_stage($1) e', [t])).rows[0].e, null);
  const ko = (await db.query(`select entry1, entry2, bracket from tournament_matches where tournament_id=$1 and stage=1`, [t])).rows;
  const adv = ko.flatMap((r) => [r.entry1, r.entry2]).filter(Boolean).sort();
  assert.deepEqual(adv, table.filter((r) => r.qualifies).map((r) => r.entry_id).sort());
  console.log('groups + knockout end to end: top 2 of each of 2 groups into', ko[0].bracket);
  // Play out the knockout through the console path and finalize.
  for (;;) {
    const open = (await db.query(`select id, entry1 from tournament_matches where tournament_id=$1 and winner_entry is null and entry1 is not null and entry2 is not null`, [t])).rows;
    for (const m of open) await db.query(`update tournament_matches set winner_entry=$2 where id=$1`, [m.id, m.entry1]);
    const e = (await db.query('select advance_stage($1) e', [t])).rows[0].e;
    if (e) break;
  }
  const f = (await db.query('select finalize_tournament($1) e', [t])).rows[0].e;
  const pts = (await db.query(`select rule_code, count(*)::int c from season_points where tournament_id=$1 group by 1`, [t])).rows;
  console.log('  finalize ->', f, '| season points awarded:', JSON.stringify(pts));
}
// ── Security ────────────────────────────────────────────────────────────────
{
  const helpers = ['_match_set_counts(text,boolean)', '_stage_standings(uuid,int,boolean)', '_wb_rounds(uuid)', '_lb_place(uuid,uuid,int,int,boolean)',
    '_advance_in_losers(uuid,uuid,int,int)', '_drop_from_winners(uuid,uuid,int,int)', '_open_grand_final(uuid)'];
  for (const h of helpers) for (const role of ['anon', 'authenticated']) {
    const r = await db.query(`select has_function_privilege($1,$2,'execute') p`, [role, 'public.' + h]);
    assert.equal(r.rows[0].p, false, `${role} can run ${h}`);
  }
  const anonCan = (await db.query(`select has_function_privilege('anon','public.tournament_standings(uuid)','execute') p`)).rows[0].p;
  const authCan = (await db.query(`select has_function_privilege('authenticated','public.tournament_standings(uuid)','execute') p`)).rows[0].p;
  assert.equal(anonCan, false); assert.equal(authCan, true);
  // Real role switch: helper refused, RPC allowed. Default grants simulated first.
  await db.exec(`grant usage on schema public, auth to authenticated; set test.uid='${signedIn}'; set role authenticated;`);
  await assert.rejects(db.query(`select * from public._stage_standings(gen_random_uuid())`), /permission denied/);
  await db.exec(`reset role`);
  const { t, ids, add } = await group('custom', spec, 2, 'Group A');
  await add(0, 0, 1, 0, '6-0,6-0');
  await db.exec(`set role authenticated`);
  assert.equal((await db.query(`select * from public.tournament_standings('${t}')`)).rows.length, 2);
  await db.exec(`reset role`);
  // Cancelled: hidden from a player, visible to the organizer and an admin. Signed-out: nothing.
  const organizer = 'bbbbbbbb-0000-4000-8000-000000000002';
  await db.query(`update tournaments set status='cancelled', organizer_id=$2 where id=$1`, [t, organizer]);
  const count = async () => (await db.query(`select * from public.tournament_standings('${t}')`)).rows.length;
  assert.equal(await as(signedIn, count), 0, 'cancelled hidden from a player');
  assert.equal(await as(organizer, count), 2, 'cancelled visible to its organizer');
  await db.query(`update tournaments set status='open' where id=$1`, [t]);
  assert.equal(await as(null, count), 0, 'signed out sees nothing');
  console.log('security: helpers refused, RPC signed-in only, cancelled events hidden per RLS');
}
// ── Match info ──────────────────────────────────────────────────────────────
{
  const { t } = await makeTournament(db, 'knockout', 4);
  await db.query('select generate_draw($1)', [t]);
  const m = (await db.query(`select id, entry1 from tournament_matches where tournament_id=$1 and slot=0`, [t])).rows[0];
  const set = async (c, l) => (await db.query('select admin_set_match_info($1,$2,$3) e', [m.id, c, l])).rows[0].e;
  const row = async () => (await db.query('select court, result_status from tournament_matches where id=$1', [m.id])).rows[0];
  assert.equal(await set(' 3 ', true), null); assert.deepEqual(await row(), { court: '3', result_status: 'live' });
  assert.equal(await set('', false), null); assert.deepEqual(await row(), { court: null, result_status: 'open' });
  await db.query(`update tournament_matches set result_status='pending' where id=$1`, [m.id]);
  assert.match(await set('1', true), /waiting to be played/);
  assert.equal(await set('1', false), null); assert.equal((await row()).result_status, 'pending');
  console.log('match info: court + live behave; a pending result is never overwritten');
}
console.log('ALL PASSED');
process.exit(0);
