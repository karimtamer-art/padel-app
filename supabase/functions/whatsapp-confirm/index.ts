// Supabase Edge Function — WhatsApp "your entry is confirmed" for website
// registrations, sent the moment staff press "Add to draw" in the console.
//
//   POST /functions/v1/whatsapp-confirm   { "registration_ids": ["<uuid>", …] }
//
// One or two ids: a pair, or two "find me a partner" solos that were just
// paired (each is told who their partner is). Everyone with a number gets a
// message — the registrant, and the partner too when they gave a number.
//
// WHO MAY CALL IT. The caller's own JWT is checked against Postgres
// `owns_tournament(tournament)` — the same gate as the entry manager — so the
// app can't lie about who it is. Deployed WITH JWT verification (default).
//
// HOW IT SENDS. WhatsApp Cloud API, an approved UTILITY template. Free-form
// text isn't allowed to someone who hasn't messaged you in the last 24h, so a
// template is the only thing that reliably arrives. Template body (submit it
// in WhatsApp Manager → Message templates, category Utility, language English):
//
//   Hi {{1}}, your entry for {{2}} is confirmed ✅
//   📅 {{3}}
//   📍 {{4}}
//   👥 Partner: {{5}}
//   See you on court! — Padel Rivals
//
// Each attempt is recorded on web_registrations (wa_status / wa_error /
// wa_sent_at) so the console can show what happened.
//
// Secrets (never commit these):
//   supabase secrets set WA_TOKEN=<permanent System User access token>
//   supabase secrets set WA_PHONE_ID=<Phone number ID from WhatsApp Manager>
//   supabase secrets set WA_TEMPLATE=entry_confirmed     # optional, default
//   supabase secrets set WA_LANG=en                      # optional, default
//   supabase secrets set WA_API_VERSION=v23.0            # optional, default
//
// Unset WA_TOKEN / WA_PHONE_ID → answers { status: "not_configured" } and the
// console offers its one-tap "send from my WhatsApp" fallback instead.
//
// Deploy:
//   supabase functions deploy whatsapp-confirm

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_TOKEN = Deno.env.get("WA_TOKEN");
const WA_PHONE_ID = Deno.env.get("WA_PHONE_ID");
const WA_TEMPLATE = Deno.env.get("WA_TEMPLATE") ?? "entry_confirmed";
const WA_LANG = Deno.env.get("WA_LANG") ?? "en";
const WA_API_VERSION = Deno.env.get("WA_API_VERSION") ?? "v23.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const svc = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

type Reg = {
  id: string;
  tournament_id: string;
  name: string;
  phone: string | null;
  needs_partner: boolean;
  partner_name: string | null;
  partner_phone: string | null;
};

/** Egyptian numbers as typed on the site → WhatsApp's digits-only E.164. */
export function toWaNumber(raw: string | null): string | null {
  let d = (raw ?? "").replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("01")) d = "2" + d;       // 01xxxxxxxxx
  else if (d.length === 10 && d.startsWith("1")) d = "20" + d;  // 1xxxxxxxxx
  return d.length >= 10 && d.length <= 15 ? d : null;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function when(date: string | null, time: string | null): string {
  if (!date) return "Date to be announced";
  const d = new Date(date + "T12:00:00Z");
  const s = `${DAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
  return time ? `${s}, ${time}` : s;
}

/** Template parameters may not be empty or contain newlines/tabs. */
const param = (s: string | null | undefined, fallback: string) => {
  const t = (s ?? "").replace(/[\n\t]+/g, " ").replace(/ {4,}/g, " ").trim();
  return { type: "text", text: t || fallback };
};

async function callerOwns(auth: string, tournamentId: string): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/owns_tournament`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ p_tid: tournamentId }),
    });
    return res.ok && (await res.json()) === true;
  } catch (e) {
    console.error("[whatsapp-confirm] owns check:", e);
    return false;
  }
}

