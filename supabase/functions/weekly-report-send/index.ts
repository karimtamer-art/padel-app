// Supabase Edge Function — emails a link to the weekly profit & loss.
//
//   POST /functions/v1/weekly-report-send   { "week_start": "2026-08-03" }
//
// `week_start` is optional; with no body it reports THE WEEK THAT JUST ENDED,
// which is what the Monday cron wants. The mail carries a link, not the
// numbers: the figures stay behind one token-guarded page (see the
// `weekly-report` function) instead of sitting in an inbox forever.
//
// Two ways in, and it needs exactly one of them:
//   • `x-cron-secret: <CRON_SECRET>`  — how pg_cron calls it, unattended.
//   • a super admin's Authorization bearer token — how the console's
//     "Email report" button calls it. Verified by asking Postgres `_is_admin()`
//     with the caller's own JWT, so the app can't lie about who it is.
//
// WHO IT GOES TO. The `report_recipients` table, managed from the console —
// see 2026-08-07_report_recipients.sql. Everyone gets their own copy (Resend's
// batch endpoint) so no recipient sees another's address. REPORT_TO is now only
// a fallback, used when the list is empty or that migration hasn't been run.
//
// Secrets (never commit these):
//   supabase secrets set RESEND_API_KEY=re_...
//   supabase secrets set REPORT_FROM='Padel Rivals <reports@YOURDOMAIN>'
//   supabase secrets set REPORT_TO=padelrivals@gmail.com   # fallback only
//   supabase secrets set CRON_SECRET=<any long random string>
//
// REPORT_FROM must be a domain you have verified in Resend, or Gmail will bin
// it. Until you have, leaving it unset falls back to Resend's test sender,
// which only delivers to the address that owns the Resend account.
//
// Deploy:
//   supabase functions deploy weekly-report-send --no-verify-jwt
// (--no-verify-jwt because pg_cron sends the cron secret, not a JWT; the
// checks above are what actually guard it.)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY");
const FROM = Deno.env.get("REPORT_FROM") ?? "Padel Rivals <onboarding@resend.dev>";
const TO = Deno.env.get("REPORT_TO") ?? "padelrivals@gmail.com";
const CRON_SECRET = Deno.env.get("CRON_SECRET");
// Where the link points. Defaults to this project's own function host, which is
// right unless you put the report behind a custom domain.
const BASE = Deno.env.get("REPORT_BASE_URL") ?? `${SUPABASE_URL}/functions/v1/weekly-report`;

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

/** Monday of the week containing [d], in UTC. */
function mondayOf(d: Date): Date {
  const out = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  // getUTCDay(): 0 = Sunday. Shift so Monday is the origin.
  out.setUTCDate(out.getUTCDate() - ((out.getUTCDay() + 6) % 7));
  return out;
}

const iso = (d: Date) => d.toISOString().slice(0, 10);

function weekLabel(startIso: string, endIso: string): string {
  const a = new Date(startIso + "T00:00:00Z");
  const b = new Date(endIso + "T00:00:00Z");
  const am = MONTHS[a.getUTCMonth()], bm = MONTHS[b.getUTCMonth()];
  return am === bm
    ? `${am} ${a.getUTCDate()} – ${b.getUTCDate()}`
    : `${am} ${a.getUTCDate()} – ${bm} ${b.getUTCDate()}`;
}

/**
 * Who the report goes to. The `report_recipients` table is the source of
 * truth; REPORT_TO is the fallback for an empty list or an unrun migration, so
 * a half-set-up project still mails somebody rather than silently nobody.
 */
