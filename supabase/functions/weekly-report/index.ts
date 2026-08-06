// Supabase Edge Function — the page a weekly-report link opens.
//
//   GET /functions/v1/weekly-report?t=<token>
//
// Renders ONE week's full profit & loss as a self-contained read-only HTML
// page: no login, no JavaScript, no external assets, nothing to edit. It is a
// statement of a week that has already happened.
//
// Everything on the page comes from `report_render(token)`, which is the same
// `_finance_core` the admin console reads — the numbers cannot disagree with
// the app. This function computes nothing but percentages of a bar's width.
//
// The token is validated in Postgres, not here. This function holds the
// service-role key (auto-injected by Supabase) because `report_render` is
// granted to service_role alone — a leaked token is useless against PostgREST.
//
// Deploy WITHOUT jwt verification, or links won't open from a mail client:
//   supabase functions deploy weekly-report --no-verify-jwt

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ── Money + dates, formatted the way the console formats them ───────────────

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const egp = (n: number) =>
  "EGP " + Math.round(Math.abs(n)).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");

/** "Aug 3 – 9" / "Jul 28 – Aug 3" — same rule as FinanceWeek.label. */
function weekLabel(startIso: string, endIso: string): string {
  const a = new Date(startIso + "T00:00:00Z");
  const b = new Date(endIso + "T00:00:00Z");
  const am = MONTHS[a.getUTCMonth()], bm = MONTHS[b.getUTCMonth()];
  return am === bm
    ? `${am} ${a.getUTCDate()} – ${b.getUTCDate()}`
    : `${am} ${a.getUTCDate()} – ${bm} ${b.getUTCDate()}`;
}

function longDate(iso: string): string {
  const d = new Date(iso + "T00:00:00Z");
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}

// Category labels mirror kExpenseCategories / kIncomeCategories in
// lib/admin/data/finance_model.dart — change both.
const EXPENSE_LABELS: Record<string, string> = {
  materials: "Materials & supplies",
  court_rent: "Courts & venue",
  prizes: "Prizes & trophies",
  marketing: "Marketing & ads",
  salaries: "Staff & coaches",
  shipping: "Delivery & courier",
  software: "Software & fees",
  equipment: "Equipment & upkeep",
  other: "Other",
};

const INCOME_LABELS: Record<string, string> = {
  cash_sale: "Cash sale",
  coaching: "Coaching",
  court_hire: "Court hire",
  sponsorship: "Sponsorship",
  event: "Event takings",
  other: "Other",
};

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

type Line = { label: string; amount: number; hint: string };

/** What we get — mirrors FinanceReport.inLines. Zero lines dropped, biggest first. */
function inLines(r: any): Line[] {
  const c = r.counts ?? {};
  const lines: Line[] = [
    { label: "Store sales", amount: +r.in?.store || 0, hint: `${c.orders ?? 0} orders` },
    { label: "Tournament entries", amount: +r.in?.entries || 0, hint: `${c.entries ?? 0} paid entries` },
    { label: "Repairs", amount: +r.in?.repairs || 0, hint: `${c.repairs ?? 0} collected` },
    ...((r.in?.by_category ?? []) as any[]).map((e) => ({
      label: INCOME_LABELS[e.category] ?? "Other",
      amount: +e.amount || 0,
      hint: `${e.n ?? 0} recorded outside the app`,
    })),
  ];
  return lines.filter((l) => l.amount !== 0).sort((a, b) => b.amount - a.amount);
}

/** What we pay — mirrors FinanceReport.outLines. */
function outLines(r: any): Line[] {
  const c = r.counts ?? {};
  const lines: Line[] = [
    { label: "Cost of goods sold", amount: +r.out?.cogs || 0, hint: "What the items sold cost us · automatic" },
    { label: "Trade-in credit", amount: +r.out?.trade_in || 0, hint: `${c.trade_in ?? 0} offers accepted · automatic` },
    ...((r.out?.by_category ?? []) as any[]).map((e) => ({
      label: EXPENSE_LABELS[e.category] ?? "Other",
      amount: +e.amount || 0,
      hint: `${e.n ?? 0} recorded`,
    })),
  ];
  return lines.filter((l) => l.amount !== 0).sort((a, b) => b.amount - a.amount);
}

