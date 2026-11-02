// Tests the payment status delta: every state a paid entry can be in, on the real SQL.
// Nothing here can reach the live database. node payment.mjs [path-to-schema-dump]
// LOCKDOWN=1 also applies the lock-down proposal first (needs the dump).
import assert from 'assert';
import fs from 'fs';
import { PGlite } from '@electric-sql/pglite';
import { fnText, repo } from './harness.mjs';
import { loadDump } from './live_schema.mjs';

const ch = `${repo}/supabase/changes`;
const delta = fs.readFileSync(`${ch}/2026-11-02_payment_status.sql`, 'utf8');
const rollback = fs.readFileSync(`${repo}/supabase/rollbacks/2026-11-02_payment_status_rollback.sql`, 'utf8');
const noSelf = fs.readFileSync(`${ch}/2026-11-02_entries_no_self_write.sql`, 'utf8');
const noSelfRb = fs.readFileSync(`${repo}/supabase/rollbacks/2026-11-02_entries_no_self_write_rollback.sql`, 'utf8');

const dump = process.argv[2];
const db = new PGlite();
if (dump) {
  const failed = await loadDump(db, dump);
  console.log(`dump loaded, ${failed.length} statement(s) didn't`);
  for (const f of failed) console.log('  ', f.what, '->', f.why);
} else {
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
  grant usage on schema public, auth to anon, authenticated;
  create table profiles (id uuid primary key default gen_random_uuid(), name text,
    gender text, is_admin boolean default false);
  create table player_ratings (player_id uuid primary key, rating numeric);
  create function rating_prior() returns numeric language sql as 'select 3.30';
  create function tournament_reg_deadline(date, text) returns timestamptz language sql as 'select null::timestamptz';
  -- The organiser check: only the test's organiser.
  create function owns_tournament(uuid) returns boolean language sql stable as
    $$ select current_setting('test.owner', true) = 'yes' $$;
  create table tournaments (id uuid primary key default gen_random_uuid(), name text default 'Open D',
    status text default 'open', start_date date default '2026-11-06', start_time text default '5:00 PM',
    capacity int default 12, min_rating numeric default 0, max_rating numeric, entry_fee int default 500,
    registration_opens date, registration_closed boolean default false, category text default 'open',
    organizer_id uuid);
  create table tournament_entries (id uuid primary key default gen_random_uuid(), tournament_id uuid references tournaments,
    player_id uuid, player_name text, partner_id uuid, partner_name text, status text default 'pending',
    paid_amount int, payment_method text, instapay_sender text, instapay_proof_url text,
    refund_status text not null default 'none', fee_mode text, payer_paid boolean default false,
    partner_paid boolean default false, partner_instapay_sender text, partner_instapay_proof_url text,
    registered_at timestamptz default now(), unique (tournament_id, player_id));
  create table notifications (id uuid primary key default gen_random_uuid(), user_id uuid, type text,
    title text, body text, data jsonb, created_at timestamptz default now());
  grant select on tournament_entries to anon, authenticated;
  alter table tournament_entries enable row level security;
  create policy "entries readable" on tournament_entries for select using (true);
  create policy "register self" on tournament_entries for insert with check (auth.uid() = player_id);
  create policy "withdraw self" on tournament_entries for update using (auth.uid() = player_id);
  grant insert, update on tournament_entries to authenticated;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`);
for (const f of ['pay_partner_share']) await db.exec(fnText(f));
}

// Apply, as Supabase would have it: every function granted by default.
const res = await db.exec(delta);
const verify = res[res.length - 1].rows;
for (const r of verify) assert.equal(r.ok, true, r.check_name);
console.log(`verify: ${verify.length}/${verify.length} ok`);
await db.exec(delta); // safe to re-run
// Exists on live; the delta replaces its function.
if (!dump) {
  await db.exec(`create trigger trg_notify_tournament_entry_update after update on tournament_entries
    for each row execute function notify_tournament_entry_update();`);
}
if (dump && process.env.LOCKDOWN) {
  const src = fs.readFileSync(`${repo}/supabase/proposals/2026-11-02_lock_down_functions.sql`, 'utf8');
  const rows = await db.transaction(async (tx) => (await tx.exec(src.slice(0, src.indexOf('-- ── ROLLBACK')))).at(-1).rows);
  for (const r of rows) assert.equal(r.ok, true, r.check_name);
  console.log('lock-down applied first');
}

const profile = async (name, admin = false) => {
  if (!dump) return (await db.query(`insert into profiles (name) values ($1) returning id`, [name])).rows[0].id;
  const id = (await db.query(`insert into auth.users (email) values ($1) returning id`, [`${name.replace(/\W/g, '')}@x.test`])).rows[0].id;
  await db.query(`insert into public.profiles (id, name, is_admin) values ($1,$2,$3)
    on conflict (id) do update set name = excluded.name, is_admin = excluded.is_admin`, [id, name, admin]);
  return id;
};
const mina = await profile('Mina Sobhy'), omar = await profile('Omar Hany'),
  stranger = await profile('Sara Stranger'), organiser = await profile('Org Aniser', true);

const as = async (uid, owner, sql, params) => {
  await db.exec(`select set_config('test.uid', '${uid ?? ''}', false), set_config('test.owner', '${owner ? 'yes' : 'no'}', false); set role ${uid ? 'authenticated' : 'anon'};`);
  try { return (await db.query(sql, params)).rows; } finally { await db.exec('reset role'); }
};
const rpc = async (uid, owner, sql, params) => (await as(uid, owner, `select ${sql} as e`, params))[0].e;
const entry = async (id) => (await db.query(`select * from tournament_entries where id=$1`, [id])).rows[0];
const notes = async (who) => (await db.query(`select title, body from notifications where user_id=$1 order by created_at`, [who])).rows;
const clearNotes = () => db.exec('delete from notifications');
const newT = async (cap = 12) => (await db.query(`insert into tournaments (name, status, start_date, start_time, entry_fee, capacity, organizer_id)
  values ('Open D', 'open', '2026-11-06', '5:00 PM', 500, $1, $2) returning id`, [cap, organiser])).rows[0].id;
const proof = (uid) => `proofs/${uid}/x.jpg`;
const register = async (t, mode) => {
  const e = await rpc(mina, false, `register_for_tournament($1,$2,'Omar Hany','mina@instapay',$3,$4)`, [t, omar, proof(mina), mode]);
  assert.equal(e, null, e);
  return (await db.query(`select id from tournament_entries where tournament_id=$1 and player_id=$2`, [t, mina])).rows[0].id;
};
const reject = (id, opts = {}) => rpc(organiser, true,
  `reject_tournament_entry($1,$2,$3,$4,$5)`,
  [id, opts.reason ?? "Amount doesn't match", opts.note ?? null, opts.money ?? false, opts.hold ?? 24]);

// ── Pending, paying for both ───────────────────────────────────────────────
{
  const t = await newT();
  await clearNotes();
  const id = await register(t, 'both');
  assert.equal((await entry(id)).status, 'pending');
  const n = await notes(omar);
  assert.equal(n.length, 1);
  assert.match(n[0].title, /^Mina registered you, payment under review$/);
  assert.ok(!/paid/i.test(n[0].title + n[0].body), 'partner is not told it is paid');
  console.log('pending, both: partner told "under review", never "paid"');

  // Confirmed.
  await clearNotes();
  assert.equal(await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]), null);
  assert.equal((await entry(id)).status, 'paid');
  for (const who of [mina, omar]) {
    const [c] = await notes(who);
    assert.equal(c.title, "You're confirmed for Open D");
    assert.equal(c.body, 'Payment verified. See you Fri 6 Nov, 5:00 PM.');
  }
  console.log('confirmed: both players get the exact copy');
}

// ── Split: 0, 1, 2 shares verified ─────────────────────────────────────────
{
  const t = await newT();
  const id = await register(t, 'split');
  let e = await entry(id);
  assert.deepEqual([e.status, e.payer_paid, e.partner_paid], ['pending', false, false]);
  await clearNotes();
  assert.equal(await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]), null);
  e = await entry(id);
  assert.deepEqual([e.status, e.payer_paid, e.partner_paid], ['pending', true, false]);
  assert.equal((await notes(omar))[0].body, "Mina's share is verified, waiting for yours.");
  assert.equal((await notes(mina))[0].body, "Your share is verified, waiting for Omar's.");
  await clearNotes();
  await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]);
  assert.equal((await notes(omar)).length, 0, 'verifying twice says nothing new');
  assert.equal(await rpc(omar, false, `pay_partner_share($1,'omar@instapay',$2)`, [id, proof(omar)]), null);
  await clearNotes();
  assert.equal(await rpc(organiser, true, `verify_entry_share($1,'partner')`, [id]), null);
  e = await entry(id);
  assert.deepEqual([e.status, e.payer_paid, e.partner_paid], ['paid', true, true]);
  assert.match((await notes(omar))[0].title, /confirmed/);
  console.log('split 0/1/2 verified: each step tells both players, confirmed only at 2');
}

// ── Rejected with a hold, then resubmitted, then confirmed ─────────────────
{
  const t = await newT();
  const id = await register(t, 'both');
  assert.match(await rpc(stranger, false, `reject_tournament_entry($1,'Other','x',false,24)`, [id]), /Not your tournament/);
  assert.match(await reject(id, { reason: 'Because' }), /Pick a reason/);
  assert.match(await reject(id, { reason: 'Other' }), /Add a note/);
  assert.match(await reject(id, { hold: 500 }), /up to 7 days/);
  await clearNotes();
  assert.equal(await reject(id, { note: 'We received EGP 500.', money: true }), null);
  let e = await entry(id);
  assert.equal(e.status, 'rejected');
  assert.ok(new Date(e.hold_until) > new Date());
  assert.equal(e.refund_status, 'none', 'no refund flag while they can still fix it');
  for (const who of [mina, omar]) {
    const [m] = await notes(who);
    assert.equal(m.title, "We couldn't verify your payment");
    assert.match(m.body, /Amount doesn't match\. We received EGP 500\. Your spot is held until/);
  }
  console.log('rejected with hold: stays held, both told the reason, no refund yet');

  // Who can read the reason.
  const read = (uid, owner) => as(uid, owner, `select reason, note from tournament_entry_rejections where entry_id=$1`, [id]);
  assert.equal((await read(mina)).length, 1, 'registrant reads it');
  assert.equal((await read(omar)).length, 1, 'partner reads it');
  assert.equal((await read(organiser, true)).length, 1, 'organiser reads it');
  assert.equal((await read(stranger)).length, 0, 'another player does not');
  await assert.rejects(read(null), /permission denied/, 'signed out does not');
  console.log('the reason is readable by the pair and the organiser only');

  // Resubmit rules.
  assert.match(await rpc(stranger, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(stranger)]), /isn't your/);
  assert.match(await rpc(mina, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(omar)]), /screenshot/, 'someone else\'s file');
  assert.match(await rpc(mina, false, `resubmit_payment_proof($1,$2,'  ')`, [id, proof(mina)]), /username/);
  await clearNotes();
  assert.equal(await rpc(mina, false, `resubmit_payment_proof($1,$2,'new@instapay')`, [id, proof(mina)]), null);
  e = await entry(id);
  assert.equal(e.status, 'pending');
  assert.equal(e.hold_until, null);
  assert.ok(e.proof_resubmitted_at);
  assert.equal(e.instapay_sender, 'new@instapay');
  assert.equal((await notes(organiser))[0].title, 'New payment proof, verify');
  assert.equal((await db.query(`select count(*)::int n from tournament_entry_rejections where entry_id=$1`, [id])).rows[0].n, 1,
    'the organiser can still see the earlier problem');
  console.log('resubmitted: same entry, back to pending, organisers told');

  // Replace while simply pending works too, and confirmed clears the history.
  assert.equal(await rpc(mina, false, `resubmit_payment_proof($1,$2,'again@instapay')`, [id, proof(mina)]), null);
  assert.equal(await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]), null);
  e = await entry(id);
  assert.equal(e.status, 'paid');
  assert.equal(e.proof_resubmitted_at, null);
  assert.equal((await db.query(`select count(*)::int n from tournament_entry_rejections where entry_id=$1`, [id])).rows[0].n, 0);
  assert.match(await rpc(mina, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(mina)]), /already been decided/);
  console.log('confirmed: history cleared, and no more resubmitting');
}

// ── Hold expired ───────────────────────────────────────────────────────────
{
  const t = await newT(1);
  const id = await register(t, 'both');
  assert.equal(await reject(id, { money: true }), null);
  // Still holds the only spot.
  const other = await profile('Hana Other');
  assert.match(await rpc(other, false, `register_for_tournament($1,null,null,'h@instapay',$2,'both')`, [t, proof(other)]), /full/);
  await db.query(`update tournament_entries set hold_until = now() - interval '1 minute' where id=$1`, [id]);
  await clearNotes();
  // A player trying to fix it after the hold is told plainly, and the spot goes.
  assert.match(await rpc(mina, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(mina)]), /hold ended/);
  let e = await entry(id);
  assert.equal(e.status, 'withdrawn');
  assert.equal(e.refund_status, 'due', 'money was logged, so the refund is flagged');
  assert.equal(e.hold_until, null);
  assert.equal((await notes(omar))[0].title, 'Your spot was released');
  assert.equal((await db.query(`select count(*)::int n from tournament_entry_rejections where entry_id=$1`, [id])).rows[0].n, 1,
    'the reason survives, so the player can still see why');
  assert.equal(await rpc(other, false, `register_for_tournament($1,null,null,'h@instapay',$2,'both')`, [t, proof(other)]), null, 'the spot is free');
  console.log('hold expired: withdrawn, refund flagged, players told, spot free, reason kept');
}
{
  // Expiry is also found by registration alone, and with no money there's no refund.
  const t = await newT(1);
  const id = await register(t, 'both');
  await reject(id, { money: false });
  await db.query(`update tournament_entries set hold_until = now() - interval '1 minute' where id=$1`, [id]);
  const other = await profile('Dina Other');
  assert.equal(await rpc(other, false, `register_for_tournament($1,null,null,'d@instapay',$2,'both')`, [t, proof(other)]), null);
  const e = await entry(id);
  assert.deepEqual([e.status, e.refund_status], ['withdrawn', 'none']);
  console.log('hold expired, nothing arrived: released on the next registration, no refund');
}
{
  // Registering again after being released starts clean.
  const t = await newT();
  const id = await register(t, 'both');
  await reject(id, { hold: 0 });
  assert.equal((await entry(id)).status, 'withdrawn');
  assert.equal(await register(t, 'both'), id, 'same row');
  const e = await entry(id);
  assert.equal(e.status, 'pending');
  assert.equal((await db.query(`select count(*)::int n from tournament_entry_rejections where entry_id=$1`, [id])).rows[0].n, 0);
  console.log('no hold: withdrawn straight away; registering again starts clean');
}

// ── Rejected, in a split, with one share verified ──────────────────────────
{
  const t = await newT();
  const id = await register(t, 'split');
  await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]);
  await reject(id, { reason: 'Transfer not received' });
  assert.equal((await entry(id)).status, 'rejected');
  assert.match(await rpc(mina, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(mina)]), /already verified/);
  assert.equal(await rpc(omar, false, `resubmit_payment_proof($1,$2,'o@instapay')`, [id, proof(omar)]), null);
  const e = await entry(id);
  assert.deepEqual([e.status, e.payer_paid, e.partner_instapay_sender, e.instapay_sender],
    ['pending', true, 'o@instapay', 'mina@instapay'], 'only the partner\'s half changed');
  console.log('split rejected: only the unverified player can resubmit, on their own half');
}

// ── Withdrawing while rejected ─────────────────────────────────────────────
{
  const t = await newT();
  let id = await register(t, 'both');
  await reject(id, { money: false });
  assert.equal(await rpc(mina, false, `withdraw_from_tournament($1)`, [t]), null);
  let e = await entry(id);
  assert.deepEqual([e.status, e.refund_status], ['withdrawn', 'none'], 'nothing arrived, nothing to refund');
  assert.equal((await db.query(`select count(*)::int n from tournament_entry_rejections where entry_id=$1`, [id])).rows[0].n, 0);

  const t2 = await newT();
  id = await register(t2, 'both');
  await reject(id, { money: true });
  await rpc(mina, false, `withdraw_from_tournament($1)`, [t2]);
  assert.equal((await entry(id)).refund_status, 'due');
  console.log('withdrawing while rejected: refund only if money was logged');
}

// ── Reject guards ──────────────────────────────────────────────────────────
{
  const t = await newT();
  const id = await register(t, 'both');
  await rpc(organiser, true, `verify_entry_share($1,'payer')`, [id]);
  assert.match(await reject(id), /under review/, 'a confirmed entry can\'t be rejected');
  for (const f of ['reject_tournament_entry(uuid, text, text, boolean, int)', 'resubmit_payment_proof(uuid, text, text)']) {
    await db.exec(`select set_config('test.uid','',false); set role anon`);
    await assert.rejects(db.query(`select public.${f.replace(/\(.*/, '')}(${f.includes('boolean') ? `'${u()}', 'Other', 'x', false, 1` : `'${u()}', 'x', 'y'`})`), /permission denied/);
    await db.exec('reset role');
  }
  console.log('anon can call neither RPC');
}
function u() { return '00000000-0000-0000-0000-000000000000'; }

// ── Self-confirming, and closing it ────────────────────────────────────────
{
  const t = await newT();
  const id = await register(t, 'both');
  const selfConfirm = async () => {
    await as(mina, false, `update tournament_entries set status='paid' where id=$1`, [id]);
    return (await entry(id)).status;
  };
  assert.equal(await selfConfirm(), 'paid', 'the hole, as the repo has it');
  await db.query(`update tournament_entries set status='pending' where id=$1`, [id]);
  const v = (await db.exec(noSelf)).at(-1).rows;
  assert.equal(v[0].ok, true);
  assert.equal(await selfConfirm(), 'pending', 'closed');
  await assert.rejects(as(stranger, false, `insert into tournament_entries (tournament_id, player_id, status) values ($1,$2,'paid')`, [t, stranger]), /row-level security/);
  // The RPCs still work without those policies.
  assert.equal(await rpc(mina, false, `resubmit_payment_proof($1,$2,'x@instapay')`, [id, proof(mina)]), null);
  assert.equal(await rpc(mina, false, `withdraw_from_tournament($1)`, [t]), null);
  assert.equal((await entry(id)).status, 'withdrawn');
  assert.equal(await register(t, 'both'), id, 'registering again still works');
  await db.exec(noSelfRb);
  assert.equal(await selfConfirm(), 'paid', 'rollback reopens it');
  console.log('a player could mark themselves paid; the delta closes it and the RPCs still work');
}

// ── Rollback ───────────────────────────────────────────────────────────────
if (!process.env.LOCKDOWN) {
  const t = await newT();
  const id = await register(t, 'both');
  await reject(id, { money: true });
  await db.exec(rollback);
  const e = await entry(id);
  assert.deepEqual([e.status, e.refund_status], ['withdrawn', 'due']);
  const gone = await db.query(`select to_regclass('public.tournament_entry_rejections') t`);
  assert.equal(gone.rows[0].t, null);
  assert.equal((await db.query(`select count(*)::int n from pg_proc where proname in ('reject_tournament_entry','resubmit_payment_proof','_release_expired_holds','_entry_reject_cleanup','_cairo_label')`)).rows[0].n, 0);
  const again = await newT();
  const eid = await register(again, 'both');
  assert.equal((await notes(omar)).at(-1).title, "You're in — your entry is paid", 'old copy back');
  assert.equal(await rpc(organiser, true, `verify_entry_share($1,'payer')`, [eid]), null);
  await db.exec(delta); // and it can be re-applied
  console.log('rollback restores the old functions; re-applying works');
}
console.log('ALL PASSED');
process.exit(0);
