// Loads a schema-only dump of live into an in-process Postgres, so a delta can be tested
// against the real tables, triggers, policies and grants. Nothing can reach the live
// database. The dump stays outside the repo: it can hold webhook tokens.
import fs from 'fs';

// Only what the public schema reaches outside itself: pg_dump --schema=public leaves
// these out.
const outside = `
  do $$ begin create role anon; exception when duplicate_object then null; end $$;
  do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
  do $$ begin create role service_role; exception when duplicate_object then null; end $$;
  create schema if not exists auth;
  create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
  create table if not exists auth.identities (id uuid primary key default gen_random_uuid(), user_id uuid, provider text, email text);
  create or replace function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated, service_role;
  create schema if not exists storage;
  create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
  create schema if not exists supabase_functions;
  create or replace function supabase_functions.http_request() returns trigger language plpgsql as
    $$ begin return new; end $$;
`;

/** Splits on semicolons outside quotes, dollar quotes and comments. */
export function statements(sql) {
  const out = [];
  let cur = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '-' && sql[i + 1] === '-') {
      const e = sql.indexOf('\n', i);
      i = e < 0 ? sql.length : e + 1;
      continue;
    }
    if (c === "'") {
      let j = i + 1;
      while (j < sql.length) {
        if (sql[j] === "'" && sql[j + 1] === "'") j += 2;
        else if (sql[j] === "'") break;
        else j++;
      }
      cur += sql.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    if (c === '"') {
      const j = sql.indexOf('"', i + 1);
      cur += sql.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    if (c === '$') {
      const m = /^\$\w*\$/.exec(sql.slice(i, i + 64));
      if (m) {
        const j = sql.indexOf(m[0], i + m[0].length);
        cur += sql.slice(i, j + m[0].length);
        i = j + m[0].length;
        continue;
      }
    }
    if (c === ';') {
      if (cur.trim()) out.push(cur.trim());
      cur = '';
      i++;
      continue;
    }
    cur += c;
    i++;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

const redact = (s) => String(s).replace(/Bearer\s+[A-Za-z0-9._-]+/g, 'Bearer <hidden>');

/** Returns what wouldn't load, with any token hidden. */
export async function loadDump(db, path) {
  await db.exec(outside);
  const sql = fs.readFileSync(path, 'utf8')
    .split(/\r?\n/)
    .filter((l) => !l.startsWith('\\'))
    .join('\n');
  const failed = [];
  for (let st of statements(sql)) {
    if (/^CREATE SCHEMA public$/i.test(st) || /^(ALTER|COMMENT ON) SCHEMA public\b/i.test(st)) continue;
    if (/^SET transaction_timeout/i.test(st)) continue;
    // MAINTAIN is Postgres 17. It isn't what any test here is about.
    st = st.replace(/,MAINTAIN\b/g, '').replace(/\bMAINTAIN,/g, '');
    try {
      await db.exec(st);
    } catch (e) {
      // Only Supabase's own role, which default privileges name. Nothing tested uses it.
      if (/FOR ROLE supabase_admin/.test(st)) continue;
      failed.push({ what: redact(st.split('\n')[0]).slice(0, 90), why: redact(e.message).slice(0, 110) });
    }
  }
  // pg_dump's session settings: search_path empty, RLS checks off. Back to how a real
  // session runs, or every policy here goes untested.
  await db.exec(`select set_config('search_path', 'public', false);
    set row_security = on; set check_function_bodies = on;`);
  await db.exec(`insert into public.regions (id, name, currency_code, dial_code) values ('EG', 'Egypt', 'EGP', '+20') on conflict do nothing`);
  return failed;
}