function rows(lines: Line[], total: number, tone: string): string {
  if (!lines.length) return `<p class="none">Nothing this week.</p>`;
  return lines
    .map((l) => {
      const pct = total > 0 ? Math.round((l.amount / total) * 100) : 0;
      return `<div class="row">
        <div class="row-top">
          <span class="row-label">${esc(l.label)}</span>
          <span class="row-amt">${esc(egp(l.amount))}</span>
        </div>
        <div class="bar"><i style="width:${pct}%;background:${tone}"></i></div>
        <div class="row-hint">${esc(l.hint)} · ${pct}%</div>
      </div>`;
    })
    .join("");
}

function page(d: any): string {
  const r = d.report ?? {};
  const profit = +r.profit || 0;
  const moneyIn = +r.in?.total || 0;
  const moneyOut = +r.out?.total || 0;
  const margin = +r.margin || 0;
  const c = r.counts ?? {};
  const up = profit >= 0;
  const label = weekLabel(d.week_start, d.week_end);
  const empty = moneyIn === 0 && moneyOut === 0;

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="light dark">
<title>Padel Rivals — week of ${esc(label)}</title>
<style>
  :root{
    --bg:#E9DFCD; --surface:#FBF6EC; --surface-alt:#F3EADB;
    --ink:#2A2218; --ink-soft:#6E6149; --ink-faint:#A2937A;
    --line:#DBCEB6; --line-soft:#E7DCC8;
    --primary:#C2502A; --green:#3F8B57; --danger:#C0432F;
    --hero:#21372F; --hero2:#2B463B; --hero-ink:#F4EFE2;
  }
  @media (prefers-color-scheme: dark){
    :root{
      --bg:#1A1610; --surface:#231E16; --surface-alt:#2B241A;
      --ink:#F1E9DA; --ink-soft:#BCAD93; --ink-faint:#8A7C64;
      --line:#3A3125; --line-soft:#2F2819;
    }
  }
  *{box-sizing:border-box}
  body{margin:0;padding:26px 16px 60px;background:var(--bg);color:var(--ink);
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-text-size-adjust:100%}
  .wrap{max-width:640px;margin:0 auto}
  .kicker{font-size:11px;font-weight:700;letter-spacing:1.4px;text-transform:uppercase;
    color:var(--ink-faint);margin:0 0 6px}
  h1{font-size:25px;font-weight:800;letter-spacing:-.6px;margin:0 0 4px}
  .sub{font-size:13px;color:var(--ink-soft);margin:0 0 20px}
  .hero{background:linear-gradient(135deg,var(--hero),var(--hero2));color:var(--hero-ink);
    border-radius:18px;padding:22px;margin-bottom:16px}
  .hero .kicker{color:rgba(244,239,226,.6)}
  .big{font-size:38px;font-weight:800;letter-spacing:-1.4px;line-height:1;margin:0 0 8px}
  .hero .foot{font-size:13px;color:rgba(244,239,226,.72);margin:0}
  .split{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px}
  .tile{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:14px}
  .tile .kicker{margin-bottom:5px}
  .tile .v{font-size:20px;font-weight:800;letter-spacing:-.5px}
  .card{background:var(--surface);border:1px solid var(--line);border-radius:18px;
    padding:18px;margin-bottom:16px}
  .card h2{font-size:15px;font-weight:800;margin:0;letter-spacing:-.2px}
  .card-head{display:flex;align-items:baseline;justify-content:space-between;
    gap:12px;margin-bottom:4px}
  .card-total{font-size:15px;font-weight:800;font-variant-numeric:tabular-nums}
  .row{padding:13px 0;border-bottom:1px solid var(--line-soft)}
  .row:last-child{border-bottom:0;padding-bottom:0}
  .row-top{display:flex;justify-content:space-between;gap:12px;align-items:baseline}
  .row-label{font-size:13.5px;font-weight:600}
  .row-amt{font-size:13.5px;font-weight:800;font-variant-numeric:tabular-nums;white-space:nowrap}
  .row-hint{font-size:11.5px;color:var(--ink-faint);margin-top:5px}
  .bar{height:6px;border-radius:999px;background:var(--surface-alt);margin-top:8px;overflow:hidden}
  .bar i{display:block;height:100%;border-radius:999px}
  .none{font-size:13px;color:var(--ink-soft);margin:10px 0 0}
  .counts{font-size:12.5px;color:var(--ink-soft);line-height:1.7;margin:0}
  .note{font-size:11.5px;color:var(--ink-faint);line-height:1.6;margin:22px 0 0;text-align:center}
  .pill{display:inline-block;padding:3px 10px;border-radius:999px;font-size:11px;
    font-weight:800;letter-spacing:.4px;text-transform:uppercase;
    background:rgba(194,80,42,.14);color:var(--primary);margin-left:8px;vertical-align:middle}
</style>
</head><body><div class="wrap">

  <p class="kicker">Padel Rivals · weekly report</p>
  <h1>Week of ${esc(label)}${d.is_current ? '<span class="pill">So far</span>' : ""}</h1>
  <p class="sub">${esc(longDate(d.week_start))} — ${esc(longDate(d.week_end))} · Monday to Sunday, Cairo time</p>

  <div class="hero">
    <p class="kicker">${up ? "Net profit" : "Net loss"}</p>
    <p class="big">${esc(egp(profit))}</p>
    <p class="foot">${
      empty
        ? "Nothing moved this week."
        : `${margin.toFixed(1)}% margin on ${esc(egp(moneyIn))} in`
    }</p>
  </div>

  <div class="split">
    <div class="tile"><p class="kicker">Money in</p>
      <div class="v" style="color:var(--green)">${esc(egp(moneyIn))}</div></div>
    <div class="tile"><p class="kicker">Money out</p>
      <div class="v" style="color:var(--danger)">${esc(egp(moneyOut))}</div></div>
  </div>

  <div class="card">
    <div class="card-head"><h2>What we get</h2>
      <span class="card-total" style="color:var(--green)">${esc(egp(moneyIn))}</span></div>
    ${rows(inLines(r), moneyIn, "var(--green)")}
  </div>

  <div class="card">
    <div class="card-head"><h2>What we pay</h2>
      <span class="card-total" style="color:var(--danger)">${esc(egp(moneyOut))}</span></div>
    ${rows(outLines(r), moneyOut, "var(--danger)")}
  </div>

  <div class="card">
    <div class="card-head"><h2>The week in counts</h2></div>
    <p class="counts">
      ${c.orders ?? 0} store orders · ${c.entries ?? 0} paid tournament entries ·
      ${c.repairs ?? 0} repairs collected<br>
      ${c.manual ?? 0} money-in entries by hand · ${c.expenses ?? 0} expenses recorded ·
      ${c.trade_in ?? 0} trade-ins accepted
    </p>
  </div>

  <p class="note">
    Read-only. Store sales, entry fees and repairs are counted automatically;
    cost of goods sold and trade-in credit come off the ledgers the same way.<br>
    Anyone with this link can read this week — treat it like the numbers themselves.
  </p>

</div></body></html>`;
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // A financial statement should not sit in a shared cache.
      "Cache-Control": "no-store, private",
      "X-Robots-Tag": "noindex, nofollow",
      "Referrer-Policy": "no-referrer",
    },
  });
}

const problem = (title: string, msg: string, status: number) =>
  html(
    `<!doctype html><html lang="en"><head><meta charset="utf-8">
     <meta name="viewport" content="width=device-width,initial-scale=1">
     <title>${esc(title)}</title>
     <style>body{margin:0;min-height:100vh;display:flex;align-items:center;
       justify-content:center;background:#E9DFCD;color:#2A2218;text-align:center;
       padding:30px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
       h1{font-size:19px;margin:0 0 8px}p{font-size:14px;color:#6E6149;margin:0;max-width:340px}
     </style></head><body><div><h1>${esc(title)}</h1><p>${esc(msg)}</p></div></body></html>`,
    status,
  );

serve(async (req) => {
  const token = new URL(req.url).searchParams.get("t");
  if (!token) {
    return problem("No report requested", "That link is missing its report code.", 400);
  }

  let data: any;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/report_render`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_token: token }),
    });
    if (!res.ok) throw new Error(`report_render ${res.status}: ${await res.text()}`);
    data = await res.json();
  } catch (e) {
    console.error("[weekly-report]", e);
    return problem("Report unavailable", "Something went wrong fetching it. Try again shortly.", 502);
  }

  if (!data || data.error) {
    // Same answer for an unknown token and a revoked one — no probing.
    return problem("Link not valid", "This report link has been revoked, or never existed.", 404);
  }
  if (data.report?.error) {
    console.error("[weekly-report] core refused:", data.report.error);
    return problem("Report unavailable", "The numbers could not be read.", 502);
  }

  return html(page(data));
});
