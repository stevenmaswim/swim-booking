#!/usr/bin/env node
// verify_v6_api.mjs — hits the REAL Supabase REST API with real JWTs to
// prove the v6 permission gates hold outside the UI. Non-destructive:
// every probe either reads, or is refused before it can write (admin
// probes use a nonexistent uuid so the gate is exercised but nothing
// changes). The full write-path matrix runs in verify_v6.sql (rolled back).
//
// Get each JWT from a logged-in staff.html session (DevTools > Console):
//   (await db.auth.getSession()).data.session.access_token
//
// Usage:
//   ADMIN_JWT=eyJ... COACH_JWT=eyJ... node supabase/verify_v6_api.mjs
// COACH_JWT is optional until a real coach account exists — admin + anon
// checks still run without it.

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const cfg = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'config.js'), 'utf8');
const URL_ = process.env.SUPABASE_URL ?? cfg.match(/SUPABASE_URL\s*=\s*"([^"]+)"/)[1];
const ANON = process.env.SUPABASE_ANON_KEY ?? cfg.match(/SUPABASE_ANON_KEY\s*=\s*"([^"]+)"/)[1];
const ADMIN_JWT = process.env.ADMIN_JWT;
const COACH_JWT = process.env.COACH_JWT;
if (!ADMIN_JWT) { console.error('Set ADMIN_JWT (and ideally COACH_JWT). See the header comment.'); process.exit(2); }

const NIL = '00000000-0000-0000-0000-000000000000';
let pass = 0, fail = 0, skip = 0;
const ok = (label, cond, detail) => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${cond ? '' : '  → ' + detail}`);
  cond ? pass++ : fail++;
};

async function rpc(name, body, jwt) {
  const res = await fetch(`${URL_}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', apikey: ANON,
      Authorization: `Bearer ${jwt ?? ANON}`,
    },
    body: JSON.stringify(body ?? {}),
  });
  let j = null; try { j = await res.json(); } catch {}
  return { status: res.status, body: j, msg: j?.message ?? j?.error ?? '' };
}

console.log(`Target: ${URL_}\n`);

// ---------- anon: admin RPCs not even executable ----------
for (const [name, body] of [
  ['get_revenue_grid', { p_from: new Date().toISOString(), p_to: new Date(Date.now() + 864e5).toISOString() }],
  ['reopen_slot', { p_slot_id: NIL }],
  ['admin_update_profile', { p_id: NIL, p_display_name: 'x', p_bio: '', p_is_public: true, p_role: 'coach' }],
]) {
  const r = await rpc(name, body, null);
  ok(`anon cannot execute ${name}`, r.status === 401 || r.status === 403 || r.status === 404,
    `status ${r.status}: ${r.msg}`);
}
// anon booking without verification must refuse
{
  const r = await rpc('book_slots', {
    p_slot_ids: [NIL], p_first_name: 'A', p_last_name: 'B',
    p_parent_name: 'CD', p_email: 'probe@example.com', p_phone: '2045550000',
  }, null);
  ok('anon book_slots without code/token refused', r.status === 400 && /verify your email/i.test(r.msg),
    `status ${r.status}: ${r.msg}`);
}

// ---------- coach JWT: admin gates must refuse ----------
if (COACH_JWT) {
  for (const [name, body] of [
    ['get_revenue_grid', { p_from: new Date().toISOString(), p_to: new Date(Date.now() + 864e5).toISOString() }],
    ['reopen_slot', { p_slot_id: NIL }],
    ['admin_update_profile', { p_id: NIL, p_display_name: 'x', p_bio: '', p_is_public: true, p_role: 'coach' }],
  ]) {
    const r = await rpc(name, body, COACH_JWT);
    ok(`coach refused by ${name}`, r.status === 400 && /Only admins/i.test(r.msg),
      `status ${r.status}: ${r.msg}`);
  }
  // direct role write must be blocked by column grants
  {
    const res = await fetch(`${URL_}/rest/v1/profiles?id=eq.${NIL}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', apikey: ANON, Authorization: `Bearer ${COACH_JWT}` },
      body: JSON.stringify({ role: 'admin' }),
    });
    ok('coach cannot PATCH profiles.role directly', res.status === 401 || res.status === 403 || res.status === 404,
      `status ${res.status}`);
  }
} else {
  console.log('SKIP  coach checks — set COACH_JWT once a coach account exists');
  skip++;
}

// ---------- admin JWT: passes the gates (probed without writing) ----------
{
  const r = await rpc('get_revenue_grid', {
    p_from: new Date(Date.now() - 30 * 864e5).toISOString(),
    p_to: new Date().toISOString(),
  }, ADMIN_JWT);
  ok('admin reads the revenue grid', r.status === 200 && Array.isArray(r.body?.cells),
    `status ${r.status}: ${r.msg}`);
}
{
  // Nonexistent slot: 'Slot not found.' proves the is_admin gate PASSED
  // (a non-admin fails earlier with 'Only admins') — and nothing changed.
  const r = await rpc('reopen_slot', { p_slot_id: NIL }, ADMIN_JWT);
  ok('admin passes the reopen gate (no-op probe)', r.status === 400 && /Slot not found/i.test(r.msg),
    `status ${r.status}: ${r.msg}`);
}
{
  const r = await rpc('admin_update_profile',
    { p_id: NIL, p_display_name: 'x', p_bio: '', p_is_public: true, p_role: 'coach' }, ADMIN_JWT);
  ok('admin passes the profile-management gate (no-op probe)', r.status === 400 && /Profile not found/i.test(r.msg),
    `status ${r.status}: ${r.msg}`);
}

console.log(`\n${fail === 0 ? 'ALL GREEN' : 'FAILURES'} — ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ''}`);
process.exit(fail ? 1 : 0);
