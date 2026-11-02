// Tests the stopgap: the eight helpers close, and the real draw, result and finalise
// code still works when run AS a signed-in user. Nothing here can reach the live database.
import assert from 'assert';
import fs from 'fs';
import { execSync } from 'child_process';
import { fnText, fresh, makeTournament, repo } from './harness.mjs';

const ch = `${repo}/supabase/changes`;
const delta = fs.readFileSync(`${ch}/2026-11-02_stopgap_close_helpers.sql`, 'utf8');
const rollback = fs.readFileSync(`${repo}/supabase/rollbacks/2026-11-02_stopgap_close_helpers_rollback.sql`, 'utf8');
const migration = fs.readFileSync(`${repo}/supabase/migration_player_app.sql`, 'utf8').replace(/\r\n/g, '\n');

const EIGHT = [
  '_finance_core(date, date)',
  '_advance_winner(uuid, text, int, int, uuid)',
  'apply_rating_decay()',
  '_award_tournament_season_points(uuid)',
  '_award_season_points(uuid)',
  '_settle_rating(uuid)',
  '_invite_partner(uuid, uuid, text)',
  '_seed_season_defaults(uuid)',
];

// origin/master holds what live runs for draws and finalise: live has the finalise guard
// and standings, but not the grand final or the season points fix.
const master = execSync('git show origin/master:supabase/migration_player_app.sql',
  { cwd: repo, maxBuffer: 1 << 28 }).toString().replace(/\r\n/g, '\n');
const LIVE_FNS = ['_advance_winner', 'generate_draw', 'record_bracket_winner',
  '_award_tournament_season_points', 'finalize_tournament'];

// The harness has the real draw, result and finalise functions. These stand in for the
// rest, with the live signatures, called the way the repo calls them: from a definer.
const setup = (d) => d.exec(`
  create role service_role;
  grant usage on schema auth to anon, authenticated;
  create function public._finance_core(date, date) returns json language sql security definer as $$ select '{"profit":1}'::json $$;
  create function public.admin_finance_summary(date, date) returns json language sql security definer as $$ select public._finance_core($1, $2) $$;
  create function public.apply_rating_decay() returns int language sql security definer as 'select 7';
  create function public._award_season_points(uuid) returns void language sql security definer as 'select null::void';
  create function public.confirm_match_result(uuid, boolean) returns text language plpgsql security definer as $$
    begin perform public._settle_rating($1); perform public._award_season_points($1); return null; end $$;
  create function public._invite_partner(uuid, uuid, text) returns void language sql security definer as 'select null::void';
  create function public.join_match(uuid, text, uuid) returns text language plpgsql security definer as $$
    begin perform public._invite_partner($1, $3, $2); return null; end $$;
  create function public._seed_season_defaults(uuid) returns void language sql security definer as 'select null::void';
  create function public.admin_create_season(uuid) returns text language plpgsql security definer as $$
    begin perform public._seed_season_defaults($1); return null; end $$;
  -- As on Supabase: every function granted to all three roles.
  grant execute on all functions in schema public to anon, authenticated, service_role;
`);

// Draw, every result, then finalise, all AS a signed-in user. Returns finalise's answer.
async function tournamentAsUser(d, format) {
  const { t } = await makeTournament(d, format, 4);
  const run = async (sql, params) => {
    await d.exec(`set role authenticated`);
    try { return (await d.query(sql, params)).rows[0].e; } finally { await d.exec(`reset role`); }
  };
  assert.equal(await run('select public.generate_draw($1) e', [t]), null, 'draw');
  for (let played = 0; ; played++) {
    assert.ok(played < 40, 'the draw never finished');
    const open = (await d.query(
      `select id, entry1 from tournament_matches where tournament_id=$1 and winner_entry is null
        and entry1 is not null and entry2 is not null limit 1`, [t])).rows[0];
    if (!open) break;
    const e = await run(`select public.record_bracket_winner($1,$2,'6-4,6-3') e`, [open.id, open.entry1]);
    assert.ok(!e, 'result: ' + e);
  }
  const finalised = await run('select public.finalize_tournament($1) e', [t]);
  const points = (await d.query(`select count(*)::int n from season_points where tournament_id=$1`, [t])).rows[0].n;
  return { finalised, points };
}

const db = await fresh();
for (const f of LIVE_FNS) await db.exec(fnText(f, master));
await setup(db);
const can = async (role, fn) =>
  (await db.query(`select has_function_privilege($1,$2,'execute') p`, [role, 'public.' + fn])).rows[0].p;
const exposed = async () => {
  const out = [];
  for (const f of EIGHT) for (const r of ['anon', 'authenticated']) if (await can(r, f)) out.push(`${r} ${f}`);
  return out;
};
assert.equal((await exposed()).length, 16, 'all eight open before, as in the audit');

