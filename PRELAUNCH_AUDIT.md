# KSJ Swimming — Pre-Launch Audit (2026-07-10)

Scope: full re-audit before shipping to real families, with emphasis on everything
added since the first audit (`SECURITY_AUDIT.md`, `migration_security.sql`): OTP email
verification, multi-slot atomic booking (`book_slots`), 24h verify-tokens in
localStorage, client deletion/anonymization, admin Team management (`admin_update_profile`),
revenue grid (`get_revenue_grid`), slot edit/reopen, Storage photo uploads, CSV exports,
cancellation timestamps, and the Resend email Edge Function + pg_cron reminders.

## How this was verified (and its limits)

- **DB policy/grant state**: static trace of *every* `create/drop policy`, `grant`,
  `revoke`, and `security definer` across all nine migrations in documented order,
  reconciled to the final effective state (tables below). No Docker/psql is available
  on this machine, so a literal "fresh scratch DB" was **not** built here.
- **Behavioural DB proof**: `supabase/verify_v6.sql` (34 checks) was run on the **live
  production database** and returned ALL GREEN — it exercises the real RLS policies and
  `SECURITY DEFINER` gates as simulated admin/coach/anon roles (booking verification,
  OTP lockout, atomic multi-book, cap, last-admin guard, every "Only admins" gate,
  anon-cannot-execute). `verify_v6_api.mjs` provides the same probes against the live
  REST API with real JWTs (admin leg runnable now; coach leg awaits a real coach login).
- **Frontend/behaviour**: 85 headless-browser checks against the real pages with a
  mocked Supabase client (`test-staff.mjs` 53, `test-book.mjs` 21, `test-partb.mjs` 11),
  all green after the fixes below.
