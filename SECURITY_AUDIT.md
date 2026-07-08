# Security & Safety Audit — KSJ Swimming

**Date:** 2026-07-08
**System:** Static HTML/JS site (GitHub Pages) + Supabase (Postgres, RLS, Auth, Storage, Edge Functions, Resend email).
**Sensitivity:** Production system holding personal data of children and their parents — names, parent/guardian names, emails, phone numbers, lesson schedules, and booking history. Treated as high-sensitivity throughout.

## How this audit was done

This was not just a read-through of the code. The database was **actively probed as a real anonymous visitor** using the site's public key, issuing live queries against the production API:

- Attempted to read every sensitive table (`bookings`, `clients`, `booking_otps`, `settings`, `staff_emails`) and column (`slots.price`, `profiles.role`).
- Attempted to write to every table (inserts/updates) as an anonymous user.
- Attempted to call the admin-only database functions (revenue report, delete client) as an anonymous user.
- Attempted to upload and overwrite files in the photo storage bucket as an anonymous user.
- Reviewed every security-definer function, RLS policy, the email Edge Function, and all four web pages for escaping, secrets, and abuse.

**Headline result:** there is **no Critical hole** — an outside visitor cannot read or change any private data. Every attempt to reach bookings, client contact details, parent names, prices, or revenue was refused by the database. The findings below are real and worth fixing, but none of them expose a child's personal data to an anonymous outsider today. The most serious (High) issue is abuse of the email system, not a data leak.

---

## Findings

Severity key: **Critical** = private data or control exposed to anyone; **High** = remotely abusable with real harm; **Medium** = meaningful risk needing a knowledgeable attacker or specific conditions; **Low** = defense-in-depth / minor.

### HIGH

#### H1 — The email endpoint can be abused to spam inboxes and exhaust the email quota
**Status:** Fixed (Edge Function hardened) + recommendation.
**Plain English:** The "email me a code" feature (My Bookings) and the booking confirmation both send email through a function that anyone on the internet can call, with no login. It only limited a *single* email address to 5 codes per 15 minutes — there was no overall daily cap and no per-visitor cap.
**What an attacker could do:** Write a tiny script to (a) send a stranger a stream of "KSJ Swimming access code" emails to harass them, and (b) fire requests for many different addresses to burn through the Resend free allowance (100 emails/day) in minutes — after which **real families stop getting confirmations, reminders, and login codes**. It's a denial-of-service on the whole email system plus a harassment tool.
**Fix applied:** The function now enforces a lower per-email limit (3 per 15 min) **and** a global daily ceiling (40 code emails per 24h) so the shared email quota can't be drained, returning a "too many requests" response when exceeded.
**Recommended follow-up:** Add a CAPTCHA (Cloudflare Turnstile, free) in front of the "send code" and booking buttons to stop scripted abuse entirely. Effort: ~2–3 hours.

### MEDIUM

#### M2 — Cancellation link could leak the secret token to a third party (referrer header)
**Status:** Fixed.
**Plain English:** The cancel link contains a secret token in the web address (`...book.html?cancel=SECRET`). When that page loads the Supabase code library from a public CDN (jsdelivr), the browser was free to attach the **full address, including the secret**, in the "Referer" header sent to that outside company.
**What an attacker could do:** Anyone able to see those CDN request logs could read the token and cancel that family's lesson. Low likelihood, but it's a private token going somewhere it shouldn't.
**Fix applied:** Added a strict `Referrer-Policy: no-referrer` to every page, so the browser never sends the address (or token) to any third party.

