// KSJ Swimming — email Edge Function (Deno)
//
// One function, three actions selected by the JSON body `type`:
//   { type: "otp", email }             → email a 6-digit login code (My Bookings)
//   { type: "confirmation", booking_id } → email a booking confirmation
//   { type: "reminders" }              → (cron only) email 2-day reminders
//
// Emails are sent with Resend. Deploy WITHOUT JWT verification because
// booking + OTP requests are anonymous:
//   supabase functions deploy emails --no-verify-jwt
//
// Required secrets (supabase secrets set ...):
//   RESEND_API_KEY   Resend API key
//   FROM_EMAIL       verified sender, e.g. "KSJ Swimming <no-reply@yourdomain.com>"
//   SITE_URL         e.g. https://stevenmaswim.github.io/swim-booking
//   CRON_SECRET      shared secret the hourly cron job sends (reminders)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const REPLY_TO = "ksjswimming@gmail.com";
const FROM = Deno.env.get("FROM_EMAIL") ?? "KSJ Swimming <onboarding@resend.dev>";
const SITE_URL = (Deno.env.get("SITE_URL") ?? "").replace(/\/+$/, "");
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
// The pool's local timezone (IANA name). Every customer-facing time in these
// emails is formatted explicitly in this zone — never the Edge runtime's
// default (UTC / the server region) — so the clock time always matches the
// pool and the website. Override with a BUSINESS_TIMEZONE secret if the
// school relocates; keep it in sync with BUSINESS_TIMEZONE in config.js.
const BUSINESS_TIMEZONE = Deno.env.get("BUSINESS_TIMEZONE") ?? "America/Chicago";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function esc(s: string): string {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));
}

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sendEmail(to: string, subject: string, html: string) {
  if (!RESEND_API_KEY) throw new Error("RESEND_API_KEY not set");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from: FROM, to, reply_to: REPLY_TO, subject, html }),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
  return await res.json();
}

function fmtWhen(iso: string): string {
  // timeZoneName:"short" appends the zone abbreviation (e.g. "CDT"/"CST") so
  // any future zone mismatch is obvious in the email, and it tracks DST
  // automatically. Always pass timeZone explicitly — the runtime default is
  // NOT the pool's zone.
  return new Date(iso).toLocaleString("en-US", {
    weekday: "long", month: "long", day: "numeric",
    hour: "numeric", minute: "2-digit",
    timeZone: BUSINESS_TIMEZONE, timeZoneName: "short",
  });
}

function shell(inner: string): string {
  return `<div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
    max-width:520px;margin:0 auto;color:#0f172a;line-height:1.55;">
    <h2 style="color:#075985;margin:0 0 4px;">🏊 KSJ Swimming</h2>
    ${inner}
    <hr style="border:none;border-top:1px solid #e2e8f0;margin:22px 0;">
    <p style="color:#64748b;font-size:0.85rem;">KSJ Swimming · reply to this email or
    <a href="mailto:${REPLY_TO}">${REPLY_TO}</a> with any questions.</p>
  </div>`;
}

// ---------- OTP ----------
// Two rate limits protect against inbox-bombing a single address AND
// against draining the shared daily email quota across many addresses.
const OTP_PER_EMAIL_15MIN = 3;
const OTP_GLOBAL_PER_DAY = 40;
async function handleOtp(body: { email?: string }) {
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Invalid email" }, 400);

  // Per-email limit: at most N codes to one address per 15 minutes
  const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const { count: perEmail } = await sb.from("booking_otps")
    .select("id", { count: "exact", head: true })
    .eq("email", email).gte("created_at", since);
  if ((perEmail ?? 0) >= OTP_PER_EMAIL_15MIN) {
    return json({ error: "Too many code requests for this email. Please wait a few minutes." }, 429);
  }

  // Global daily ceiling: stop anyone draining the Resend quota by
  // requesting codes for many different addresses.
  const since24h = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count: global } = await sb.from("booking_otps")
    .select("id", { count: "exact", head: true })
    .gte("created_at", since24h);
  if ((global ?? 0) >= OTP_GLOBAL_PER_DAY) {
    return json({ error: "The code service is temporarily busy. Please try again later or contact us." }, 429);
  }

  const code = String(Math.floor(100000 + Math.random() * 900000));
  const code_hash = await sha256hex(code);
  const expires_at = new Date(Date.now() + 10 * 60 * 1000).toISOString();
  const { error } = await sb.from("booking_otps").insert({ email, code_hash, expires_at });
  if (error) return json({ error: error.message }, 500);

  await sendEmail(email, "Your KSJ Swimming access code", shell(`
    <p>Here is your one-time code to view your bookings:</p>
    <p style="font-size:2rem;font-weight:800;letter-spacing:6px;color:#075985;">${code}</p>
    <p class="muted" style="color:#64748b;">It expires in 10 minutes. If you didn't request this, you can ignore this email.</p>
  `));
  return json({ ok: true });
}