- **Not automated**: Storage policy behaviour (SQL-only projects can't always alter it),
  live Resend send paths, and pg_cron scheduling — verified by reading + reasoning, and
  called out where a live check is still recommended before/after launch.

**Residual action for the team:** run `verify_v6.sql` once more after any further
migration, and run `verify_v6_api.mjs` with a real `COACH_JWT` the first time a
coach-role account exists — that permission leg has never been exercised with a real token.

---

## Findings summary

| # | Severity | Area | Status |
|---|----------|------|--------|
| H1 | **High** | CSV formula injection in exports | **Fixed** |
| M1 | Medium | Mobile tap targets < 44px on customer pages | **Fixed** (44px primary / 36px floor) |
| M2 | Medium | Staff can overwrite each other's Storage photos | Listed (needs Storage policy) |
| M3 | Medium | OTP request endpoint emails arbitrary addresses (bounded) | Accepted w/ rate limits; CAPTCHA recommended |
| L1 | Low | `profiles.role` visible to any *authenticated* user for public coaches | Listed |
| L2 | Low | Edge `slot_update`/`confirmation` invokable by anon (no open relay) | Listed w/ hardening |
| L3 | Low | 24h verify-token theft blast radius | Documented (bounded) |
| L4 | Low | Booking-cap race under concurrent multi-book | Listed (self-inflicted) |
| — | Info | Public signups, sender verification, Storage bucket = Supabase console settings | See ship checklist |

No **Critical** findings. The old audit's fixes (L1–L6 in `SECURITY_AUDIT.md`) still
hold in the final migration state — see the reconciliation table.

---

## PART A — SECURITY

### A0. Final effective RLS / grants (reconciled across all 9 migrations)

Every table has RLS enabled. "anon" = the public/browser key; "auth" = any logged-in
user; "staff" = auth **and** `is_staff()`; "admin" = staff **and** `role='admin'`.

| Table | anon | authenticated (non-staff) | staff | admin |
|-------|------|---------------------------|-------|-------|
| `profiles` | SELECT only `(id,display_name,bio,is_public,photo_url)` where `is_public` | + reads `role` on public rows (**L1**) | read all; update own `(display_name,bio,is_public,photo_url)` | roles via `admin_update_profile()` RPC only |
| `pools` | SELECT active pools | same | full manage | full manage |
| `slots` | SELECT future open/booked, **no `price`**, + `booked_by_display` | same | read all; insert/cancel **own or admin** | insert/edit/cancel/reopen any |
| `bookings` | **none** | none (RLS `is_staff`) | SELECT; UPDATE `status` on own-slot bookings | UPDATE any |
| `clients` | **none** | none | SELECT; UPDATE `notes` | UPDATE notes; delete via `delete_client()` |
| `settings` | **none** | none | SELECT | UPDATE `default_price` |
| `staff_emails` | **none** | none | none (only `is_staff()` definer reads) | none |
| `booking_otps` | **none** | none | none (Edge service-role + verify definer) | none |
| `booking_email_tokens` | **none** | none | none (`book_slots` definer only) | none |

Writes to `bookings`/`clients` for the public happen **only** through `SECURITY DEFINER`
functions; `slots.price` and `profiles.role` have **no API write grant at all**. This
matches the intended model and the `verify_v6.sql` C8/D-series results.

**Old-audit fixes re-confirmed in final state:**
- L1 (hide `role` from anon): holds — anon's `profiles` SELECT is column-limited and
  excludes `role`. (See L1 below for the residual *authenticated* exposure.)
- L2 (revoke leftover anon table grants): holds — `bookings`, `clients`, `staff_emails`,
  both OTP/token tables have `revoke all … from anon`.
- L3 (admin RPCs not anon-executable): holds — `is_admin`, `is_staff`,
  `get_revenue_report/grid`, `delete_client`, `reopen_slot`, `admin_update_profile`,
  `edit_slot`, `get_slot_for_edit` all `revoke execute … from anon`. (`book_slots`,
  `cancel_booking`, `verify_and_list_bookings` intentionally stay anon — that's the
  public booking path.)
- L4 (Storage restricted to image paths): holds in the migration, but see **M2**.
- L6/M5 (retention helpers): present (`purge_expired_otps`, `purge_old_client_data`).

### A1. New RPC surface — per-function verdict

| RPC | Callable by | Privilege check | Validation | Error leaks | Verdict |
|-----|-------------|-----------------|------------|-------------|---------|
| `book_slots` | anon, auth | email verified (OTP **or** 24h token) *before* any state read | name/email/phone, 1–8 slots, tz, cap 8, overlap (in-set + existing), row-locks in id order | names times only, never PII; count only after verification | ✅ |
| `verify_and_list_bookings` | anon, auth | correct OTP; 5-attempt lockout | code format | generic; returns only that email's own rows | ✅ (lockout fixed in v6) |
| `cancel_booking` | anon, auth | unguessable `cancel_token` | token match, future-only | generic | ✅ |
| `admin_update_profile` | auth | `is_admin()` + last-admin guard | name non-empty, role ∈ {coach,admin} | generic | ✅ |
| `reopen_slot` | auth | `is_admin()` | cancelled + future + no confirmed booking | generic | ✅ |
| `get_revenue_grid` / `_report` | auth | `is_admin()` | range ≤ 400d, valid tz | generic | ✅ |
| `edit_slot` / `get_slot_for_edit` | auth | `is_staff()` + own-slot-or-admin | duration/price/pool/coach, no-overlap, no past-move | generic | ✅ |
| `delete_client` | auth | `is_admin()` | — (anonymizes, keeps history) | — | ✅ |
| OTP request (Edge) | anon | none by design | email format; per-email 3/15min + global 40/day | none | ⚠️ **M3** |

`p_tz` is passed to the `AT TIME ZONE` operator (a parameter, **not** string-concatenated
into SQL) and validated with a probing `perform` — no SQL injection surface.

### A2. Abuse paths

- **OTP brute force** — 6-digit code, SHA-256 hashed, 10-min expiry, **5 wrong attempts
  locks the code** (the v6 fix: the attempt counter now persists because the wrong-code
  path RETURNs `{error}` instead of RAISE-ing, which had rolled the increment back). A
  new code resets attempts, but code *requests* are capped at 3/15min per email → ≤15
  guesses per 15 min against 10⁶ space. Effectively unbruteforceable. **OK.**
- **OTP / email bombing (M3)** — the request endpoint will email a code to *any* address
  (fixed content, no recipient control beyond the address itself). A victim address is
  capped at **3 emails / 15 min**; the whole system at **40 / day**. That bounds abuse
  but isn't zero. *Recommend a CAPTCHA/Turnstile on the code-request + booking forms
  before or shortly after launch* (also in the original audit's "recommended").
- **Booking-cap bypass** — cap = 8 upcoming confirmed per email, enforced inside
  `book_slots` for both the code and token paths; verified live (`verify_v6` A7). A rare
  race (two concurrent multi-books for the same email both reading the same baseline)
  could momentarily exceed 8 (**L4**) — self-inflicted, anti-spam only, not a security
  boundary.
- **CSV formula injection (H1 — fixed)** — client-supplied `first_name`/`last_name`/
  `parent_name` flow into the schedule/history/bookings CSVs, which **staff** open in
  Excel. A parent named `=HYPERLINK(...)` or `=cmd|'/c …'!A1` would execute on open.
  Fixed centrally in `csvField()`: any cell whose first character is `= + - @` (or a
  leading tab/CR that shifts the first char) is prefixed with `'` so the spreadsheet
  treats it as text. Covers all four exporters (schedule, history, SignUpGenius,
  revenue). Ordinary names are untouched. (Tests: `sec:` group in `test-staff.mjs`.)
- **Photo upload abuse (M2)** — the Storage policy allows `authenticated` + `is_staff()`
  to write only `^(coaches|pools)/[^/]+\.(jpg|jpeg|png|webp)$`, but does **not** bind the
  filename to the caller. So any staff member can overwrite **another** coach's or a
  pool's photo. Staff-only, so Medium not High. Fix (Storage → Policies, since SQL DDL on
  `storage.objects` is often blocked): restrict INSERT/UPDATE to
  `public.is_admin() OR name = 'coaches/' || auth.uid()::text || '.jpg'`. Also note the
  content-type is inferred from the extension, not magic bytes, and size is only capped
  client-side (server relies on the project file-size limit) — set a Storage file-size
  limit in the console.
- **24h verify-token theft (L3)** — the raw token lives in `localStorage`; only its
  SHA-256 is stored server-side. Blast radius if stolen (needs XSS or device access):
  the holder can **create** bookings under the victim's email without the OTP for ≤24h,
  up to the cap of 8 — an annoyance, not account takeover. It grants **no read access**
  to the victim's bookings/PII (My Bookings still requires a fresh OTP). No XSS sink was
  found — output is consistently escaped (`esc`/`escAttr`, `textContent`), and the CSP-free
  static pages don't `eval` user input.

### A3. Edge Function (`emails`)

- **Secrets** — read from `Deno.env` (`RESEND_API_KEY`, `FROM_EMAIL`, `SITE_URL`,
  `CRON_SECRET`, `BUSINESS_TIMEZONE`); `SUPABASE_SERVICE_ROLE_KEY` auto-injected. None are
  echoed to responses; only booking ids + errors are logged. **OK.**
- **Open relay?** — **No.** `confirmation`/`slot_update` derive the recipient **and**
  body from the DB via `booking_id`; the caller can't choose either. `reminders` is gated
  by the `CRON_SECRET` header (fails closed if the secret is unset). `otp` is the only
  path that emails a caller-supplied address, and its content is a fixed code (see M3).
- **L2 (listed)** — the function is deployed `--no-verify-jwt` (required: booking +
  code requests are anonymous), so `confirmation`/`slot_update` are invokable by anyone
  who knows a booking's UUID. `confirmation` is harmless (fully DB-derived, and the UUID
  is unguessable — `gen_random_uuid`). `slot_update` additionally embeds caller-supplied
  `old_start`/`old_location` **text** (HTML-escaped) into the "Was:" line of an email to
  the booking's real owner — a low-severity misleading-text vector, gated by knowing an
  unguessable UUID. *Recommended hardening (not blocking):* validate the caller for
  `slot_update` — read the `Authorization` bearer, `sb.auth.getUser(jwt)`, and confirm
  the email is in `staff_emails` (the service-role client can read it) before sending;
  keep `confirmation` anon for the post-booking flow.