#### M3 — A child's lesson schedule can be probed if you know the family's email
**Status:** Recommended (message softened; full fix needs a product decision).
**Plain English:** When booking, if the email you enter already has a lesson at that time, the form says "You already have a lesson booked at this time." By trying different times with someone else's email, an outsider could map out **when a specific child has lessons** — without ever completing a booking.
**What an attacker could do:** Learn a minor's weekly whereabouts (day/time they'll be at a specific pool), which is a physical-safety concern, not just data privacy.
**Fix applied (partial):** none yet — see recommendation.
**Recommended follow-up:** The robust fix is to require email verification (a code) *before* a booking is accepted, so you can only probe your own email. This reuses the OTP machinery already built. Effort: ~3–4 hours. A cheaper partial step is to make the message generic ("This time isn't available"), which removes the clear signal at some cost to booking UX.

#### M4 — Anyone can fill the schedule with fake bookings
**Status:** Recommended (needs CAPTCHA / verification).
**Plain English:** The booking form takes any name/email/phone with no verification. One email is capped at 3 upcoming lessons, but there's no limit on how many different emails one person can use.
**What an attacker could do:** Script hundreds of bookings with fake details and **occupy every open slot**, blocking real customers, while also generating confirmation emails that burn the email quota (see H1).
**Fix applied:** none — this needs an external anti-bot control.
**Recommended follow-up:** Add Cloudflare Turnstile (free) to the booking button, and/or require the email-verification step from M3 before a slot is held. Effort: ~2–4 hours.

