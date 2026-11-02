// Tests the lock-down proposal on a small stub: what closes, what stays, and rollback.
import assert from 'assert';
import fs from 'fs';
import { PGlite } from '@electric-sql/pglite';
const repo = decodeURIComponent(new URL('../..', import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1').replace(/\/$/, '');
const file = `${repo}/supabase/proposals/2026-11-02_lock_down_functions.sql`;
const src = fs.readFileSync(file, 'utf8');
const db = new PGlite();
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create function auth.uid() returns uuid language sql as $$ select null::uuid $$;
  grant usage on schema public, auth to anon, authenticated;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant select on tables to anon, authenticated;

  -- Internal helper, definer: must close.
  create function public._advance_winner(uuid) returns void language sql security definer as 'select null::void';
  -- RPC the app calls: must stay signed-in only.
  create function public.generate_draw(uuid) returns text language sql security definer as 'select null::text';
  -- Signed-out RPC.
  create function public.email_exists(text) returns boolean language sql security definer as 'select false';
  -- Used by an RLS policy, and calling another: must stay for both roles.
  create function public._chain() returns boolean language sql as 'select true';
  create function public._is_admin() returns boolean language plpgsql as $$ begin return public._chain(); end $$;
  create table public.things (id int primary key, n text default null);
  alter table public.things enable row level security;
  create policy p on public.things for select using (public._is_admin());
  insert into public.things values (1, 'x');
  -- Used by a column default.
  create function public._new_code() returns text language sql as $$ select 'c' $$;
  alter table public.things alter column n set default public._new_code();
  -- A trigger function: needs no grant to fire.
  create function public._touch() returns trigger language plpgsql as $$ begin return new; end $$;
  create trigger t before update on public.things for each row execute function public._touch();
`);
const can = async (role, fn) => (await db.query(`select has_function_privilege($1,$2,'execute') p`, [role, 'public.' + fn])).rows[0].p;

assert.equal(await can('anon', '_advance_winner(uuid)'), true, 'open before: the hole being closed');

// Apply (in one transaction, because the report is a temp table on commit drop).
const main = src.slice(0, src.indexOf('-- ── ROLLBACK'));
const res = await db.transaction(async (tx) => { const r = await tx.exec(main); return r[r.length - 1].rows; });
for (const r of res) console.log(' ', r.check_name, '=', r.ok, String(r.detail).slice(0, 160));
assert.ok(res.every((r) => r.ok));

assert.equal(await can('anon', '_advance_winner(uuid)'), false, 'helper closed to anon');
assert.equal(await can('authenticated', '_advance_winner(uuid)'), false, 'helper closed to authenticated');
assert.equal(await can('service_role', '_advance_winner(uuid)'), true, 'service role keeps it');
assert.equal(await can('authenticated', 'generate_draw(uuid)'), true, 'app RPC stays');
assert.equal(await can('anon', 'generate_draw(uuid)'), false, 'app RPC not open to anon');
assert.equal(await can('anon', 'email_exists(text)'), true, 'signed-out RPC stays');
assert.equal(await can('anon', '_is_admin()'), true, 'policy helper stays');
assert.equal(await can('anon', '_chain()'), true, 'what a caller-rights helper calls stays');
assert.equal(await can('authenticated', '_new_code()'), true, 'column default stays');
assert.equal(await can('anon', '_touch()'), false, 'trigger function closes');
console.log('closed and kept as expected');

// The real test: as each role, do reads and writes still work?
await db.exec(`set role anon`);
assert.equal((await db.query(`select * from public.things`)).rows.length, 1, 'RLS read still works as anon');
await assert.rejects(db.query(`select public._advance_winner(gen_random_uuid())`), /permission denied/);
await db.exec(`reset role; update public.things set n = 'y' where id = 1;`);
console.log('RLS reads work as anon, helper refused, trigger still fires');

// Rollback restores the exact grants.
const rb = src.slice(src.indexOf('-- ── ROLLBACK'), src.indexOf('-- ── OPTIONAL')).split('\n')
  .filter((l) => l.startsWith('-- ') && !l.startsWith('-- ──')).map((l) => l.slice(3)).join('\n');
await db.exec(rb);
assert.equal(await can('anon', '_advance_winner(uuid)'), true, 'rollback reopens');
assert.equal(await can('authenticated', 'generate_draw(uuid)'), true);
console.log('rollback restored the previous grants');

// Default privileges: does a NEW function start closed, and what breaks?
const opt = src.slice(src.indexOf('-- ── OPTIONAL')).split('\n')
  .filter((l) => l.startsWith('-- alter')).map((l) => l.slice(3)).join('\n');
await db.exec(opt);
await db.exec(`create function public.brand_new_rpc() returns int language sql as 'select 1';`);
assert.equal(await can('anon', 'brand_new_rpc()'), false, 'new function closed to anon');
assert.equal(await can('authenticated', 'brand_new_rpc()'), false, 'new function closed to authenticated');
await db.exec(`create or replace function public.generate_draw(uuid) returns text language sql security definer as 'select ''x''::text';`);
assert.equal(await can('authenticated', 'generate_draw(uuid)'), true, 'create or replace keeps existing grants');
await db.exec(`drop function public.generate_draw(uuid); create function public.generate_draw(uuid) returns text language sql security definer as 'select ''x''::text';`);
assert.equal(await can('authenticated', 'generate_draw(uuid)'), false, 'drop and recreate loses the grant');
console.log('default privileges: new functions start closed; replace keeps grants; drop + create loses them');
console.log('ALL PASSED');
process.exit(0);