### A4. PII exposure to anon — swept clean

Confirmed **no** full last name, parent/guardian name, email, or phone is reachable by
anon in any surface:
- `slots` (anon): only `booked_by_display` = `"First L."` (approved), never the
  `bookings` row; `price` has no anon grant.
- `profiles` (anon): name/bio/photo of public coaches only.
- `bookings`/`clients`: no anon policy or grant at all.
- RPC returns: `book_slots` → ids + `starts_at`; `verify_and_list_bookings` → only the
  verified email's own rows.
- Error messages: name times, never people. The cap/overlap messages that reference an
  existing booking are only reachable **after** email verification, so they don't leak
  a stranger's schedule.

---

## PART B — DESIGN / UX PRE-SHIP

Reviewed at **360px** (mobile) with the real pages; 11 automated checks green.

**Fixed (M1):** touch targets were 16–42px. Now — all form fields and primary buttons
**≥44px** (WCAG 2.5.5 / Apple HIG), day-filter chips 40px, nav links given full 44px tap
height; compact staff-table buttons kept at a **36px** floor (well above the WCAG 2.2 AA
24px minimum) to preserve table density. Footer sentence links stay small — WCAG exempts
inline links within text.

**Verified good:**
- **Mobile** — no horizontal scroll at 360px on `book.html` or `mybookings.html`;
  multi-select tray is a fixed bottom bar (thumb-reachable); modals use
  `max-height:90vh; overflow-y:auto` (scroll when tall); the OTP field is
  `inputmode="numeric"` + `autocomplete="one-time-code"` (SMS/keyboard friendly).