// ---------- Confirmation (one booking or a whole multi-slot set) ----------
async function handleConfirmation(body: { booking_id?: string; booking_ids?: string[] }) {
  const ids = (Array.isArray(body.booking_ids) && body.booking_ids.length
    ? body.booking_ids
    : body.booking_id ? [body.booking_id] : []).map(String).slice(0, 8);
  if (!ids.length) return json({ error: "booking_id(s) required" }, 400);

  const { data, error } = await sb.from("bookings")
    .select("email, first_name, student_name, parent_name, cancel_token, slots(starts_at, duration_min, pools(name, address), profiles!coach_id(display_name))")
    .in("id", ids);
  if (error || !data?.length) return json({ error: error?.message ?? "not found" }, 404);

  // One email per call: all listed lessons must belong to the same address
  // (book_slots guarantees this; drop anything else defensively).
  const email = (data[0] as any).email;
  const rows = (data as any[])
    .filter((b) => b.email === email)
    .sort((a, b) => String(a.slots.starts_at).localeCompare(String(b.slots.starts_at)));
  const first = rows[0];
  const myUrl = `${SITE_URL}/mybookings.html`;
  const n = rows.length;

  const lessonRow = (b: any) => {
    const slot = b.slots;
    const cancelUrl = `${SITE_URL}/book.html?cancel=${b.cancel_token}`;
    return `
    <table style="font-size:0.95rem;margin-bottom:6px;">
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Student</td><td><strong>${esc(b.student_name || b.first_name || "")}</strong></td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">When</td><td><strong>${esc(fmtWhen(slot.starts_at))}</strong> (${slot.duration_min} min)</td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Pool</td><td>${esc(slot.pools?.name || "")}${slot.pools?.address ? " — " + esc(slot.pools.address) : ""}</td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Coach</td><td>${esc(slot.profiles?.display_name || "TBD")}</td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;"></td><td style="font-size:0.85rem;"><a href="${cancelUrl}" style="color:#64748b;">Cancel this lesson</a></td></tr>
    </table>
    ${n > 1 ? '<hr style="border:none;border-top:1px dashed #e2e8f0;margin:10px 0;">' : ""}`;
  };

  // Greet the parent (the email always goes to the booker); fall back to
  // the student name for pre-v8 single bookings without a parent on file.
  await sendEmail(email,
    n === 1 ? "Your KSJ Swimming lesson is booked ✅"
            : `Your ${n} KSJ Swimming lessons are booked ✅`,
    shell(`
    <p>Hi ${esc(first.parent_name || first.first_name || "there")}, your ${n === 1 ? "lesson is" : `${n} lessons are`} confirmed:</p>
    ${rows.map(lessonRow).join("")}
    <p style="margin-top:18px;">
      <a href="${myUrl}" style="background:#0369a1;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;">View my bookings</a>
    </p>
  `));
  return json({ ok: true });
}

