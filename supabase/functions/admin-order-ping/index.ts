// SKETCH · Supabase Edge Function — phone ping to admin on new order.
//
// Use this variant instead of the pg_net SQL if you want WhatsApp, or richer
// logic/retries. Wire it up as a Database Webhook:
//   Dashboard -> Database -> Webhooks -> "orders" table, event INSERT,
//   type "Supabase Edge Function" -> select this function.
//
// Set secrets once (never commit them):
//   supabase secrets set TG_BOT_TOKEN=... TG_CHAT_ID=...
//   # WhatsApp (Meta Cloud API): WA_TOKEN, WA_PHONE_ID, WA_TO
//
// Deploy:
//   supabase functions deploy admin-order-ping --no-verify-jwt
//
// The webhook POSTs { type, table, record, old_record } — `record` is the new
// order row.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const ref = (id: string) =>
  "PD-" + String(id).replace(/-/g, "").slice(0, 6).toUpperCase();

serve(async (req) => {
  const { record } = await req.json();
  const text =
    `New order ${ref(record.id)}\n` +
    `Method: ${record.payment_method ?? "cod"}\n` +
    `Total: EGP ${record.total ?? 0}\n` +
    `Status: ${record.status ?? "pending"} — needs confirmation`;

  // ---- Option A: Telegram ----
  const tgToken = Deno.env.get("TG_BOT_TOKEN");
  const tgChat = Deno.env.get("TG_CHAT_ID");
  if (tgToken && tgChat) {
    await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: tgChat, text }),
    });
  }

  // ---- Option B: WhatsApp (Meta Cloud API) ----
  // Needs a WhatsApp Business number + a PRE-APPROVED message template
  // ("new_order") because the recipient hasn't messaged you in the last 24h.
  // const waToken = Deno.env.get("WA_TOKEN");
  // const waPhoneId = Deno.env.get("WA_PHONE_ID");
  // const waTo = Deno.env.get("WA_TO");
  // if (waToken && waPhoneId && waTo) {
  //   await fetch(`https://graph.facebook.com/v20.0/${waPhoneId}/messages`, {
  //     method: "POST",
  //     headers: {
  //       Authorization: `Bearer ${waToken}`,
  //       "Content-Type": "application/json",
  //     },
  //     body: JSON.stringify({
  //       messaging_product: "whatsapp",
  //       to: waTo,
  //       type: "template",
  //       template: {
  //         name: "new_order",
  //         language: { code: "en" },
  //         components: [
  //           { type: "body", parameters: [{ type: "text", text: ref(record.id) }] },
  //         ],
  //       },
  //     }),
  //   });
  // }

  return new Response("ok", { status: 200 });
});