- **States** — every fetch has a loading placeholder, a friendly empty state ("No open
  times this week…"), and error copy via the message banner rather than a raw dump;
  `config.js` shows a persistent red banner (never a blank page) if misconfigured.
  No spinner-forever paths found.
- **Consistency** — "KSJ Swimming" branding on every page + email; all customer/record
  times render in `BUSINESS_TIMEZONE` (America/Chicago) with a `CDT/CST` suffix in
  emails; no leftover test/debug text in the shipped pages.
- **A11y basics** — all visible inputs are labeled; focus outline is defined
  (`:focus { outline: 2px … }`); the new badges (amber `#fef3c7/#92400e`, red
  `#fee2e2/#991b1b`, tooltip `#0f172a/#f1f5f9`) meet AA contrast.

**Notes / minor (non-blocking):**
- Modals close on backdrop click and buttons, but **Escape-to-close** is not wired on
  every modal. Low priority; nice-to-add for keyboard users.
- The top **nav is crowded at 360px** — the "🏊 KSJ Swimming" brand wraps and the three
  links (Home / My Bookings / Contact Us) tuck tight (confirmed by screenshot). Cosmetic,
  not blocking; a small-screen tweak (shorter brand or a smaller gap under ~380px) would
  polish it. Left as-is to avoid a responsive-nav change right before ship.
- The browsing **calendars** on `book.html`/`staff.html` render times in the **viewer's**
  device timezone (only the record surfaces are pinned to the pool zone). Fine for the
  common all-local case; an out-of-town parent sees their own time on the grid but the
  confirmed pool time in the email — documented, acceptable.
- Client journey (land → browse → filter → multi-select → verify → book → My Bookings →
  cancel) walks cleanly; the one thing a non-technical parent may pause on is that a
  booking now **requires an email code** — the copy explains why ("so your confirmation
  and cancellation links reach you"), which is the right trade for deliverability.

---

## PART C — SHIP CHECKLIST

Moved into `README.md` → **"Pre-launch checklist"** (deploy order, Supabase console
settings, first-week monitoring, rollback). Summary lives there so it stays with the
deploy instructions.

---

## Fixes applied in this pass

1. **H1 — CSV formula injection**: `csvField()` neutralizes leading `= + - @` / tab / CR.
2. **M1 — Mobile tap targets**: `styles.css` (inputs/buttons/chips/nav) + `book.html`
   tray → 44px primary, 36px floor.

## Recommended before or shortly after launch (not blocking)

- **M2**: bind Storage photo writes to the caller (`is_admin() OR name matches own id`)
  in Supabase → Storage → Policies; set a file-size limit.
- **M3**: add CAPTCHA/Turnstile to the code-request + booking forms.
- **L2**: validate the caller of the Edge `slot_update` action.
- **L1**: if it matters that non-staff logins can see which public coaches are admins,
  move `role` reads behind `is_staff()`. (Disabling public signups — checklist — mostly
  closes this.)