// 1. A caller-rights user of a helper stops the delta before anything changes.
await db.exec(`create function public._drift() returns void language plpgsql as $$ begin perform public._settle_rating(null); end $$;`);
await assert.rejects(db.exec(delta), /Stopgap stopped, nothing changed.*function _drift/);
assert.equal((await exposed()).length, 16, 'nothing closed after stopping');
await db.exec(`drop function public._drift();`);
await db.exec(`create table public.t_pol (id int); alter table public.t_pol enable row level security;
  create policy pol on public.t_pol using (public._finance_core(null, null) is not null);`);
await assert.rejects(db.exec(delta), /policy pol/);
await db.exec(`drop table public.t_pol;`);
console.log('stops first, changing nothing, if a function or policy running as the caller uses a helper');

// 2. Applies, and its own verify rows all pass.
const res = await db.exec(delta);
const rows = res[res.length - 1].rows;
assert.equal(rows.length, 13);
for (const r of rows) assert.equal(r.ok, true, r.check_name);
console.log(`verify: ${rows.length}/${rows.length} ok`);
assert.deepEqual(await exposed(), []);
for (const f of EIGHT) assert.equal(await can('service_role', f), true, 'service role keeps ' + f);

// 3. Direct calls are refused, for both client roles.
const u = '00000000-0000-0000-0000-000000000000';
for (const role of ['anon', 'authenticated']) {
  for (const call of [
    `select public._finance_core(current_date, current_date)`,
    `select public._advance_winner('${u}', 'wb', 1, 0, '${u}')`,
    `select public.apply_rating_decay()`,
    `select public._award_tournament_season_points('${u}')`,
    `select public._award_season_points('${u}')`,
    `select public._settle_rating('${u}')`,
    `select public._invite_partner('${u}', '${u}', 'a')`,
    `select public._seed_season_defaults('${u}')`,
  ]) {
    await db.exec(`set role ${role}`);
    await assert.rejects(db.query(call), /permission denied/, `${role}: ${call}`);
    await db.exec(`reset role`);
  }
}
console.log('every direct call refused, for anon and for signed-in users');

// 4. The whole tournament path still works, run AS a signed-in user, on live's code.
{
  const { finalised, points } = await tournamentAsUser(db, 'double_elim');
  assert.match(finalised, /rated/, finalised);
  assert.ok(points > 0, 'season points landed');
  console.log(`live's code, as a signed-in user: draw, every result and finalise work, ${points} season point rows`);
}

// And on the code that replaces it, once the grand final delta has run.
{
  const next = await fresh(`${ch}/2026-11-02_grand_final.sql`);
  await setup(next);
  await next.exec(delta);
  const { finalised, points } = await tournamentAsUser(next, 'double_elim');
  assert.match(finalised, /rated/, finalised);
  assert.ok(points > 0, 'season points landed');
  console.log(`grand final code, as a signed-in user: same, ${points} season point rows`);
}

// 5. The other wrappers, as a signed-in user.
await db.exec(`set role authenticated`);
assert.deepEqual((await db.query(`select public.admin_finance_summary(current_date, current_date) r`)).rows[0].r, { profit: 1 });
for (const call of [
  `select public.confirm_match_result('${u}', true)`,
  `select public.join_match('${u}', 'a', '${u}')`,
  `select public.admin_create_season('${u}')`,
]) await db.query(call);
await db.exec(`reset role`);
assert.equal((await db.query(`select public.apply_rating_decay() n`)).rows[0].n, 7, 'the owner, as cron runs it, can still call decay');
console.log('reports, confirm, join and new season work; the owner can still run the decay job');

// 6. Re-running is safe, and replacing a function body keeps it closed.
for (const r of (await db.exec(delta)).at(-1).rows) assert.equal(r.ok, true);
await db.exec(`create or replace function public._finance_core(date, date) returns json language sql security definer as $$ select '{}'::json $$;`);
assert.deepEqual(await exposed(), []);
console.log('safe to re-run; replacing a function keeps it closed');

// 7. The migration can't reopen them on a re-run: no grants, and the revokes come last.
for (const f of EIGHT) {
  const name = f.slice(0, f.indexOf('('));
  assert.ok(!new RegExp(`^\\s*grant\\s[^;]*\\b${name}\\b`, 'im').test(migration), 'migration grants ' + name);
  const line = `revoke all on function public.${f} from public, anon, authenticated;`;
  assert.ok(migration.includes(line), 'migration revoke ' + f);
  const lastDef = migration.lastIndexOf(`function public.${name}(`.replace('function', 'create or replace function'));
  assert.ok(lastDef < migration.lastIndexOf(line), 'revoke comes after the definition of ' + name);
}
console.log('migration: no grants left, and each revoke follows the last definition');

// 8. Rollback restores what the audit showed.
await db.exec(rollback);
assert.equal((await exposed()).length, 16);
console.log('rollback restores the previous grants');
console.log('ALL PASSED');
process.exit(0);
