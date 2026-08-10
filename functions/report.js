// Cloudflare Pages Function — serves the weekly P&L at padel-rivals.com/report
//
// WHY THIS EXISTS. The report itself is rendered by the Supabase Edge Function
// `weekly-report` (supabase/functions/weekly-report/index.ts), which correctly
// sets `Content-Type: text/html`. Supabase's gateway then REWRITES that header
// to `text/plain` and injects `X-Content-Type-Options: nosniff` plus a
// `default-src 'none'; sandbox` CSP, because letting Edge Functions serve
// renderable HTML would turn every *.supabase.co project into a phishing host.
// The result is that a browser paints the page source instead of the page — no
// header we set upstream can undo it, since the rewrite happens after the
// response leaves the runtime.
//
// So this proxies: same body, same status, correct Content-Type, on a domain we
// control. Nothing is recomputed here and no secret lives here — the token is
// still checked by `report_render` in Postgres, which is granted to
// service_role only, so this endpoint is exactly as guarded as the one behind
// it. Point the mailer at it with:
//
//   supabase secrets set REPORT_BASE_URL=https://padel-rivals.com/report
//
// Pages picks this up from the `functions/` directory at the REPO ROOT — not
// from `docs/`, which is only the static output directory. The file name is the
// route: functions/report.js -> /report.

const DEFAULT_UPSTREAM =
  'https://lxihwifpcufhieppfeza.supabase.co/functions/v1/weekly-report';

export async function onRequestGet(context) {
  const { request, env } = context;
  const token = new URL(request.url).searchParams.get('t') ?? '';
  const upstream = env.REPORT_UPSTREAM || DEFAULT_UPSTREAM;

  let res;
  try {
    res = await fetch(`${upstream}?t=${encodeURIComponent(token)}`, {
      // Never let Cloudflare cache a financial statement.
      cf: { cacheTtl: 0, cacheEverything: false },
    });
  } catch (e) {
    return page(
      'Report unavailable',
      'The report could not be reached. Try again shortly.',
      502,
    );
  }

  // Pass the upstream body through untouched — it is already a complete HTML
  // document, including its own error pages ("Link not valid" for a revoked
  // token), and those should reach the reader as-is rather than be replaced.
  return new Response(await res.text(), {
    status: res.status,
    headers: baseHeaders(),
  });
}

function baseHeaders() {
  return {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store, private',
    'X-Robots-Tag': 'noindex, nofollow',
    // Keeps the ?t= token out of the Referer of anything the page links to.
    'Referrer-Policy': 'no-referrer',
  };
}

/** Only used when the upstream is unreachable; upstream renders its own errors. */
function page(title, msg, status) {
  const esc = (s) =>
    String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[c]);
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;
justify-content:center;background:#E9DFCD;color:#2A2218;text-align:center;
padding:30px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
h1{font-size:19px;margin:0 0 8px}p{font-size:14px;color:#6E6149;margin:0;max-width:340px}
</style></head><body><div><h1>${esc(title)}</h1><p>${esc(msg)}</p></div></body></html>`,
    { status, headers: baseHeaders() },
  );
}
