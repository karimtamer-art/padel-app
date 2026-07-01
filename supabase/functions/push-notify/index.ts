// push-notify — Supabase Edge Function.
//
// Triggered by a Database Webhook on INSERT into `public.notifications`.
// Looks up the recipient's FCM device tokens and sends each one a push via the
// FCM HTTP v1 API, authenticating with a Google service account.
//
// Required secrets (supabase secrets set ...):
//   FCM_SERVICE_ACCOUNT   the service-account JSON (entire file, as a string)
//   PUSH_WEBHOOK_SECRET   optional; if set, the webhook must send
//                         `Authorization: Bearer <PUSH_WEBHOOK_SECRET>`
// Auto-injected by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

interface NotificationRow {
  id: string;
  user_id: string;
  type?: string;
  title?: string;
  body?: string | null;
  data?: Record<string, unknown> | null;
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET");

function b64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

// Mint a short-lived OAuth2 access token for the FCM scope.
async function getAccessToken(sa: {
  client_email: string;
  private_key: string;
  token_uri: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );
  const jwt = `${unsigned}.${b64url(sig)}`;

  const res = await fetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const json = await res.json();
  if (!json.access_token) throw new Error(`token exchange failed: ${JSON.stringify(json)}`);
  return json.access_token as string;
}

async function tokensForUser(userId: string): Promise<string[]> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/device_tokens?user_id=eq.${userId}&select=token`,
    { headers: { apikey: SERVICE_ROLE, Authorization: `Bearer ${SERVICE_ROLE}` } },
  );
  const rows = (await res.json()) as { token: string }[];
  return rows.map((r) => r.token).filter(Boolean);
}

async function deleteToken(token: string): Promise<void> {
  await fetch(
    `${SUPABASE_URL}/rest/v1/device_tokens?token=eq.${encodeURIComponent(token)}`,
    { method: "DELETE", headers: { apikey: SERVICE_ROLE, Authorization: `Bearer ${SERVICE_ROLE}` } },
  );
}

Deno.serve(async (req) => {
  try {
    if (WEBHOOK_SECRET) {
      const auth = req.headers.get("Authorization");
      if (auth !== `Bearer ${WEBHOOK_SECRET}`) {
        return new Response("unauthorized", { status: 401 });
      }
    }

    const payload = await req.json();
    const record: NotificationRow | undefined = payload.record;
    if (!record?.user_id) return new Response("no record", { status: 200 });

    const tokens = await tokensForUser(record.user_id);
    if (tokens.length === 0) return new Response("no tokens", { status: 200 });

    const sa = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT")!);
    const accessToken = await getAccessToken(sa);
    const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

    // FCM data values must be strings.
    const data: Record<string, string> = { type: String(record.type ?? "") };
    if (record.data && typeof record.data === "object") {
      for (const [k, v] of Object.entries(record.data)) {
        data[k] = typeof v === "string" ? v : JSON.stringify(v);
      }
    }

    let sent = 0;
    for (const token of tokens) {
      const msg = {
        message: {
          token,
          notification: { title: record.title ?? "", body: record.body ?? "" },
          data,
          android: {
            priority: "HIGH", // delivery: wake the device immediately
            notification: {
              // Must match the channel created in MainActivity.kt and the
              // manifest meta-data. Drives heads-up + lock-screen display.
              channel_id: "padel_default",
              notification_priority: "PRIORITY_HIGH",
              visibility: "PUBLIC", // show content (not just "new notification") on lock screen
            },
          },
          // iOS/APNs: an explicit alert payload so the notification reliably
          // shows on the lock screen. apns-priority 10 + push-type alert are
          // required for an immediate visible alert.
          apns: {
            headers: {
              "apns-priority": "10",
              "apns-push-type": "alert",
            },
            payload: {
              aps: {
                alert: { title: record.title ?? "", body: record.body ?? "" },
                sound: "default",
              },
            },
          },
        },
      };
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(msg),
      });
      if (res.ok) {
        sent++;
      } else {
        const err = await res.json().catch(() => ({}));
        const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status;
        // Log the FCM rejection so APNs/token problems are visible in the logs.
        console.error(
          `FCM send failed (${res.status}) for token ${token.slice(0, 12)}…: ${JSON.stringify(err)}`,
        );
        // Stale token → remove so we stop trying it.
        if (res.status === 404 || code === "UNREGISTERED") await deleteToken(token);
      }
    }

    console.log(`push-notify: type=${record.type} sent=${sent}/${tokens.length}`);
    return new Response(JSON.stringify({ sent, of: tokens.length }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(`error: ${e}`, { status: 500 });
  }
});