// ---------- Slot changed (staff edited a booked lesson) ----------
async function handleSlotUpdate(body: { booking_id?: string; old_start?: string; old_location?: string }) {
  const id = String(body.booking_id ?? "");
  if (!id) return json({ error: "booking_id required" }, 400);
  const { data: b, error } = await sb.from("bookings")
    .select("email, first_name, cancel_token, slots(starts_at, duration_min, pools(name, address), profiles!coach_id(display_name))")
    .eq("id", id).single();
  if (error || !b) return json({ error: error?.message ?? "not found" }, 404);

  const slot: any = b.slots;
  const newLoc = slot.pools?.address || slot.pools?.name || "";
  const cancelUrl = `${SITE_URL}/book.html?cancel=${b.cancel_token}`;
  const myUrl = `${SITE_URL}/mybookings.html`;
  await sendEmail(b.email, "Your KSJ Swimming lesson has been updated", shell(`
    <p>Hi ${esc(b.first_name || "there")}, the details of your lesson have changed:</p>
    <table style="font-size:0.95rem;">
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Was</td><td style="text-decoration:line-through;color:#94a3b8;">${esc(body.old_start ? fmtWhen(body.old_start) : "")}${body.old_location ? " — " + esc(body.old_location) : ""}</td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Now</td><td><strong>${esc(fmtWhen(slot.starts_at))}</strong> (${slot.duration_min} min)${newLoc ? " — " + esc(newLoc) : ""}</td></tr>
      <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Coach</td><td>${esc(slot.profiles?.display_name || "TBD")}</td></tr>
    </table>
    <p style="margin-top:18px;"><a href="${myUrl}" style="background:#0369a1;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;">View my bookings</a></p>
    <p style="margin-top:14px;color:#64748b;font-size:0.9rem;">If this doesn't work for you, <a href="${cancelUrl}">cancel here</a> and pick another time.</p>
  `));
  return json({ ok: true });
}

// ---------- Reminders (cron only) ----------
async function handleReminders(req: Request) {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  const from = new Date(Date.now() + 47 * 3600 * 1000).toISOString();
  const to = new Date(Date.now() + 49 * 3600 * 1000).toISOString();
  const { data, error } = await sb.from("bookings")
    .select("id, email, first_name, cancel_token, slots!inner(starts_at, duration_min, pools(name, address), profiles!coach_id(display_name))")
    .eq("status", "confirmed").is("reminded_at", null)
    .gte("slots.starts_at", from).lt("slots.starts_at", to);
  if (error) return json({ error: error.message }, 500);

  let sent = 0;
  for (const b of data ?? []) {
    const slot: any = (b as any).slots;
    const cancelUrl = `${SITE_URL}/book.html?cancel=${(b as any).cancel_token}`;
    try {
      await sendEmail((b as any).email, "Reminder: your KSJ Swimming lesson is in 2 days", shell(`
        <p>Hi ${esc((b as any).first_name || "there")}, this is a friendly reminder of your upcoming lesson:</p>
        <table style="font-size:0.95rem;">
          <tr><td style="padding:2px 10px 2px 0;color:#64748b;">When</td><td><strong>${esc(fmtWhen(slot.starts_at))}</strong> (${slot.duration_min} min)</td></tr>
          <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Pool</td><td>${esc(slot.pools?.name || "")}${slot.pools?.address ? " — " + esc(slot.pools.address) : ""}</td></tr>
          <tr><td style="padding:2px 10px 2px 0;color:#64748b;">Coach</td><td>${esc(slot.profiles?.display_name || "TBD")}</td></tr>
        </table>
        <p style="margin-top:14px;color:#64748b;font-size:0.9rem;">Can't make it? <a href="${cancelUrl}">Cancel</a> so someone else can take the spot.</p>
      `));
      await sb.from("bookings").update({ reminded_at: new Date().toISOString() }).eq("id", (b as any).id);
      sent++;
    } catch (e) {
      console.error("reminder failed for", (b as any).id, e);
    }
  }
  return json({ ok: true, sent });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json();
    switch (body.type) {
      case "otp": return await handleOtp(body);
      case "confirmation": return await handleConfirmation(body);
      case "slot_update": return await handleSlotUpdate(body);
      case "reminders": return await handleReminders(req);
      default: return json({ error: "unknown type" }, 400);
    }
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