async function sendTemplate(to: string, params: unknown[]): Promise<string | null> {
  const res = await fetch(
    `https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_ID}/messages`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${WA_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to,
        type: "template",
        template: {
          name: WA_TEMPLATE,
          language: { code: WA_LANG },
          components: [{ type: "body", parameters: params }],
        },
      }),
    },
  );
  if (res.ok) return null;
  const body = await res.json().catch(() => null);
  const err = body?.error;
  console.error("[whatsapp-confirm] send failed:", res.status, JSON.stringify(err));
  return (err?.error_data?.details as string) || (err?.message as string) || `HTTP ${res.status}`;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = req.headers.get("Authorization") ?? "";

  let ids: string[] = [];
  try {
    const body = await req.json();
    ids = (body?.registration_ids ?? []).filter((x: unknown) => typeof x === "string");
  } catch { /* fall through */ }
  if (ids.length < 1 || ids.length > 2) return json({ error: "bad_request" }, 400);

  // ── Load the registrations (service role) ─────────────────────
  const regRes = await fetch(
    `${SUPABASE_URL}/rest/v1/web_registrations?id=in.(${ids.join(",")})` +
      `&select=id,tournament_id,name,phone,needs_partner,partner_name,partner_phone`,
    { headers: svc },
  );
  const regs: Reg[] = regRes.ok ? await regRes.json() : [];
  if (regs.length !== ids.length) return json({ error: "not_found" }, 404);
  const tid = regs[0].tournament_id;
  if (regs.some((r) => r.tournament_id !== tid)) return json({ error: "bad_request" }, 400);

  // ── Who's asking ──────────────────────────────────────────────
  if (!(await callerOwns(auth, tid))) return json({ error: "forbidden" }, 403);

  if (!WA_TOKEN || !WA_PHONE_ID) return json({ status: "not_configured" });

  const tRes = await fetch(
    `${SUPABASE_URL}/rest/v1/tournaments?id=eq.${tid}&select=name,start_date,start_time,venue_name`,
    { headers: svc },
  );
  const t = tRes.ok ? (await tRes.json())[0] : null;

  // ── Who gets a message, and who their partner is ──────────────
  const out: { reg: string; to: string; name: string; partner: string }[] = [];
  const seen = new Set<string>();
  const push = (reg: string, phone: string | null, name: string, partner: string) => {
    const to = toWaNumber(phone);
    if (!to || seen.has(to)) return;
    seen.add(to);
    out.push({ reg, to, name, partner });
  };
  if (regs.length === 2) {
    // two paired solos: each one's partner is the other
    push(regs[0].id, regs[0].phone, regs[0].name, regs[1].name);
    push(regs[1].id, regs[1].phone, regs[1].name, regs[0].name);
  } else {
    const r = regs[0];
    push(r.id, r.phone, r.name, r.partner_name ?? "to be confirmed");
    if (!r.needs_partner && r.partner_name) push(r.id, r.partner_phone, r.partner_name, r.name);
  }

  // ── Send ──────────────────────────────────────────────────────
  const results: { to: string; ok: boolean; error?: string }[] = [];
  const perReg = new Map<string, string | null>(); // reg → first error (null = all ok)
  for (const m of out) {
    const first = m.name.trim().split(/\s+/)[0] || m.name;
    const err = await sendTemplate(m.to, [
      param(first, "there"),
      param(t?.name, "the tournament"),
      param(when(t?.start_date ?? null, t?.start_time ?? null), "Date to be announced"),
      param(t?.venue_name, "Venue to be announced"),
      param(m.partner, "to be confirmed"),
    ]);
    results.push(err ? { to: m.to, ok: false, error: err } : { to: m.to, ok: true });
    // keep the first error for a registration; a success never hides one
    if (err) {
      if (!perReg.get(m.reg)) perReg.set(m.reg, err);
    } else if (!perReg.has(m.reg)) {
      perReg.set(m.reg, null);
    }
  }

  // ── Record what happened on each registration ─────────────────
  for (const r of regs) {
    const err = perReg.has(r.id) ? perReg.get(r.id)! : "No valid WhatsApp number";
    await fetch(`${SUPABASE_URL}/rest/v1/web_registrations?id=eq.${r.id}`, {
      method: "PATCH",
      headers: { ...svc, Prefer: "return=minimal" },
      body: JSON.stringify(
        err
          ? { wa_status: "failed", wa_error: err.slice(0, 300) }
          : { wa_status: "sent", wa_error: null, wa_sent_at: new Date().toISOString() },
      ),
    }).catch((e) => console.error("[whatsapp-confirm] record:", e));
  }

  const okCount = results.filter((r) => r.ok).length;
  const status = results.length === 0 ? "failed"
    : okCount === results.length ? "sent"
    : okCount === 0 ? "failed" : "partial";
  return json({ status, sent: okCount, results });
});