async function recipients(): Promise<string[]> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/report_recipients_active`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
    const rows = await res.json();
    const list = Array.isArray(rows)
      ? rows.map((r: any) => String(r?.email ?? "").trim()).filter(Boolean)
      : [];
    if (list.length) return [...new Set(list.map((e) => e.toLowerCase()))];
  } catch (e) {
    // A missing function is the expected shape of "migration not run yet".
    console.error("[weekly-report-send] recipients:", e);
  }
  return TO.split(",").map((e) => e.trim()).filter(Boolean);
}

/** Is the bearer token in [auth] a super admin? Asks Postgres, not ourselves. */
async function callerIsAdmin(auth: string): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/_is_admin`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: auth, // the CALLER's JWT — that's the whole point
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    return res.ok && (await res.json()) === true;
  } catch (e) {
    console.error("[weekly-report-send] admin check:", e);
    return false;
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // ── Who's asking ──────────────────────────────────────────────
  const cronHeader = req.headers.get("x-cron-secret");
  const auth = req.headers.get("Authorization") ?? "";
  const viaCron = !!CRON_SECRET && cronHeader === CRON_SECRET;
  const viaAdmin = !viaCron && auth.startsWith("Bearer ") && (await callerIsAdmin(auth));

  if (!viaCron && !viaAdmin) return json({ error: "not_allowed" }, 403);

  if (!RESEND_KEY) {
    return json(
      { error: "not_configured", detail: "RESEND_API_KEY is not set on this project." },
      500,
    );
  }

  // ── Which week ────────────────────────────────────────────────
  let requested: string | null = null;
  try {
    const body = await req.json();
    requested = typeof body?.week_start === "string" ? body.week_start : null;
  } catch {
    // No body at all — the cron case. Fall through to "last week".
  }
  const weekStart = requested ?? iso(
    new Date(mondayOf(new Date()).getTime() - 7 * 86_400_000),
  );

  // ── Mint (or reuse) the link ──────────────────────────────────
  let link: any;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/report_link_ensure`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_week_start: weekStart }),
    });
    if (!res.ok) throw new Error(`report_link_ensure ${res.status}: ${await res.text()}`);
    link = await res.json();
  } catch (e) {
    console.error("[weekly-report-send] mint:", e);
    return json({ error: "link_failed" }, 502);
  }
  if (!link?.token) return json({ error: "link_failed" }, 502);

  const url = `${BASE}?t=${link.token}`;
  const label = weekLabel(link.week_start, link.week_end);

  // ── Send it ───────────────────────────────────────────────────
  // Deliberately no figures in the body: the link is the report, and an inbox
  // is a worse place for the P&L than a page you can revoke.
  const html = `<!doctype html><html><body style="margin:0;padding:28px 18px;background:#E9DFCD;
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
  <div style="max-width:520px;margin:0 auto;background:#FBF6EC;border:1px solid #DBCEB6;
    border-radius:18px;padding:26px">
    <p style="margin:0 0 6px;font-size:11px;font-weight:700;letter-spacing:1.4px;
      text-transform:uppercase;color:#A2937A">Padel Rivals · weekly report</p>
    <h1 style="margin:0 0 8px;font-size:22px;font-weight:800;color:#2A2218;
      letter-spacing:-.5px">Week of ${label}</h1>
    <p style="margin:0 0 22px;font-size:14px;line-height:1.6;color:#6E6149">
      Monday to Sunday, Cairo time. The full profit &amp; loss — what came in,
      what went out, and the profit between them — is on the page below.
    </p>
    <a href="${url}" style="display:inline-block;background:#C2502A;color:#FDF6EE;
      text-decoration:none;font-weight:700;font-size:15px;padding:13px 26px;
      border-radius:12px">Open the report</a>
    <p style="margin:22px 0 0;font-size:12px;line-height:1.6;color:#A2937A">
      The link keeps working, so you can come back to this week whenever.
      Anyone holding it can read the week without logging in — treat it like the
      numbers themselves.
    </p>
  </div></body></html>`;

  const to = await recipients();
  if (!to.length) {
    return json(
      { error: "no_recipients", detail: "Nobody is on the weekly report list." },
      400,
    );
  }

  const subject = `Padel Rivals — weekly report, ${label}`;
  const text =
    `Padel Rivals — weekly report\nWeek of ${label} (Monday to Sunday, Cairo time)\n\n` +
    `Open the full profit & loss:\n${url}\n\n` +
    `The link keeps working. Anyone holding it can read the week without logging in.`;

  // One message PER recipient, not one message with everyone in `to` — nobody
  // needs to see who else gets the P&L. Resend's batch endpoint takes up to 100
  // in a single call, so this stays one request regardless of team size.
  try {
    const res = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(
        to.slice(0, 100).map((addr) => ({ from: FROM, to: [addr], subject, html, text })),
      ),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error("[weekly-report-send] resend:", res.status, detail);
      return json({ error: "send_failed", detail }, 502);
    }
  } catch (e) {
    console.error("[weekly-report-send] resend:", e);
    return json({ error: "send_failed" }, 502);
  }

  return json({ ok: true, to, sent: to.length, week_start: link.week_start, url });
});