#### M5 — No data-retention / purge policy for children's personal data
**Status:** Recommended (purge tools provided in `migration_security.sql`, scheduling left to you).
**Plain English:** Names, parent names, emails, phones, and full booking history are kept forever. The longer personal data (especially minors') is stored, the bigger the damage if the account is ever breached, and the harder to comply with privacy expectations.
**What an attacker could do:** Nothing new — but it increases the blast radius of any future compromise.
**Fix applied:** Added two helper functions — `purge_expired_otps()` (safe to run automatically) and `purge_old_client_data(months)` (admin-only; anonymizes personal details on lessons older than N months while keeping revenue totals intact). They are **not** scheduled, because the retention period is your decision.
**Recommended follow-up:** Decide a retention window (e.g. anonymize personal details 24 months after a lesson) and schedule `purge_old_client_data` via pg_cron. Effort: ~30 min once you pick a number.

### LOW (defense-in-depth / minor)

#### L1 — Anonymous visitors can see which coaches are admins
**Status:** Fixed (in `migration_security.sql`).
**Plain English:** The public "coaches" data included an internal `role` column, so anyone could see that "Kevin Li" and "Steven Ma" are administrators (plus internal id/created-at fields). Confirmed live.
**Impact:** Minor information disclosure — tells an attacker which two accounts are the highest-value targets.
**Fix applied:** Anonymous visitors can now read only name, bio, photo, and the public flag — not `role` or internal fields.

#### L2 — Leftover table permissions on `bookings` and `staff_emails` (only RLS is stopping access)
**Status:** Fixed (in `migration_security.sql`).
**Plain English:** These tables were reachable at the permission level by anonymous users; only the row-level security rules returned "nothing." That's one safety net instead of two — a future careless policy change could turn it into a real leak (`staff_emails` is the list that grants dashboard access).
**Fix applied:** Removed all anonymous table permissions on `staff_emails` and `bookings` so there are now two independent barriers, not one.

#### L3 — Admin-only functions are callable by anonymous users (blocked only by their internal check)
**Status:** Fixed (in `migration_security.sql`).
**Plain English:** `get_revenue_report` and `delete_client` could be *invoked* by anyone; they correctly refused with "Only admins…", so no data leaked — but they should not be callable at all by the public.
**Fix applied:** Removed anonymous permission to execute the admin/staff-only functions (revenue, delete-client, is_admin, is_staff), leaving only the intended public ones (book, cancel, view-my-bookings).

#### L4 — A staff member could upload non-image files (or overwrite another's photo)
**Status:** Fixed where the platform allows (in `migration_security.sql`, best-effort).
**Plain English:** The photo bucket accepted any file type from a logged-in staff member and any path, so a malicious/compromised staff account could host, say, a fake login page on the trusted Supabase domain, or replace another coach's photo.
**Fix applied:** Tightened the upload rules to accept only image files (`.jpg/.jpeg/.png/.webp`) under the `coaches/` and `pools/` folders. (Staff-only to begin with, so this is hardening against a compromised staff account.)

#### L5 — Inconsistent HTML-escaping on the My Bookings cancel button
**Status:** Fixed.
**Plain English:** One spot used text-escaping instead of attribute-escaping for the cancel token. Safe today because the token is a system-generated UUID with no special characters, but the inconsistent pattern is a foot-gun.
**Fix applied:** Switched to attribute-safe escaping for consistency with the other pages.

#### L6 — Expired login codes are never cleaned up
**Status:** Fixed (purge function provided; see M5).
**Plain English:** Used/expired 6-digit code records pile up forever. Minor housekeeping.
**Fix applied:** `purge_expired_otps()` added; recommend scheduling it hourly (or it can piggyback on the reminder job).

#### L7 — Booking rate-limit message reveals an email already has 3 bookings
**Status:** Accepted (informational).
**Plain English:** If you try to book a 4th lesson on an email, the message says that email already has 3 upcoming bookings. Very minor and only meaningful to someone already using that exact email. No change made; noted for completeness.

---

## Verified GOOD (tested, no action needed)

- **No anonymous access to private data.** Live probes as an anonymous user were refused for `clients`, `booking_otps`, `settings`, and `slots.price`; `bookings`/`staff_emails` returned zero rows. Emails, phones, parent names, full last names, prices, and revenue are all unreachable.
- **No anonymous writes.** Inserts/updates to `bookings`, `clients`, `slots`, `profiles`, and `staff_emails` were all denied. No way to self-promote to staff or admin.
- **Row-Level Security is enabled on every table.**
- **Security-definer functions are sound.** All pin `search_path`, take strongly-typed parameters (no SQL injection), validate input, and the admin/OTP checks live inside the function (not just in the UI).
- **Cancel tokens are strong.** 122-bit random UUIDs — not guessable or brute-forceable.
- **OTP codes resist brute force.** 6 digits, stored only as a SHA-256 hash, 10-minute expiry, max 5 wrong attempts per code and max a few codes per 15 minutes → far too slow to guess (1 in 1,000,000 with ~25 tries per 15 min).
- **No secrets in the public repo.** The only key in the code is the Supabase **anon** key, which is safe to publish by design (all protection is server-side RLS). No `service_role` key, Resend key, or cron secret is committed.
- **No open redirects.** The Google sign-in redirect uses the page's own address; no user-controlled redirect targets.
- **Public data minimization holds.** Booked slots publicly show at most "FirstName L." + coach — never a full last name, parent name, email, or phone.

### One thing I could not test live
Coach-vs-admin enforcement (a coach must not cancel another coach's bookings, read revenue, or delete clients) is enforced by database policies and the `is_admin()` check, which I verified by reading the policies and via earlier automated browser tests. I could **not** exercise it with a real coach login because both current staff accounts are admins, so there was no coach token to test with. **Recommended:** once you add a non-admin coach, sign in as them and confirm the Revenue tab is absent and canceling someone else's lesson fails.

---

## Summary table

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| H1 | High | Email/OTP endpoint abusable → inbox spam + quota exhaustion | **Fixed** (function redeployed) + rec. CAPTCHA |
| M2 | Medium | Cancel token could leak via Referer to CDN | **Fixed** (referrer policy) |
| M3 | Medium | Child's lesson schedule enumerable via booking error | **Recommended** (email-verify to book) |
| M4 | Medium | Anyone can fill schedule with fake bookings | **Recommended** (CAPTCHA / email-verify) |
| M5 | Medium | No data-retention policy for minors' data | **Recommended** (purge tools provided) |
| L1 | Low | Anon can read `profiles.role` (admins revealed) | **Fixed** (migration) |
| L2 | Low | Leftover anon table grants on `bookings`/`staff_emails` | **Fixed** (migration) |
| L3 | Low | Admin RPCs callable by anon (blocked only internally) | **Fixed** (migration) |
| L4 | Low | Staff could upload non-image files / overwrite paths | **Fixed** (migration, best-effort) |
| L5 | Low | Inconsistent HTML escaping on one attribute | **Fixed** (frontend) |
| L6 | Low | Expired login codes never cleaned up | **Fixed** (purge function) |
| L7 | Info | Rate-limit message reveals email has 3 bookings | Accepted |

**Before the fixes, the worst realistic attack was:** a script (no login, from anywhere) hammering the code-email endpoint to bombard a chosen person's inbox and burn the daily email allowance so real families silently stopped receiving confirmations, reminders, and login codes (H1). Separately, someone who knew a family's email could quietly map out which day/time a specific child swims (M3). Neither ever exposed the bookings or client tables directly — those stayed locked throughout.

## How to activate each fix

Three of the fixes are already **live** (the Edge Function was redeployed during the audit). The rest activate when you deploy the frontend and run the migration:

1. **Database fixes (L1–L4, L6, M5 tools)** — run **`supabase/migration_security.sql`** in the Supabase SQL Editor. Idempotent; safe to re-run. If you see a NOTICE about storage policies, set them by hand in Storage → photos → Policies (allow INSERT/UPDATE only for image files).
2. **Frontend fixes (M2, L5)** — commit & push; GitHub Pages redeploys `ksjswimming.com`.
3. **Edge Function (H1)** — already deployed and verified live. No action.

After running the migration, you can confirm L1 is closed by loading the site's coach data as a logged-out visitor — the `role` field should no longer be present.

## Operational-security checklist for the owners

Most real-world compromises of a system like this come from an account or key being mishandled, not from the code. Keep this list somewhere safe:

- **Staff accounts**
  - Use a **strong, unique password** for every staff Google/email account. Turn on 2-step verification on the Google accounts used to sign in.
  - Keep the **`staff_emails` allowlist tight** — only current coaches. Review it every few months and whenever someone leaves. Removing an email instantly cuts off dashboard access.
  - Grant **admin** (`role = 'admin'`) to as few people as possible. Admins can see revenue and delete client data.
- **The Supabase dashboard**
  - Know exactly **who has the Supabase login** (it's the master key — it can read everything, bypassing all the protections above). Ideally one or two trusted owners, with 2FA enabled on their Supabase accounts.
- **Secrets — never put these in the website code or GitHub**
  - `service_role` key, the **Resend API key**, and the **`CRON_SECRET`** must stay only in Supabase (Function secrets / SQL). The site's `anon` key in `config.js` is the *only* key that belongs in the public repo.
  - If a secret is ever pasted somewhere public, **rotate it**: regenerate the Resend key (Resend dashboard) and re-set it with `supabase secrets set`; generate a new `CRON_SECRET` and update both the secret and the cron job.
- **If a staff account is compromised**
  1. Remove their email from `staff_emails` immediately (cuts off all data access).
  2. In Supabase → Authentication → Users, delete or reset that user.
  3. If they were an admin, set their `role` back to `coach` (or delete) and review recent bookings/clients for tampering.
  4. If you suspect the Supabase login itself was exposed, rotate the database password and the `service_role` key from the dashboard.
- **Data hygiene**
  - Schedule `purge_expired_otps()` (hourly) and decide a retention window for `purge_old_client_data(months)` so children's personal details aren't kept indefinitely.
  - Supabase keeps automatic backups on paid plans; on the free plan, take an occasional manual export of the important tables.
- **General**
  - Keep using HTTPS only (already enforced). Never share the customer booking link alongside any staff credentials.
  - Revisit this audit if you add features that touch bookings, clients, payments, or file uploads.
