// create-staff — Supabase Edge Function.
//
// A super admin provisions a staff account of ANY role (super_admin, organizer,
// support, analyst): a username + a temporary password. We synthesize a login
// email (<username>@padelegypt.app — the same scheme the app's username login
// already uses), create the auth user with the service role, and stamp the
// profile with the chosen role, flagged must_change_password so they reset the
// password on first login.
//
// Called from the admin console via supabase.functions.invoke('create-staff').
// The caller's JWT is forwarded automatically; we verify it belongs to a
// super admin before doing anything.
//
// Auto-injected by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

// Must match AuthService.usernameDomain in the Flutter app.
const USERNAME_DOMAIN = "padelegypt.app";
const ROLES = ["super_admin", "organizer", "support", "analyst"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// service-role client — the privileged writer (auth.admin + profiles).
const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { autoRefreshToken: false, persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    // 1. Verify the caller is a signed-in super admin.
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Not signed in." }, 401);

    const caller = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData?.user) return json({ error: "Not signed in." }, 401);

    const { data: me } = await admin
      .from("profiles")
      .select("is_admin, admin_role")
      .eq("id", userData.user.id)
      .maybeSingle();
    const isSuperAdmin =
      me?.is_admin === true || me?.admin_role === "super_admin";
    if (!isSuperAdmin) {
      return json({ error: "Only a super admin can create staff." }, 403);
    }

    // 2. Validate input.
    const body = await req.json().catch(() => ({}));
    const name = String(body.name ?? "").trim();
    const username = String(body.username ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    const role = String(body.role ?? "").trim();
    const scope = body.scope ? String(body.scope).trim() : null;
    // Optional custom section list; null → the role's default access.
    const access = Array.isArray(body.access) ? body.access.map(String) : null;

    if (!name) return json({ error: "Name is required." }, 400);
    if (!ROLES.includes(role)) return json({ error: "Invalid role." }, 400);
    if (!/^[a-z0-9_]{3,20}$/.test(username)) {
      return json({
        error:
          "Username must be 3–20 characters: lowercase letters, numbers or underscore.",
      }, 400);
    }
    if (password.length < 6) {
      return json({ error: "Temp password must be at least 6 characters." }, 400);
    }

    const email = `${username}@${USERNAME_DOMAIN}`;

    // 3. Reject a taken username.
    const { data: clash } = await admin
      .from("profiles")
      .select("id")
      .eq("username", username)
      .maybeSingle();
    if (clash) return json({ error: "That username is already taken." }, 409);

    // 4. Create the auth user (email pre-confirmed so they can log in at once).
    const { data: created, error: createErr } = await admin.auth.admin
      .createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { name, username },
      });
    if (createErr || !created?.user) {
      const msg = createErr?.message ?? "Could not create the account.";
      if (/already|exists|registered/i.test(msg)) {
        return json({ error: "That username is already taken." }, 409);
      }
      return json({ error: msg }, 400);
    }

    const newId = created.user.id;

    // 5. Stamp the profile with the chosen role. Only super_admin keeps
    //    is_admin=true (full DB access); other roles are is_admin=false.
    const { error: upErr } = await admin.from("profiles").upsert({
      id: newId,
      name,
      username,
      is_admin: role === "super_admin",
      admin_role: role,
      admin_access: access, // null → role default
      admin_scope: scope,
      must_change_password: true,
    }, { onConflict: "id" });
    if (upErr) {
      await admin.auth.admin.deleteUser(newId).catch(() => {});
      return json({ error: `Profile setup failed: ${upErr.message}` }, 400);
    }

    return json({ ok: true, user_id: newId, email, username, role });
  } catch (e) {
    return json({ error: `Unexpected error: ${e}` }, 500);
  }
});
